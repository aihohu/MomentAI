import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:momentai/l10n/app_localization.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../domain/audio/committed_audio_chunk.dart';
import '../../domain/transcript/transcript_segment.dart';
import '../models/local_model_manifest.dart';
import '../models/local_model_runtime.dart';
import 'transcription_provider.dart';

const stage1ModelId = lightweightRealtimeModelId;
const _encoderName = 'encoder.int8.onnx';
const _decoderName = 'decoder.onnx';
const _joinerName = 'joiner.int8.onnx';
const _tokensName = 'tokens.txt';
const _modelIdKey = '__modelId';
const _workerShutdownTimeout = Duration(seconds: 5);
const _stableRssDelay = Duration(seconds: 30);

class SherpaOnnxTranscriptionProvider
    implements
        TranscriptionProvider,
        TranscriptionResilienceControl,
        TranscriptionRecoveryReconciliation,
        TranscriptionIdleResourceControl,
        RealtimeModelRuntimeSwitcher {
  SherpaOnnxTranscriptionProvider({
    required this.modelResolver,
    this.queueCapacity = 4,
  });

  final LocalModelRuntimeResolver modelResolver;
  final int queueCapacity;
  final _partials = StreamController<TranscriptPartial>.broadcast();
  final _segments = StreamController<TranscriptSegment>.broadcast();
  final _states = StreamController<TranscriptionWorkerState>.broadcast();
  final _diagnosticEvents =
      StreamController<TranscriptionDiagnosticEvent>.broadcast(sync: true);
  final _receivePort = ReceivePort();
  final Map<int, ReceivePort> _exitPorts = {};
  final Map<int, ReceivePort> _errorPorts = {};
  final Map<int, Completer<void>> _exitCompleters = {};
  final Map<int, Completer<void>> _nativeReleaseCompleters = {};
  final Set<int> _expectedExitGenerations = {};
  final Set<int> _missingModelGenerations = {};
  final Set<int> _nativeReleaseReportedGenerations = {};
  final Set<int> _nativeReleasedGenerations = {};

  StreamSubscription<Object?>? _receiveSubscription;
  Future<void>? _initializationFuture;
  Future<void>? _workerStartFuture;
  Completer<void>? _workerReady;
  Completer<void>? _ended;
  Isolate? _worker;
  SendPort? _commands;
  Map<String, String>? _modelFiles;
  TranscriptionSessionContext? _session;
  var _workerGeneration = 0;
  var _pendingChunks = 0;
  var _lastTranscribedSample = 0;
  var _status = TranscriptionWorkerStatus.uninitialized;
  var _disposed = false;
  var _runtimeVersion = '';
  var _activeModelId = stage1ModelId;
  var _modelInitializationMs = 0;
  var _processedSamples = 0;
  var _decodeMicroseconds = 0;
  final Set<String> _finalSegmentIds = {};
  var _peakRssBytes = 0;
  var _sessionStartRssBytes = 0;
  var _workerFailureCount = 0;
  var _workerRestartCount = 0;
  var _nativeResourceReleaseCount = 0;
  var _nativeResourceReleaseFailureCount = 0;
  var _gracefulWorkerStopCount = 0;
  var _forcedWorkerKillCount = 0;
  var _queueOverflowCount = 0;
  var _maxQueueDepth = 0;
  var _forcedProcessingDelayMs = 0;
  var _modelFaultActive = false;
  String? _metricsSessionId;
  String? _metricsDirectory;
  String? _probePath;
  Future<void> _probeWrites = Future<void>.value();
  final Set<Timer> _stableRssTimers = {};

  @override
  Stream<TranscriptPartial> get partials => _partials.stream;

  @override
  Stream<TranscriptSegment> get segments => _segments.stream;

  @override
  Stream<TranscriptionWorkerState> get states => _states.stream;

  @override
  Stream<TranscriptionDiagnosticEvent> get diagnosticEvents =>
      _diagnosticEvents.stream;

  @override
  int get forcedProcessingDelayMs => _forcedProcessingDelayMs;

  @override
  bool get modelFaultActive => _modelFaultActive;

  @override
  int get lastTranscribedSample => _lastTranscribedSample;

  @override
  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('Transcription provider is disposed.'),
      );
    }
    return _initializationFuture ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    final initializationWatch = Stopwatch()..start();
    _setState(
      TranscriptionWorkerStatus.loadingModel,
      message: l10n.preparingTheLocalMandarinModel,
    );
    final model = await modelResolver.activeRealtimeModelFiles();
    _modelFiles = _workerModelFiles(model);
    _activeModelId = model.modelId;
    final support = await getApplicationSupportDirectory();
    _probePath = '${support.path}/MomentAI/stage1_asr_probe.json';
    _receiveSubscription ??= _receivePort.listen(_handleWorkerMessage);
    await _startWorker(missingModel: false);
    initializationWatch.stop();
    _modelInitializationMs = initializationWatch.elapsedMilliseconds;
    await _writeProbe('ready');
  }

  @override
  Future<void> startSession(TranscriptionSessionContext context) async {
    await initialize();
    if (_modelFaultActive) {
      throw StateError('The injected model-missing fault is active.');
    }
    if (_commands == null) await _startWorker(missingModel: false);

    final isNewSession = _metricsSessionId != context.sessionId;
    _session = context;
    _metricsDirectory = context.directory;
    _pendingChunks = 0;
    if (isNewSession) {
      _metricsSessionId = context.sessionId;
      _lastTranscribedSample = 0;
      _processedSamples = 0;
      _decodeMicroseconds = 0;
      _finalSegmentIds.clear();
      _sessionStartRssBytes = ProcessInfo.currentRss;
      _peakRssBytes = _sessionStartRssBytes;
      _workerFailureCount = 0;
      _workerRestartCount = 0;
      _nativeResourceReleaseCount = 0;
      _nativeResourceReleaseFailureCount = 0;
      _gracefulWorkerStopCount = 0;
      _forcedWorkerKillCount = 0;
      _queueOverflowCount = 0;
      _maxQueueDepth = 0;
    }
    _sendStart(context);
    _setState(TranscriptionWorkerStatus.transcribing);
    await _writeProbe('transcribing');
  }

  @override
  EnqueueResult tryEnqueue(CommittedAudioChunk chunk) =>
      _tryEnqueue(chunk, reportOverflow: true);

  EnqueueResult _tryEnqueue(
    CommittedAudioChunk chunk, {
    required bool reportOverflow,
  }) {
    if (_disposed || _commands == null) {
      return EnqueueResult.workerUnavailable;
    }
    final session = _session;
    if (session == null || session.sessionId != chunk.sessionId) {
      return EnqueueResult.sessionClosed;
    }
    if (_pendingChunks >= queueCapacity) {
      if (reportOverflow) {
        _queueOverflowCount += 1;
        _emitDiagnostic(
          'asr_queue_overflow',
          sampleOffset: chunk.startSample,
          payload: {
            'phase': 'live',
            'chunkIndex': chunk.index,
            'queueDepth': _pendingChunks,
            'queueCapacity': queueCapacity,
            'workerGeneration': _workerGeneration,
          },
        );
        _setState(
          TranscriptionWorkerStatus.catchUpRequired,
          message: l10n.theTranscriptionQueueIsFullRecordingContinues,
        );
      }
      return EnqueueResult.queueFull;
    }
    _pendingChunks += 1;
    _maxQueueDepth = math.max(_maxQueueDepth, _pendingChunks);
    _commands!.send({'type': 'chunk', ...chunk.toMessage()});
    _setState(TranscriptionWorkerStatus.transcribing);
    return EnqueueResult.accepted;
  }

  @override
  Future<void> transcribeCommittedChunks(
    List<CommittedAudioChunk> chunks,
  ) async {
    for (final chunk in chunks) {
      while (true) {
        final result = _tryEnqueue(chunk, reportOverflow: false);
        if (result == EnqueueResult.accepted) break;
        if (result == EnqueueResult.queueFull) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }
        throw StateError('Unable to enqueue catch-up chunk: $result');
      }
    }
  }

  @override
  Future<void> endSession() async {
    if (_session == null) return;
    if (_modelFaultActive) {
      throw StateError(
        'Cannot finish ASR while the model-missing fault is active.',
      );
    }
    if (_commands == null) await _startWorker(missingModel: false);
    _ended = Completer<void>();
    _commands!.send({'type': 'end'});
    await _ended!.future.timeout(const Duration(seconds: 30));
    _session = null;
    _pendingChunks = 0;
    _setState(TranscriptionWorkerStatus.ready);
  }

  @override
  Future<void> completeRecoveredSession({
    required TranscriptionSessionContext context,
    required int completedHighWater,
    required int finalSegmentCount,
  }) async {
    await initialize();
    if (_session != null) {
      throw StateError(
        'Cannot reconcile a recovered Session while ASR is active.',
      );
    }
    if (completedHighWater < 0 || finalSegmentCount < 0) {
      throw ArgumentError('Recovered ASR metrics cannot be negative.');
    }

    _metricsSessionId = context.sessionId;
    _metricsDirectory = context.directory;
    _lastTranscribedSample = completedHighWater;
    _processedSamples = completedHighWater;
    _decodeMicroseconds = 0;
    _finalSegmentIds
      ..clear()
      ..addAll(
        List<String>.generate(
          finalSegmentCount,
          (index) => 'recovered_existing_$index',
        ),
      );
    _pendingChunks = 0;
    _sessionStartRssBytes = ProcessInfo.currentRss;
    _peakRssBytes = _sessionStartRssBytes;
    _workerFailureCount = 0;
    _workerRestartCount = 0;
    _nativeResourceReleaseCount = 0;
    _nativeResourceReleaseFailureCount = 0;
    _gracefulWorkerStopCount = 0;
    _forcedWorkerKillCount = 0;
    _queueOverflowCount = 0;
    _maxQueueDepth = 0;
    _setState(
      TranscriptionWorkerStatus.ready,
      message:
          'Recovered Session transcripts already reach the audio high-water.',
    );
    await _writeProbe('completed');
    _scheduleStableRssProbe();
  }

  @override
  Future<void> terminateWorkerForTest() async {
    final context = _requireActiveSession();
    final crashedGeneration = _workerGeneration;
    _emitDiagnostic(
      'asr_worker_crash_injected',
      payload: {
        'workerGeneration': crashedGeneration,
        'mode': 'unhandled_exception_after_native_release',
      },
    );
    _setState(
      TranscriptionWorkerStatus.catchUpRequired,
      message: l10n.releasingNativeResourcesAndTriggeringAWorker,
    );
    await _crashCurrentWorkerForTest();
    _workerFailureCount += 1;
    _emitDiagnostic(
      'asr_worker_crashed',
      payload: {
        'injected': true,
        'workerGeneration': crashedGeneration,
        'nativeResourcesReleased': _nativeReleasedGenerations.contains(
          crashedGeneration,
        ),
      },
    );
    await _startWorker(missingModel: false);
    _workerRestartCount += 1;
    _sendStart(context);
    _emitDiagnostic(
      'asr_worker_restarted',
      payload: {'workerGeneration': _workerGeneration},
    );
    _setState(
      TranscriptionWorkerStatus.catchUpRequired,
      message: l10n.theTranscriptionWorkerHasRestartedMissingText,
    );
    await _writeProbe('catch_up_required');
  }

  @override
  Future<void> restartWithMissingModelForTest() async {
    _requireActiveSession();
    _modelFaultActive = true;
    _emitDiagnostic(
      'asr_model_missing_injected',
      payload: {'workerGeneration': _workerGeneration},
    );
    _setState(
      TranscriptionWorkerStatus.catchUpRequired,
      message: l10n.restartingTheTranscriptionWorkerWithAMissing,
    );
    await _stopCurrentWorkerGracefully(reason: 'model_missing_switch');
    try {
      await _startWorker(missingModel: true);
      throw StateError('The missing-model injection unexpectedly succeeded.');
    } catch (_) {
      if (!_modelFaultActive) rethrow;
    }
  }

  @override
  Future<void> restoreModelForTest() async {
    final context = _requireActiveSession();
    _modelFaultActive = false;
    await _waitForCurrentExit();
    await _startWorker(missingModel: false);
    _workerRestartCount += 1;
    _sendStart(context);
    _emitDiagnostic(
      'asr_model_restored',
      payload: {'workerGeneration': _workerGeneration},
    );
    _emitDiagnostic(
      'asr_worker_restarted',
      payload: {
        'workerGeneration': _workerGeneration,
        'afterModelFailure': true,
      },
    );
    _setState(
      TranscriptionWorkerStatus.catchUpRequired,
      message: l10n.theModelIsRestoredMissingTextWill109,
    );
    await _writeProbe('catch_up_required');
  }

  @override
  Future<void> setProcessingDelayForTest(int delayMs) async {
    _requireActiveSession();
    _forcedProcessingDelayMs = delayMs.clamp(0, 5000);
    _commands?.send({'type': 'setDelay', 'delayMs': _forcedProcessingDelayMs});
    _emitDiagnostic(
      'asr_processing_delay_changed',
      payload: {
        'delayMs': _forcedProcessingDelayMs,
        'workerGeneration': _workerGeneration,
      },
    );
    _setState(
      _forcedProcessingDelayMs == 0
          ? TranscriptionWorkerStatus.transcribing
          : TranscriptionWorkerStatus.transcribing,
      message: _forcedProcessingDelayMs == 0
          ? l10n.normalTranscriptionSpeedRestored110
          : l10n.eachTranscriptionChunkIsDelayedByMs(
              (_forcedProcessingDelayMs).toString(),
            ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await _stopCurrentWorkerGracefully(reason: 'provider_dispose');
    _disposed = true;
    for (final timer in _stableRssTimers) {
      timer.cancel();
    }
    _stableRssTimers.clear();
    await _receiveSubscription?.cancel();
    _receivePort.close();
    for (final port in _exitPorts.values) {
      port.close();
    }
    for (final port in _errorPorts.values) {
      port.close();
    }
    _exitPorts.clear();
    _errorPorts.clear();
    _setState(TranscriptionWorkerStatus.disposed);
    await _partials.close();
    await _segments.close();
    await _states.close();
    await _diagnosticEvents.close();
  }

  @override
  Future<void> releaseIdleResources() async {
    if (_disposed || _session != null) return;
    await _stopCurrentWorkerGracefully(reason: 'full_text_refinement');
    _setState(
      TranscriptionWorkerStatus.ready,
      message: l10n.theLiveModelWasReleasedAndWill,
    );
  }

  @override
  Future<void> switchToRealtimeModel(RealtimeModelFiles candidate) async {
    if (_disposed) throw StateError('Transcription provider is disposed.');
    if (_session != null || _pendingChunks != 0) {
      throw StateError(l10n.cannotSwitchTheLiveModelDuringRecording);
    }
    await initialize();
    if (candidate.modelId == _activeModelId) return;
    final previousFiles = _modelFiles;
    final previousModelId = _activeModelId;
    if (previousFiles == null) {
      throw StateError(l10n.theCurrentLiveModelIsNotReady);
    }
    await _stopCurrentWorkerGracefully(reason: 'model_center_switch');
    _modelFiles = _workerModelFiles(candidate);
    _activeModelId = candidate.modelId;
    try {
      await _startWorker(missingModel: false);
      _setState(
        TranscriptionWorkerStatus.ready,
        message: l10n.switchedToLocalModel((candidate.modelId).toString()),
      );
    } catch (error) {
      _modelFiles = previousFiles;
      _activeModelId = previousModelId;
      await _startWorker(missingModel: false);
      _setState(
        TranscriptionWorkerStatus.ready,
        message: l10n.theNewModelCouldNotLoadThe,
      );
      throw StateError(l10n.theNewModelCouldNotLoadThe117((error).toString()));
    }
  }

  Future<void> _startWorker({required bool missingModel}) {
    final existing = _workerStartFuture;
    if (existing != null) return existing;
    late final Future<void> future;
    future = () async {
      try {
        await _spawnWorker(missingModel: missingModel);
      } finally {
        if (identical(_workerStartFuture, future)) {
          _workerStartFuture = null;
        }
      }
    }();
    _workerStartFuture = future;
    return future;
  }

  Future<void> _spawnWorker({required bool missingModel}) async {
    if (_disposed) throw StateError('Transcription provider is disposed.');
    final sourceFiles = _modelFiles;
    if (sourceFiles == null) throw StateError('Model assets are not prepared.');

    final generation = ++_workerGeneration;
    final files = Map<String, String>.from(sourceFiles);
    if (missingModel) {
      files[_encoderName] = '${files[_encoderName]}.fault-injected-missing';
      _missingModelGenerations.add(generation);
    }
    final ready = Completer<void>();
    final exited = Completer<void>();
    final nativeReleased = Completer<void>();
    _workerReady = ready;
    _exitCompleters[generation] = exited;
    _nativeReleaseCompleters[generation] = nativeReleased;

    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    _exitPorts[generation] = exitPort;
    _errorPorts[generation] = errorPort;
    exitPort.listen((_) => _handleWorkerExit(generation));
    errorPort.listen((raw) => _handleUnhandledWorkerError(generation, raw));

    final isolate = await Isolate.spawn<List<Object?>>(
      _sherpaWorkerMain,
      [
        _receivePort.sendPort,
        files,
        generation,
        _forcedProcessingDelayMs,
        applicationLocale.languageCode,
      ],
      debugName: 'momentai-sherpa-asr-$generation',
      errorsAreFatal: true,
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
    );
    if (generation == _workerGeneration) _worker = isolate;
    await ready.future.timeout(const Duration(seconds: 30));
  }

  Future<void> _crashCurrentWorkerForTest() async {
    final isolate = _worker;
    final commands = _commands;
    if (isolate == null || commands == null) {
      throw StateError('ASR Worker is unavailable for crash injection.');
    }
    final generation = _workerGeneration;
    _expectedExitGenerations.add(generation);
    final exited = _exitCompleters[generation];
    final nativeReleased = _nativeReleaseCompleters[generation];
    commands.send({'type': 'prepareCrash'});
    try {
      if (nativeReleased == null) {
        throw StateError('Worker native-release acknowledgement is missing.');
      }
      await nativeReleased.future.timeout(_workerShutdownTimeout);
      if (!_nativeReleasedGenerations.contains(generation)) {
        throw StateError('Worker did not confirm native-resource release.');
      }
      commands.send({'type': 'triggerCrash'});
      if (exited != null) {
        await exited.future.timeout(_workerShutdownTimeout);
      }
    } catch (error) {
      await _forceKillWorker(
        isolate,
        generation: generation,
        exited: exited,
        reason: 'injected_crash_timeout',
      );
      _setState(
        TranscriptionWorkerStatus.catchUpRequired,
        message: l10n.workerCrashInjectionCouldNotReleaseNative,
      );
    }
  }

  Future<void> _stopCurrentWorkerGracefully({required String reason}) async {
    final isolate = _worker;
    if (isolate == null) return;
    final generation = _workerGeneration;
    final commands = _commands;
    final exited = _exitCompleters[generation];
    final nativeReleased = _nativeReleaseCompleters[generation];
    _expectedExitGenerations.add(generation);

    if (commands == null || nativeReleased == null) {
      await _forceKillWorker(
        isolate,
        generation: generation,
        exited: exited,
        reason: '${reason}_worker_unresponsive',
      );
      return;
    }

    commands.send({'type': 'dispose', 'reason': reason});
    try {
      await nativeReleased.future.timeout(_workerShutdownTimeout);
      if (!_nativeReleasedGenerations.contains(generation)) {
        throw StateError('Worker did not confirm native-resource release.');
      }
      _gracefulWorkerStopCount += 1;
      commands.send({'type': 'exit'});
      if (exited != null) {
        await exited.future.timeout(_workerShutdownTimeout);
      }
    } catch (_) {
      await _forceKillWorker(
        isolate,
        generation: generation,
        exited: exited,
        reason: '${reason}_timeout',
      );
    }
  }

  Future<void> _forceKillWorker(
    Isolate isolate, {
    required int generation,
    required Completer<void>? exited,
    required String reason,
  }) async {
    if (!(exited?.isCompleted ?? false)) {
      _forcedWorkerKillCount += 1;
      _emitDiagnostic(
        'asr_worker_forced_kill',
        payload: {'workerGeneration': generation, 'reason': reason},
      );
      isolate.kill(priority: Isolate.immediate);
    }
    if (exited != null && !exited.isCompleted) {
      await exited.future.timeout(_workerShutdownTimeout);
    }
  }

  Future<void> _waitForCurrentExit() async {
    if (_commands != null) return;
    final exited = _exitCompleters[_workerGeneration];
    if (exited == null || exited.isCompleted) return;
    await exited.future.timeout(const Duration(seconds: 5));
  }

  void _handleWorkerExit(int generation) {
    _exitCompleters[generation]?.complete();
    final nativeReleased = _nativeReleaseCompleters[generation];
    if (!_nativeReleaseReportedGenerations.contains(generation) &&
        !_missingModelGenerations.contains(generation)) {
      _nativeResourceReleaseFailureCount += 1;
      _emitDiagnostic(
        'asr_worker_native_cleanup_unconfirmed',
        payload: {'workerGeneration': generation},
      );
    }
    if (!(nativeReleased?.isCompleted ?? true)) nativeReleased!.complete();
    _nativeReleaseCompleters.remove(generation);
    _exitPorts.remove(generation)?.close();
    _errorPorts.remove(generation)?.close();
    final wasExpected = _expectedExitGenerations.remove(generation);
    if (generation != _workerGeneration) return;
    _worker = null;
    _commands = null;
    _pendingChunks = 0;
    if (_disposed || wasExpected || _modelFaultActive) return;

    final context = _session;
    if (context == null) {
      _setState(
        TranscriptionWorkerStatus.failed,
        message: l10n.theTranscriptionWorkerExited,
      );
      return;
    }
    _workerFailureCount += 1;
    _emitDiagnostic(
      'asr_worker_crashed',
      payload: {'injected': false, 'workerGeneration': generation},
    );
    _setState(
      TranscriptionWorkerStatus.catchUpRequired,
      message: l10n.theTranscriptionWorkerExitedUnexpectedlyRestarting,
    );
    unawaited(_restartAfterUnexpectedExit(context));
  }

  Future<void> _restartAfterUnexpectedExit(
    TranscriptionSessionContext context,
  ) async {
    try {
      await _startWorker(missingModel: false);
      if (_session?.sessionId != context.sessionId) return;
      _workerRestartCount += 1;
      _sendStart(context);
      _emitDiagnostic(
        'asr_worker_restarted',
        payload: {'workerGeneration': _workerGeneration},
      );
      _setState(
        TranscriptionWorkerStatus.catchUpRequired,
        message: l10n.theTranscriptionWorkerRestartedMissingTextWill,
      );
    } catch (error) {
      _setState(
        TranscriptionWorkerStatus.failed,
        message: l10n.theTranscriptionWorkerCouldNotRestart((error).toString()),
      );
    }
  }

  void _handleUnhandledWorkerError(int generation, Object? raw) {
    if (generation != _workerGeneration || _disposed) return;
    _setState(
      TranscriptionWorkerStatus.failed,
      message: l10n.unhandledTranscriptionWorkerException((raw).toString()),
    );
  }

  void _handleWorkerMessage(Object? raw) {
    if (raw is! Map) return;
    final message = Map<Object?, Object?>.from(raw);
    final generation = _number(message['generation']);
    if (generation != _workerGeneration || _disposed) return;

    switch (message['type']) {
      case 'nativeResourcesReleased':
        final success = message['success'] == true;
        final firstReport = _nativeReleaseReportedGenerations.add(generation);
        if (firstReport) {
          if (success) {
            _nativeReleasedGenerations.add(generation);
            _nativeResourceReleaseCount += 1;
            _emitDiagnostic(
              'asr_worker_native_resources_released',
              payload: {
                'workerGeneration': generation,
                'reason': message['reason']?.toString() ?? 'unknown',
              },
            );
          } else {
            _nativeResourceReleaseFailureCount += 1;
            _emitDiagnostic(
              'asr_worker_native_cleanup_failed',
              payload: {
                'workerGeneration': generation,
                'reason': message['reason']?.toString() ?? 'unknown',
                'error': message['error']?.toString() ?? 'unknown',
              },
            );
          }
        }
        final released = _nativeReleaseCompleters[generation];
        if (!(released?.isCompleted ?? true)) released!.complete();
      case 'ready':
        _commands = message['commands'] as SendPort;
        _runtimeVersion = message['version']?.toString() ?? '';
        _setState(
          _session == null
              ? TranscriptionWorkerStatus.ready
              : TranscriptionWorkerStatus.catchUpRequired,
          message: l10n.sherpaOnnxWorkerIsReady(
            (_runtimeVersion).toString(),
            (generation).toString(),
          ),
        );
        if (!(_workerReady?.isCompleted ?? true)) _workerReady!.complete();
      case 'ack':
        _pendingChunks = (_pendingChunks - 1).clamp(0, queueCapacity);
        _lastTranscribedSample = _number(message['endSample']);
        // Catch-up is intentionally idempotent. Count the unique contiguous
        // high-water instead of summing replayed work if a boundary Chunk is
        // ever submitted twice.
        _processedSamples = math.max(_processedSamples, _lastTranscribedSample);
        _decodeMicroseconds += _number(message['decodeMicroseconds']);
        _peakRssBytes = math.max(_peakRssBytes, ProcessInfo.currentRss);
        _setState(TranscriptionWorkerStatus.transcribing);
      case 'partial':
        final session = _session;
        if (session == null) return;
        _partials.add(
          TranscriptPartial(
            sessionId: session.sessionId,
            startSample: _number(message['startSample']),
            endSample: _number(message['endSample']),
            text: message['text']?.toString() ?? '',
          ),
        );
      case 'segment':
        final session = _session;
        if (session == null) return;
        final segmentId = message['segmentId']?.toString() ?? '';
        final text = message['text']?.toString() ?? '';
        _finalSegmentIds.add(segmentId);
        _segments.add(
          TranscriptSegment(
            segmentId: segmentId,
            sessionId: session.sessionId,
            directory: session.directory,
            startSample: _number(message['startSample']),
            endSample: _number(message['endSample']),
            text: text,
            rawText: message['rawText']?.toString() ?? text,
            language: 'zh',
            source: 'sherpa_onnx',
            modelId: _activeModelId,
            isFinal: true,
          ),
        );
      case 'ended':
        unawaited(_writeProbe('completed'));
        _scheduleStableRssProbe();
        if (!(_ended?.isCompleted ?? true)) _ended!.complete();
      case 'failed':
        final error = StateError(
          message['message']?.toString() ?? 'ASR Worker failed.',
        );
        _commands = null;
        _pendingChunks = 0;
        _workerFailureCount += 1;
        final missingModel = _missingModelGenerations.contains(generation);
        if (missingModel) {
          _emitDiagnostic(
            'asr_model_unavailable',
            payload: {'workerGeneration': generation, 'error': '$error'},
          );
        }
        _setState(
          TranscriptionWorkerStatus.failed,
          message: missingModel
              ? l10n.aMissingModelCausedInitializationToFail
              : l10n.theTranscriptionWorkerFailed((error).toString()),
        );
        unawaited(_writeProbe('failed', error: '$error'));
        if (!(_workerReady?.isCompleted ?? true)) {
          _workerReady!.completeError(error);
        }
        if (!(_ended?.isCompleted ?? true)) _ended!.completeError(error);
    }
  }

  void _sendStart(TranscriptionSessionContext context) {
    final commands = _commands;
    if (commands == null) throw StateError('ASR Worker is unavailable.');
    commands.send({
      'type': 'start',
      'sessionId': context.sessionId,
      'directory': context.directory,
      'sampleRate': context.sampleRate,
    });
  }

  TranscriptionSessionContext _requireActiveSession() {
    final context = _session;
    if (context == null) {
      throw StateError('Start a recording before injecting an ASR fault.');
    }
    return context;
  }

  void _emitDiagnostic(
    String type, {
    int? sampleOffset,
    Map<String, Object?> payload = const {},
  }) {
    if (_diagnosticEvents.isClosed) return;
    _diagnosticEvents.add(
      TranscriptionDiagnosticEvent(
        type: type,
        sampleOffset: sampleOffset ?? _lastTranscribedSample,
        payload: {
          ...payload,
          'lastTranscribedSample': _lastTranscribedSample,
          'processedSamples': _processedSamples,
        },
      ),
    );
  }

  void _setState(TranscriptionWorkerStatus status, {String? message}) {
    _status = status;
    if (_states.isClosed) return;
    _states.add(
      TranscriptionWorkerState(
        status: _status,
        pendingChunks: _pendingChunks,
        lastTranscribedSample: _lastTranscribedSample,
        message: message,
      ),
    );
  }

  Future<void> _writeProbe(String status, {String? error}) {
    final globalPath = _probePath;
    if (globalPath == null || globalPath.isEmpty) {
      return _probeWrites;
    }
    final currentRssBytes = ProcessInfo.currentRss;
    _peakRssBytes = math.max(_peakRssBytes, currentRssBytes);
    final sessionStartRssBytes = _sessionStartRssBytes == 0
        ? currentRssBytes
        : _sessionStartRssBytes;
    final audioMicroseconds = _processedSamples * 1000000 / 16000;
    final realTimeFactor = audioMicroseconds == 0
        ? 0.0
        : _decodeMicroseconds / audioMicroseconds;
    final payload = <String, Object?>{
      'status': status,
      'modelId': _activeModelId,
      'runtimeVersion': _runtimeVersion,
      'modelInitializationMs': _modelInitializationMs,
      'sessionId': _metricsSessionId,
      'processedSamples': _processedSamples,
      'lastTranscribedSample': _lastTranscribedSample,
      'decodeMs': _decodeMicroseconds / 1000,
      'realTimeFactor': realTimeFactor,
      'finalSegmentCount': _finalSegmentIds.length,
      'pendingChunks': _pendingChunks,
      'peakRssBytes': _peakRssBytes,
      'currentRssBytes': currentRssBytes,
      'sessionStartRssBytes': sessionStartRssBytes,
      'rssGrowthBytes': currentRssBytes - sessionStartRssBytes,
      'workerGeneration': _workerGeneration,
      'workerFailureCount': _workerFailureCount,
      'workerRestartCount': _workerRestartCount,
      'nativeResourceReleaseCount': _nativeResourceReleaseCount,
      'nativeResourceReleaseFailureCount': _nativeResourceReleaseFailureCount,
      'gracefulWorkerStopCount': _gracefulWorkerStopCount,
      'forcedWorkerKillCount': _forcedWorkerKillCount,
      'queueOverflowCount': _queueOverflowCount,
      'maxQueueDepth': _maxQueueDepth,
      'forcedProcessingDelayMs': _forcedProcessingDelayMs,
      'modelFaultActive': _modelFaultActive,
      'updatedAtWall': DateTime.now().toIso8601String(),
      'error': ?error,
    };
    final paths = <String>{globalPath};
    final metricsDirectory = _metricsDirectory;
    if (_metricsSessionId != null &&
        metricsDirectory != null &&
        metricsDirectory.isNotEmpty) {
      paths.add('$metricsDirectory/stage1_asr_probe.json');
    }

    return _enqueueProbeWrite(paths, payload);
  }

  void _scheduleStableRssProbe() {
    final sessionId = _metricsSessionId;
    final directory = _metricsDirectory;
    if (sessionId == null || directory == null || directory.isEmpty) return;
    final scheduledAt = DateTime.now();
    final sessionStartRssBytes = _sessionStartRssBytes;
    final peakRssBytes = _peakRssBytes;
    final completedRssBytes = ProcessInfo.currentRss;
    final processedSamples = _processedSamples;
    final lastTranscribedSample = _lastTranscribedSample;
    late final Timer timer;
    timer = Timer(_stableRssDelay, () {
      _stableRssTimers.remove(timer);
      if (_disposed) return;
      final activeSessionId = _session?.sessionId;
      final stableRssBytes = ProcessInfo.currentRss;
      final valid = _metricsSessionId == sessionId && activeSessionId == null;
      unawaited(
        _enqueueProbeWrite(
          {'$directory/stage1_rss_stable_probe.json'},
          {
            'status': valid ? 'stable' : 'contaminated',
            'valid': valid,
            'sessionId': sessionId,
            'activeSessionId': activeSessionId,
            'delayMs': _stableRssDelay.inMilliseconds,
            'scheduledAtWall': scheduledAt.toIso8601String(),
            'measuredAtWall': DateTime.now().toIso8601String(),
            'processedSamples': processedSamples,
            'lastTranscribedSample': lastTranscribedSample,
            'sessionStartRssBytes': sessionStartRssBytes,
            'peakRssBytes': peakRssBytes,
            'completedRssBytes': completedRssBytes,
            'stableRssBytes': stableRssBytes,
            'rssGrowthBytes': stableRssBytes - sessionStartRssBytes,
          },
        ),
      );
    });
    _stableRssTimers.add(timer);
  }

  Future<void> _enqueueProbeWrite(
    Set<String> paths,
    Map<String, Object?> payload,
  ) {
    final encoded = jsonEncode(payload);
    // Capture both the payload and destinations before queuing the write. A
    // subsequent Session may start before this low-priority diagnostic I/O is
    // scheduled, but it must never overwrite the previous Session's metrics.
    _probeWrites = _probeWrites.then((_) async {
      for (final path in paths) {
        try {
          final temporary = File('$path.part');
          await temporary.writeAsString(encoded, flush: true);
          await temporary.rename(path);
        } catch (_) {
          // Diagnostic probes must never affect recording or transcription.
        }
      }
    });
    return _probeWrites;
  }
}

Map<String, String> _workerModelFiles(RealtimeModelFiles model) {
  String requiredPath(String logicalName) {
    final value = model.paths[logicalName];
    if (value == null || value.isEmpty) {
      throw StateError(l10n.missingLiveModelFile((logicalName).toString()));
    }
    return value;
  }

  return {
    _modelIdKey: model.modelId,
    _encoderName: requiredPath('encoder'),
    _decoderName: requiredPath('decoder'),
    _joinerName: requiredPath('joiner'),
    _tokensName: requiredPath('tokens'),
  };
}

void _sherpaWorkerMain(List<Object?> arguments) {
  setApplicationLanguage(arguments[4]! as String);
  final output = arguments[0]! as SendPort;
  final modelFiles = Map<String, String>.from(arguments[1]! as Map);
  final generation = arguments[2]! as int;
  var processingDelayMs = arguments[3]! as int;
  final commands = ReceivePort();

  void send(String type, [Map<String, Object?> payload = const {}]) {
    output.send({'type': type, 'generation': generation, ...payload});
  }

  try {
    sherpa.initBindings();
    final model = sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: modelFiles[_encoderName]!,
        decoder: modelFiles[_decoderName]!,
        joiner: modelFiles[_joinerName]!,
      ),
      tokens: modelFiles[_tokensName]!,
      numThreads: 1,
      debug: false,
    );
    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: model,
        decodingMethod: 'greedy_search',
        enableEndpoint: true,
      ),
    );
    sherpa.OnlineStream? stream;
    String sessionId = '';
    int? segmentStartSample;
    int lastEndSample = 0;
    var workerFailed = false;
    var nativeResourcesReleased = false;
    _PendingUtf8BoundarySegment? pendingBoundarySegment;
    var stripLeadingReplacementForCurrentSegment = false;

    void sendFinalSegment(_PendingUtf8BoundarySegment segment, String text) {
      final normalized = text.trim();
      if (normalized.isEmpty || segment.endSample <= segment.startSample) {
        return;
      }
      send('segment', {
        'segmentId': segment.segmentId,
        'startSample': segment.startSample,
        'endSample': segment.endSample,
        'text': normalized,
        'rawText': segment.rawText,
      });
    }

    void flushPendingBoundarySegment() {
      final pending = pendingBoundarySegment;
      if (pending == null) return;
      sendFinalSegment(
        pending,
        _stripTrailingReplacementCharacters(pending.rawText),
      );
      pendingBoundarySegment = null;
    }

    void releaseNativeResources(String reason) {
      if (nativeResourcesReleased) return;
      final cleanupErrors = <String>[];
      final active = stream;
      stream = null;
      try {
        active?.free();
      } catch (error) {
        cleanupErrors.add('stream: $error');
      }
      try {
        recognizer.free();
      } catch (error) {
        cleanupErrors.add('recognizer: $error');
      }
      nativeResourcesReleased = true;
      send('nativeResourcesReleased', {
        'reason': reason,
        'success': cleanupErrors.isEmpty,
        if (cleanupErrors.isNotEmpty) 'error': cleanupErrors.join('; '),
      });
      if (cleanupErrors.isNotEmpty) {
        throw StateError(cleanupErrors.join('; '));
      }
    }

    void emitResult({required bool finalResult}) {
      final active = stream;
      if (active == null) return;
      final result = recognizer.getResult(active);
      final rawText = result.text.trim();
      final startSample = segmentStartSample ?? lastEndSample;

      final pending = pendingBoundarySegment;
      if (pending != null && rawText.isNotEmpty) {
        final repair = repairUtf8ByteFallbackBoundary(
          previousText: pending.rawText,
          previousTokens: pending.tokens,
          nextText: rawText,
          nextTokens: result.tokens,
        );
        if (repair != null) {
          sendFinalSegment(pending, repair.previousText);
          pendingBoundarySegment = null;
          stripLeadingReplacementForCurrentSegment = true;
        }
      }

      if (finalResult) {
        if (pendingBoundarySegment != null) {
          flushPendingBoundarySegment();
          if (_hasLeadingReplacementCharacters(rawText)) {
            stripLeadingReplacementForCurrentSegment = true;
          }
        }
        final text = stripLeadingReplacementForCurrentSegment
            ? _stripLeadingReplacementCharacters(rawText)
            : rawText;
        if (rawText.isNotEmpty && lastEndSample > startSample) {
          final current = _PendingUtf8BoundarySegment(
            segmentId: '${sessionId}_seg_${startSample}_$lastEndSample',
            startSample: startSample,
            endSample: lastEndSample,
            rawText: rawText,
            tokens: List<String>.from(result.tokens),
          );
          if (_hasTrailingReplacementCharacters(rawText)) {
            pendingBoundarySegment = current;
          } else {
            sendFinalSegment(current, text);
          }
        }
        segmentStartSample = lastEndSample;
        stripLeadingReplacementForCurrentSegment = false;
      } else {
        final text = _stripLeadingReplacementCharacters(rawText);
        if (text.isEmpty) return;
        send('partial', {
          'startSample': startSample,
          'endSample': lastEndSample,
          'text': text,
        });
      }
    }

    send('ready', {
      'commands': commands.sendPort,
      'version': sherpa.getVersion(),
    });

    commands.listen((Object? raw) {
      if (workerFailed || raw is! Map) return;
      final message = Map<Object?, Object?>.from(raw);
      try {
        switch (message['type']) {
          case 'start':
            pendingBoundarySegment = null;
            stream?.free();
            stream = recognizer.createStream();
            sessionId = message['sessionId']?.toString() ?? '';
            segmentStartSample = null;
            lastEndSample = 0;
            stripLeadingReplacementForCurrentSegment = false;
          case 'setDelay':
            processingDelayMs = _number(message['delayMs']).clamp(0, 5000);
          case 'chunk':
            final active = stream;
            if (active == null) throw StateError('ASR session is not open.');
            final startSample = _number(message['startSample']);
            lastEndSample = _number(message['endSample']);
            final fileStartSample = _number(
              message['fileStartSample'],
              fallback: startSample,
            );
            final skipSamples = startSample - fileStartSample;
            final sampleCount = lastEndSample - startSample;
            if (skipSamples < 0 || sampleCount <= 0) {
              throw StateError(
                'Invalid ASR Chunk range: file=$fileStartSample, '
                'start=$startSample, end=$lastEndSample.',
              );
            }
            segmentStartSample ??= startSample;
            final decodeWatch = Stopwatch()..start();
            final samples = _readPCM16(
              message['path']!.toString(),
              skipSamples: skipSamples,
              sampleCount: sampleCount,
            );
            active.acceptWaveform(
              samples: samples,
              sampleRate: _number(message['sampleRate'], fallback: 16000),
            );
            while (recognizer.isReady(active)) {
              recognizer.decode(active);
            }
            emitResult(finalResult: false);
            if (recognizer.isEndpoint(active)) {
              emitResult(finalResult: true);
              recognizer.reset(active);
            }
            if (processingDelayMs > 0) {
              sleep(Duration(milliseconds: processingDelayMs));
            }
            decodeWatch.stop();
            send('ack', {
              'endSample': lastEndSample,
              'sampleCount': lastEndSample - startSample,
              'decodeMicroseconds': decodeWatch.elapsedMicroseconds,
            });
          case 'end':
            final active = stream;
            if (active != null) {
              active.inputFinished();
              while (recognizer.isReady(active)) {
                recognizer.decode(active);
              }
              emitResult(finalResult: true);
              flushPendingBoundarySegment();
              active.free();
              stream = null;
            }
            send('ended');
          case 'dispose':
            releaseNativeResources(
              message['reason']?.toString() ?? 'graceful_dispose',
            );
          case 'exit':
            if (!nativeResourcesReleased) {
              throw StateError('Worker exit requested before native cleanup.');
            }
            commands.close();
          case 'prepareCrash':
            releaseNativeResources('injected_unhandled_exception');
          case 'triggerCrash':
            if (!nativeResourcesReleased) {
              throw StateError('Worker crash requested before native cleanup.');
            }
            commands.close();
            Timer.run(
              () => throw StateError(
                'Injected unhandled ASR Worker exception after native cleanup.',
              ),
            );
        }
      } catch (error, stackTrace) {
        workerFailed = true;
        var cleanupMessage = '';
        try {
          releaseNativeResources('command_failure');
        } catch (cleanupError) {
          cleanupMessage = '\nNative cleanup failed: $cleanupError';
        }
        send('failed', {
          'phase': 'command',
          'message': '$error\n$stackTrace$cleanupMessage',
        });
        commands.close();
      }
    });
  } catch (error, stackTrace) {
    send('failed', {
      'phase': 'initialization',
      'message': '$error\n$stackTrace',
    });
    commands.close();
  }
}

