import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/timeline/timeline_item.dart';
import '../../domain/transcript/transcript_segment.dart';
import '../../poc/poc_bridge.dart';
import 'full_text_refinement_service.dart';
import 'transcription_provider.dart';

class Stage1TranscriptionController extends ChangeNotifier {
  Stage1TranscriptionController({
    required this.bridge,
    required this.provider,
    this.fullTextRefinementService,
    bool? enableFaultInjection,
  }) : faultInjectionEnabled = enableFaultInjection ?? kProfileMode;

  final PoCBridge bridge;
  final TranscriptionProvider provider;
  final FullTextRefinementService? fullTextRefinementService;
  final bool faultInjectionEnabled;

  TranscriptionWorkerState workerState = const TranscriptionWorkerState(
    status: TranscriptionWorkerStatus.uninitialized,
  );
  TranscriptPartial? partial;
  List<TimelineItem> timeline = const [];
  String? error;
  String? activeSessionId;
  String? activeDirectory;
  bool catchUpRequired = false;
  bool faultOperationInProgress = false;
  bool recoveryCatchUpInProgress = false;
  String? faultStatus;
  String? recoveryStatus;
  String? fullTextRefinementStatus;
  Object? fullTextRefinementError;

  StreamSubscription<PoCSnapshot>? _runtimeSubscription;
  StreamSubscription<TranscriptionWorkerState>? _stateSubscription;
  StreamSubscription<TranscriptPartial>? _partialSubscription;
  StreamSubscription<TranscriptSegment>? _segmentSubscription;
  StreamSubscription<TranscriptionDiagnosticEvent>? _diagnosticSubscription;
  Future<void>? _startingSession;
  Future<void> _runtimeTail = Future<void>.value();
  Future<void> _refinementTail = Future<void>.value();
  final _refiningSessions = <String>{};
  String? _runningRefinementSession;

  bool isRefinementPending(String sessionId) =>
      _refiningSessions.contains(sessionId);
  bool isRefinementRunning(String sessionId) =>
      _runningRefinementSession == sessionId;

  bool get hasPendingRefinements => _refiningSessions.isNotEmpty;
  bool isSessionFinishing(String sessionId) =>
      activeSessionId == sessionId || _refiningSessions.contains(sessionId);
  Future<void> _diagnosticTail = Future<void>.value();
  Future<void>? _initializationFuture;
  final Set<Future<void>> _pendingCommits = {};
  int? _catchUpFromSample;
  bool _disposed = false;

  static final _timelineReadErrorPrefix = l10n.couldNotReadTheOriginalTimeline;
  static const _timelineReadAttempts = 3;

  TranscriptionResilienceControl? get _resilienceControl =>
      provider is TranscriptionResilienceControl
      ? provider as TranscriptionResilienceControl
      : null;

  bool get faultControlsAvailable =>
      faultInjectionEnabled && _resilienceControl != null;

  bool get canInjectFault =>
      faultControlsAvailable &&
      activeSessionId != null &&
      !recoveryCatchUpInProgress &&
      !faultOperationInProgress;

  int get forcedProcessingDelayMs =>
      _resilienceControl?.forcedProcessingDelayMs ?? 0;