class _PendingUtf8BoundarySegment {
  const _PendingUtf8BoundarySegment({
    required this.segmentId,
    required this.startSample,
    required this.endSample,
    required this.rawText,
    required this.tokens,
  });

  final String segmentId;
  final int startSample;
  final int endSample;
  final String rawText;
  final List<String> tokens;
}

@visibleForTesting
({String previousText, String nextText})? repairUtf8ByteFallbackBoundary({
  required String previousText,
  required List<String> previousTokens,
  required String nextText,
  required List<String> nextTokens,
}) {
  if (!_hasTrailingReplacementCharacters(previousText) ||
      !_hasLeadingReplacementCharacters(nextText)) {
    return null;
  }
  final previousBytes = _trailingByteFallbackTokens(previousTokens);
  final nextBytes = _leadingByteFallbackTokens(nextTokens);
  for (
    var previousCount = 1;
    previousCount <= math.min(3, previousBytes.length);
    previousCount += 1
  ) {
    for (
      var nextCount = 1;
      nextCount <= math.min(3, nextBytes.length);
      nextCount += 1
    ) {
      final bytes = <int>[
        ...previousBytes.sublist(previousBytes.length - previousCount),
        ...nextBytes.take(nextCount),
      ];
      if (bytes.length > 4) continue;
      try {
        final decoded = utf8.decode(bytes, allowMalformed: false);
        if (decoded.runes.length != 1 || decoded.runes.single == 0xfffd) {
          continue;
        }
        return (
          previousText:
              '${_stripTrailingReplacementCharacters(previousText)}$decoded',
          nextText: _stripLeadingReplacementCharacters(nextText),
        );
      } on FormatException {
        // Try the next possible split of the byte-fallback token sequence.
      }
    }
  }
  return null;
}

bool _hasLeadingReplacementCharacters(String text) =>
    text.isNotEmpty && text.codeUnitAt(0) == 0xfffd;

bool _hasTrailingReplacementCharacters(String text) =>
    text.isNotEmpty && text.codeUnitAt(text.length - 1) == 0xfffd;

String _stripLeadingReplacementCharacters(String text) {
  var start = 0;
  while (start < text.length && text.codeUnitAt(start) == 0xfffd) {
    start += 1;
  }
  return text.substring(start);
}

String _stripTrailingReplacementCharacters(String text) {
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0xfffd) {
    end -= 1;
  }
  return text.substring(0, end);
}

List<int> _leadingByteFallbackTokens(List<String> tokens) {
  final result = <int>[];
  for (final token in tokens) {
    if (result.isEmpty && token == '▁') continue;
    final byte = _byteFallbackToken(token);
    if (byte == null) break;
    result.add(byte);
  }
  return result;
}

List<int> _trailingByteFallbackTokens(List<String> tokens) {
  final result = <int>[];
  for (final token in tokens.reversed) {
    final byte = _byteFallbackToken(token);
    if (byte == null) break;
    result.insert(0, byte);
  }
  return result;
}

int? _byteFallbackToken(String token) {
  final match = RegExp(r'^(?:▁)?<0x([0-9a-fA-F]{2})>$').firstMatch(token);
  if (match == null) return null;
  return int.parse(match.group(1)!, radix: 16);
}