  bool get modelFaultActive => _resilienceControl?.modelFaultActive ?? false;

  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('Transcription controller is disposed.'),
      );
    }
    return _initializationFuture ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    _runtimeSubscription = bridge.events.listen((snapshot) {
      _runtimeTail = _runtimeTail
          .then((_) => _handleRuntime(snapshot))
          .catchError((Object value) {
            _setError(
              l10n.couldNotProcessARecordingEventAudio((value).toString()),
            );
          });
    }, onError: (Object value) => _setError('$value'));
    _stateSubscription = provider.states.listen((value) {
      workerState = value;
      if ((value.status == TranscriptionWorkerStatus.failed ||
              value.status == TranscriptionWorkerStatus.catchUpRequired) &&
          activeSessionId != null) {
        catchUpRequired = true;
        _catchUpFromSample ??= value.lastTranscribedSample;
      }
      notifyListeners();
    });
    _partialSubscription = provider.partials.listen((value) {
      partial = value;
      notifyListeners();
    });
    _segmentSubscription = provider.segments.listen(_commitSegment);
    final resilienceControl = _resilienceControl;
    if (resilienceControl != null) {
      _diagnosticSubscription = resilienceControl.diagnosticEvents.listen((
        event,
      ) {
        _diagnosticTail = _diagnosticTail
            .then((_) => _persistDiagnosticEvent(event))
            .catchError((Object value) {
              _setError(
                l10n.couldNotSaveATranscriptionRecoveryEvent(
                  (value).toString(),
                ),
              );
            });
      });
    }
    try {
      await provider.initialize();
    } catch (value) {
      _setError(
        l10n.theLocalTranscriptionModelIsUnavailableRecording(
          (value).toString(),
        ),
      );
    }
  }

  Future<RecoveryTranscriptionResult> recoverSessionTranscription({
    required String sessionId,
    required String directory,
  }) async {
    if (sessionId.isEmpty || directory.isEmpty) {
      throw ArgumentError('Recovered Session id and directory are required.');
    }
    await initialize();
    if (activeSessionId != null || recoveryCatchUpInProgress) {
      throw StateError(l10n.recordingOrTranscriptionRecoveryIsAlreadyIn);
    }

    recoveryCatchUpInProgress = true;
    recoveryStatus = l10n.checkingTranscriptionProgressForTheRecoveredRecording;
    activeSessionId = sessionId;
    activeDirectory = directory;
    error = null;
    partial = null;
    notifyListeners();

    try {
      final before = await _readTimeline(directory);
      timeline = before;
      final transcriptHighWater = _lastFinalTranscriptSample(before);
      final completedHighWater = _lastRecoveryCatchUpSample(before);
      final afterSample = transcriptHighWater > completedHighWater
          ? transcriptHighWater
          : completedHighWater;
      final committed = await bridge.committedChunks(
        directory,
        afterSample: afterSample,
      );

      if (committed.isEmpty) {
        final transcriptCount = timeline
            .where((item) => item.isTranscript)
            .length;
        final needsDurableReconciliation =
            afterSample > 0 && completedHighWater < afterSample;
        if (needsDurableReconciliation) {
          await bridge.commitStage1Event(
            directory,
            type: 'asr_recovery_catchup_started',
            sampleOffset: afterSample,
            payload: {
              'fromSample': afterSample,
              'chunkCount': 0,
              'committedHighWater': afterSample,
              'reusedExistingTranscripts': true,
            },
          );
          final reconciliation = provider is TranscriptionRecoveryReconciliation
              ? provider as TranscriptionRecoveryReconciliation
              : null;
          if (reconciliation != null) {
            await reconciliation.completeRecoveredSession(
              context: TranscriptionSessionContext(
                sessionId: sessionId,
                directory: directory,
              ),
              completedHighWater: afterSample,
              finalSegmentCount: transcriptCount,
            );
          }
          await bridge.commitStage1Event(
            directory,
            type: 'asr_recovery_catchup_completed',
            sampleOffset: afterSample,
            payload: {
              'fromSample': afterSample,
              'chunkCount': 0,
              'committedHighWater': afterSample,
              'reusedExistingTranscripts': true,
            },
          );
          await refreshTimeline(directory);
          await _runFullTextRefinement(
            sessionId: sessionId,
            directory: directory,
          );
        }
        if (!needsDurableReconciliation) {
          await _runFullTextRefinement(
            sessionId: sessionId,
            directory: directory,
          );
        }
        recoveryStatus = l10n.recoveredTranscriptionIsUpToDateThe;
        return RecoveryTranscriptionResult(
          didCatchUp: false,
          fromSample: afterSample,
          toSample: afterSample,
          chunkCount: 0,
          transcriptCount: transcriptCount,
          timelineItemCount: timeline.length,
        );
      }

      final chunks = committed.toList(growable: false);
      if (afterSample > chunks.first.startSample) {
        chunks[0] = chunks.first.sliceFrom(afterSample);
      }
      final committedHighWater = chunks.last.endSample;
      recoveryStatus = l10n.transcribing(
        (_durationLabel(afterSample)).toString(),
        (_durationLabel(committedHighWater)).toString(),
      );
      notifyListeners();

      await bridge.commitStage1Event(
        directory,
        type: 'asr_recovery_catchup_started',
        sampleOffset: afterSample,
        payload: {
          'fromSample': afterSample,
          'chunkCount': chunks.length,
          'committedHighWater': committedHighWater,
        },
      );
      await provider.startSession(
        TranscriptionSessionContext(sessionId: sessionId, directory: directory),
      );
      await provider.transcribeCommittedChunks(chunks);
      await provider.endSession();
      await _drainSegmentCommits();
      await _diagnosticTail;
      await bridge.commitStage1Event(
        directory,
        type: 'asr_recovery_catchup_completed',
        sampleOffset: committedHighWater,
        payload: {
          'fromSample': afterSample,
          'chunkCount': chunks.length,
          'committedHighWater': committedHighWater,
        },
      );
      await refreshTimeline(directory);
      await _runFullTextRefinement(sessionId: sessionId, directory: directory);
      recoveryStatus = l10n.recoveredTranscriptionIsCompleteTheOriginalTimeline;
      return RecoveryTranscriptionResult(
        didCatchUp: true,
        fromSample: afterSample,
        toSample: committedHighWater,
        chunkCount: chunks.length,
        transcriptCount: timeline.where((item) => item.isTranscript).length,
        timelineItemCount: timeline.length,
      );
    } catch (value) {
      recoveryStatus = l10n.recoveredAudioIsSavedButTranscriptionFailed(
        (value).toString(),
      );
      _setError(recoveryStatus!);
      rethrow;
    } finally {
      activeSessionId = null;
      _startingSession = null;
      _catchUpFromSample = null;
      catchUpRequired = false;
      recoveryCatchUpInProgress = false;
      partial = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refineSavedSession({
    required String sessionId,
    required String directory,
    bool forceRebuild = false,
  }) {
    final service = fullTextRefinementService;
    if (_disposed ||
        service == null ||
        sessionId.isEmpty ||
        directory.isEmpty) {
      return Future.error(StateError(l10n.manualRefinementUnavailable));
    }
    if (activeSessionId != null ||
        recoveryCatchUpInProgress ||
        faultOperationInProgress ||
        _refiningSessions.contains(sessionId)) {
      return Future.error(StateError(l10n.manualRefinementBusy));
    }
    _refiningSessions.add(sessionId);
    notifyListeners();
    final completion = Completer<void>();
    _refinementTail = _refinementTail.then((_) async {
      try {
        if (_disposed) throw StateError(l10n.manualRefinementUnavailable);
        _runningRefinementSession = sessionId;
        fullTextRefinementError = null;
        notifyListeners();
        final chunks = await bridge.committedChunks(directory);
        final sources = await _readTimeline(directory);
        await service.refine(
          FullTextRefinementRequest(
            sessionId: sessionId,
            directory: directory,
            chunks: List.unmodifiable(chunks),
            timeline: List.unmodifiable(sources),
            forceRebuild: forceRebuild,
          ),
        );
        completion.complete();
      } catch (error, stack) {
        fullTextRefinementError = error;
        completion.completeError(error, stack);
      } finally {
        _runningRefinementSession = null;
        _refiningSessions.remove(sessionId);
        if (!_disposed) notifyListeners();
      }
    });
    return completion.future;
  }

  Future<void> refreshTimeline([String? directory]) async {
    final path = directory ?? activeDirectory;
    if (path == null || path.isEmpty) return;
    try {
      timeline = await _readTimeline(path);
      if (error?.startsWith(_timelineReadErrorPrefix) == true) {
        error = null;
      }
      notifyListeners();
    } catch (value) {
      _setError('$_timelineReadErrorPrefix$value');
    }
  }

  Future<List<TimelineItem>> _readTimeline(String directory) async {
    Object? lastError;
    for (var attempt = 0; attempt < _timelineReadAttempts; attempt += 1) {
      try {
        return await bridge.timeline(directory);
      } catch (value) {
        lastError = value;
        if (!_isDatabaseBusy(value) || attempt == _timelineReadAttempts - 1) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
      }
    }
    throw StateError(l10n.couldNotReadTheTimeline((lastError).toString()));
  }

  bool _isDatabaseBusy(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked') ||
        message.contains('database is busy');
  }

  Future<void> _handleRuntime(PoCSnapshot snapshot) async {
    if (_disposed) return;
    if (snapshot.sessionId.isNotEmpty && snapshot.directory.isNotEmpty) {
      activeDirectory = snapshot.directory;
    }

    final keepsLiveSession = const {
      'recording',
      'pausing',
      'paused',
      'resuming',
      'interrupted',
    }.contains(snapshot.state);
    if (keepsLiveSession && snapshot.sessionId.isNotEmpty) {
      await _ensureSession(snapshot);
    }

    final chunk = snapshot.committedChunk;
    if (chunk != null) {
      if (activeSessionId != chunk.sessionId) {
        await _ensureSession(snapshot);
      }
      if (_catchUpFromSample == null) {
        final result = provider.tryEnqueue(chunk);
        if (result != EnqueueResult.accepted) {
          _catchUpFromSample = chunk.startSample;
          catchUpRequired = true;
          notifyListeners();
        }
      } else {
        catchUpRequired = true;
        notifyListeners();
      }
    }

    final reachedTerminalState =
        snapshot.state == 'completed' ||
        snapshot.state == 'completed_with_gaps';
    if (reachedTerminalState && activeSessionId != null) {
      try {
        await _normalizeInjectedFaultsBeforeStop();
        await provider.endSession();
        await _runCatchUpIfNeeded(snapshot);
        await _drainSegmentCommits();
        await _diagnosticTail;
        await refreshTimeline(snapshot.directory);
        await _runFullTextRefinement(
          sessionId: snapshot.sessionId,
          directory: snapshot.directory,
        );
      } catch (value) {
        _setError(
          l10n.couldNotFinishTranscriptionAudioHasBeen((value).toString()),
        );
      } finally {
        activeSessionId = null;
        _startingSession = null;
        _catchUpFromSample = null;
        partial = null;
        faultOperationInProgress = false;
        notifyListeners();
      }
    }
  }

  Future<void> _ensureSession(PoCSnapshot snapshot) async {
    if (activeSessionId == snapshot.sessionId) return;
    final existing = _startingSession;
    if (existing != null) return existing;
    final future = () async {
      try {
        // A recreated Flutter engine can attach to Android's still-running
        // foreground recorder. Resume from persisted text, never skip audio
        // committed while no Dart consumer was attached.
        final rejoining =
            snapshot.committedMs > 0 &&
            snapshot.event == null &&
            snapshot.committedChunk == null;
        final previous = rejoining
            ? await _readTimeline(snapshot.directory)
            : <TimelineItem>[];
        final transcriptEnd = _lastFinalTranscriptSample(previous);
        final reconciledEnd = _lastRecoveryCatchUpSample(previous);
        await provider.startSession(
          TranscriptionSessionContext(
            sessionId: snapshot.sessionId,
            directory: snapshot.directory,
          ),
        );
        activeSessionId = snapshot.sessionId;
        activeDirectory = snapshot.directory;
        timeline = previous;
        partial = null;
        catchUpRequired = rejoining;
        _catchUpFromSample = rejoining
            ? (transcriptEnd > reconciledEnd ? transcriptEnd : reconciledEnd)
            : null;
        faultStatus = null;
        error = null;
        notifyListeners();
      } catch (value) {
        catchUpRequired = true;
        _setError(
          l10n.liveTranscriptionDidNotStartRecordingAnd((value).toString()),
        );
      }
    }();
    _startingSession = future;
    await future;
    if (activeSessionId == null) _startingSession = null;
  }

  Future<void> _runCatchUpIfNeeded(PoCSnapshot snapshot) async {
    final afterSample = _catchUpFromSample;
    if (afterSample == null) {
      catchUpRequired = false;
      return;
    }
    final committed = await bridge.committedChunks(
      snapshot.directory,
      afterSample: afterSample,
    );
    if (committed.isEmpty) {
      catchUpRequired = false;
      return;
    }
    final chunks = committed.toList(growable: false);
    if (afterSample > chunks.first.startSample) {
      chunks[0] = chunks.first.sliceFrom(afterSample);
    }
    await bridge.commitStage1Event(
      snapshot.directory,
      type: 'asr_catchup_started',
      sampleOffset: afterSample,
      payload: {
        'chunkCount': chunks.length,
        'committedHighWater': chunks.last.endSample,
      },
    );
    await provider.startSession(
      TranscriptionSessionContext(
        sessionId: snapshot.sessionId,
        directory: snapshot.directory,
      ),
    );
    await provider.transcribeCommittedChunks(chunks);
    await provider.endSession();
    await _drainSegmentCommits();
    await bridge.commitStage1Event(
      snapshot.directory,
      type: 'asr_catchup_completed',
      sampleOffset: chunks.last.endSample,
      payload: {
        'fromSample': afterSample,
        'chunkCount': chunks.length,
        'committedHighWater': chunks.last.endSample,
      },
    );
    catchUpRequired = false;
  }

  Future<void> injectWorkerCrashForTest() => _runWorkerReplacementFault(
    runningMessage: l10n.restartingTheTranscriptionWorker,
    completedMessage: l10n.theWorkerHasRestartedKeepRecordingMissing,
    action: (control) => control.terminateWorkerForTest(),
  );

  Future<void> injectMissingModelForTest() => _runWorkerReplacementFault(
    runningMessage: l10n.restartingTheWorkerWithAMissingModel,
    completedMessage: l10n.theModelIsMissingRecordingContinuesRestore,
    action: (control) => control.restartWithMissingModelForTest(),
  );

  Future<void> restoreModelForTest() => _runFaultOperation(
    runningMessage: l10n.restoringTheModelAndRestartingTheWorker,
    completedMessage: l10n.theModelIsRestoredMissingTextWill,
    action: (control) => control.restoreModelForTest(),
  );

  Future<void> toggleForcedOverflowForTest() {
    final nextDelay = forcedProcessingDelayMs == 0 ? 2500 : 0;
    return _runFaultOperation(
      runningMessage: nextDelay == 0
          ? l10n.restoringNormalTranscriptionSpeed
          : l10n.enablingForcedDelay,
      completedMessage: nextDelay == 0
          ? l10n.normalTranscriptionSpeedRestored
          : l10n.eachChunkIsDelayedBySecondsKeep,
      action: (control) => control.setProcessingDelayForTest(nextDelay),
    );
  }

  Future<void> _runFaultOperation({
    required String runningMessage,
    required String completedMessage,
    required Future<void> Function(TranscriptionResilienceControl control)
    action,
  }) async {
    final control = _resilienceControl;
    if (!faultControlsAvailable || control == null) {
      throw UnsupportedError(
        'ASR fault injection is available only in Profile tests.',
      );
    }
    if (activeSessionId == null) {
      throw StateError(l10n.startRecordingBeforeInjectingATranscriptionFault);
    }
    if (faultOperationInProgress) return;
    faultOperationInProgress = true;
    faultStatus = runningMessage;
    error = null;
    notifyListeners();
    try {
      await action(control);
      faultStatus = completedMessage;
    } catch (value) {
      faultStatus = l10n.faultInjectionFailed((value).toString());
      _setError(faultStatus!);
      rethrow;
    } finally {
      faultOperationInProgress = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _runWorkerReplacementFault({
    required String runningMessage,
    required String completedMessage,
    required Future<void> Function(TranscriptionResilienceControl control)
    action,
  }) async {
    final existingCatchUpFromSample = _catchUpFromSample;
    await _runFaultOperation(
      runningMessage: runningMessage,
      completedMessage: completedMessage,
      action: action,
    );
    if (existingCatchUpFromSample == null && activeSessionId != null) {
      // The Worker drains commands already queued before the two-phase native
      // release. Start catch-up at the final acknowledged boundary, not at the
      // earlier UI fault-request snapshot, or that last Chunk is decoded twice.
      _catchUpFromSample = _resilienceControl!.lastTranscribedSample;
      catchUpRequired = true;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _normalizeInjectedFaultsBeforeStop() async {
    final control = _resilienceControl;
    if (control == null) return;
    if (control.forcedProcessingDelayMs != 0) {
      await control.setProcessingDelayForTest(0);
    }
    if (control.modelFaultActive) {
      await control.restoreModelForTest();
    }
  }

  Future<void> _runFullTextRefinement({
    required String sessionId,
    required String directory,
  }) async {
    final service = fullTextRefinementService;
    if (service == null ||
        directory.isEmpty ||
        _refiningSessions.contains(sessionId)) {
      return;
    }
    // Capture this recording's sources before the runtime queue accepts the
    // next recording. Model inference must never hold up recording events.
    final sourceTimeline = List<TimelineItem>.unmodifiable(timeline);
    try {
      final chunks = await bridge.committedChunks(directory);
      if (chunks.isEmpty) return;
      final idleControl = provider is TranscriptionIdleResourceControl
          ? provider as TranscriptionIdleResourceControl
          : null;
      // Still on the runtime queue: it is safe to release the ended ASR worker.
      // Never release it later inside the refinement queue, where a new live
      // recording may already be using the provider.
      await idleControl?.releaseIdleResources();
      final request = FullTextRefinementRequest(
        sessionId: sessionId,
        directory: directory,
        chunks: List.unmodifiable(chunks),
        timeline: sourceTimeline,
      );
      _refiningSessions.add(sessionId);
      _refinementTail = _refinementTail.then((_) async {
        try {
          if (_disposed) return;
          _runningRefinementSession = sessionId;
          fullTextRefinementStatus =
              l10n.refiningTheTranscriptLocallyWithSensevoice;
          fullTextRefinementError = null;
          notifyListeners();
          await service.refine(request);
          fullTextRefinementStatus = l10n.sensevoiceRefinementIsComplete;
        } catch (error) {
          fullTextRefinementError = error;
          fullTextRefinementStatus =
              l10n.refinementIsNotCompleteTheOriginalTimeline;
        } finally {
          _runningRefinementSession = null;
          _refiningSessions.remove(sessionId);
          if (!_disposed) notifyListeners();
        }
      });
    } catch (error) {
      fullTextRefinementError = error;
      fullTextRefinementStatus =
          l10n.refinementIsNotCompleteTheOriginalTimeline;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _persistDiagnosticEvent(
    TranscriptionDiagnosticEvent event,
  ) async {
    final directory = activeDirectory;
    if (directory == null || directory.isEmpty) return;
    await bridge.commitStage1Event(
      directory,
      type: event.type,
      sampleOffset: event.sampleOffset,
      payload: event.payload,
    );
  }

  void _commitSegment(TranscriptSegment segment) {
    // Recovery commits are drained before one final timeline reload. Reading
    // after every recovered segment creates avoidable cross-queue SQLite
    // contention and can leave a stale warning even though all writes succeed.
    final refreshAfterCommit = !recoveryCatchUpInProgress;
    final future = bridge
        .commitTranscriptSegment(segment)
        .then((_) {
          if (refreshAfterCommit && activeDirectory == segment.directory) {
            return refreshTimeline(segment.directory);
          }
        })
        .catchError((Object value) {
          _setError(
            l10n.couldNotSaveATranscriptSegmentAudio((value).toString()),
          );
        });
    _pendingCommits.add(future);
    future.whenComplete(() => _pendingCommits.remove(future));
  }

  Future<void> _waitForSegmentCommits() async {
    while (_pendingCommits.isNotEmpty) {
      await Future.wait(_pendingCommits.toList(growable: false));
    }
  }

  Future<void> _drainSegmentCommits() async {
    // Segment streams are asynchronous. Give the segment notification queued
    // immediately before the Worker's `ended` message a chance to create its
    // persistence Future before checking the set.
    await Future<void>.delayed(Duration.zero);
    await _waitForSegmentCommits();
    await Future<void>.delayed(Duration.zero);
    await _waitForSegmentCommits();
  }

  int _lastFinalTranscriptSample(List<TimelineItem> items) {
    var result = 0;
    for (final item in items) {
      if (item.isTranscript && item.endSample > result) {
        result = item.endSample;
      }
    }
    return result;
  }

  int _lastRecoveryCatchUpSample(List<TimelineItem> items) {
    var result = 0;
    for (final item in items) {
      if (item.type == 'asr_recovery_catchup_completed' &&
          item.sampleOffset > result) {
        result = item.sampleOffset;
      }
    }
    return result;
  }

  void _setError(String value) {
    error = value;
    if (!_disposed) notifyListeners();
  }

  @visibleForTesting
  Future<void> drainRuntimeEvents() => _runtimeTail;

  @visibleForTesting
  Future<void> drainRefinements() => _refinementTail;

  @visibleForTesting
  Future<void> drainDiagnosticEvents() => _diagnosticTail;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_runtimeSubscription?.cancel());
    unawaited(_stateSubscription?.cancel());
    unawaited(_partialSubscription?.cancel());
    unawaited(_segmentSubscription?.cancel());
    unawaited(_diagnosticSubscription?.cancel());
    unawaited(provider.dispose());
    super.dispose();
  }
}

class RecoveryTranscriptionResult {
  const RecoveryTranscriptionResult({
    required this.didCatchUp,
    required this.fromSample,
    required this.toSample,
    required this.chunkCount,
    required this.transcriptCount,
    required this.timelineItemCount,
  });

  final bool didCatchUp;
  final int fromSample;
  final int toSample;
  final int chunkCount;
  final int transcriptCount;
  final int timelineItemCount;

  String get summary => didCatchUp
      ? l10n.transcribedChunks(
          (_durationLabel(fromSample)).toString(),
          (_durationLabel(toSample)).toString(),
          (chunkCount).toString(),
        )
      : l10n.transcriptionIsUpToDate;
}

String _durationLabel(int sample) {
  final duration = Duration(milliseconds: sample * 1000 ~/ 16000);
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