Float32List _readPCM16(String path, {int skipSamples = 0, int? sampleCount}) {
  if (skipSamples < 0 || (sampleCount != null && sampleCount < 0)) {
    throw RangeError('PCM16 slice cannot use a negative sample range.');
  }
  final handle = File(path).openSync();
  late final Uint8List bytes;
  try {
    final byteLength = handle.lengthSync();
    if (byteLength.isOdd) {
      throw const FormatException('PCM16 file has an odd byte length.');
    }
    final availableSamples = byteLength ~/ 2 - skipSamples;
    final requestedSamples = sampleCount ?? availableSamples;
    if (availableSamples < 0 || requestedSamples > availableSamples) {
      throw RangeError(
        'PCM16 slice exceeds file: skip=$skipSamples, '
        'count=$requestedSamples, total=${byteLength ~/ 2}.',
      );
    }
    handle.setPositionSync(skipSamples * 2);
    bytes = handle.readSync(requestedSamples * 2);
    if (bytes.length != requestedSamples * 2) {
      throw StateError('PCM16 slice could not be read completely.');
    }
  } finally {
    handle.closeSync();
  }
  final view = ByteData.sublistView(bytes);
  final samples = Float32List(bytes.length ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = view.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return samples;
}

int _number(Object? value, {int fallback = 0}) =>
    value is num ? value.round() : int.tryParse('$value') ?? fallback;
