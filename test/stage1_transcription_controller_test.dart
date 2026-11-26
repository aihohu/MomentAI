import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/core/asr/sherpa_onnx_transcription_provider.dart';
import 'package:momentai/core/asr/stage1_transcription_controller.dart';
import 'package:momentai/core/asr/transcription_provider.dart';
import 'package:momentai/core/session/session_experience_gateway.dart';
import 'package:momentai/domain/audio/committed_audio_chunk.dart';
import 'package:momentai/domain/audio/playback_snapshot.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/domain/transcript/transcript_segment.dart';
import 'package:momentai/poc/poc_bridge.dart';

void main() {
  test(
    'slow refinement cannot block the next recording and failures do not poison the queue',
    () async {
      final bridge = _ControllerBridge();
      final provider = _ControllerProvider();
      final service = _SlowRefinement();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
        fullTextRefinementService: service,
      );
      await controller.initialize();
      bridge.emit(_snapshot(state: 'recording'));
      bridge.emit(_snapshot(state: 'completed'));
      await controller.drainRuntimeEvents().timeout(const Duration(seconds: 2));
      expect(controller.activeSessionId, isNull);
      expect(controller.isSessionFinishing('session_stage1'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.requests.single.sessionId, 'session_stage1');
      final gateway = ProductSessionExperienceGateway(
        bridge,
        transcriptionController: controller,
      );
      expect(
        gateway.transcriptionPhase('session_stage1'),
        TranscriptionPhase.refining,
      );
      expect(gateway.transcriptionPhase('other'), TranscriptionPhase.idle);
      bridge.emit(_snapshot(state: 'recording', sessionId: 'second'));
      bridge.emit(
        _snapshot(
          state: 'recording',
          sessionId: 'second',
          chunk: const CommittedAudioChunk(
            sessionId: 'second',
            directory: '/tmp/second',
            index: 0,
            path: '/tmp/second/audio/chunk_0.pcm',
            startSample: 0,
            endSample: 16000,
            sampleRate: 16000,
          ),
        ),
      );
      await controller.drainRuntimeEvents().timeout(const Duration(seconds: 2));
      expect(controller.activeSessionId, 'second');
      expect(provider.liveChunkIndexes, [0]);
      expect(
        gateway.transcriptionPhase('second'),
        TranscriptionPhase.transcribing,
      );
      service.first.completeError(StateError('test refinement failure'));
      await controller.drainRefinements();
      expect(controller.isSessionFinishing('session_stage1'), isFalse);
      expect(controller.activeSessionId, 'second');
      bridge.emit(_snapshot(state: 'completed', sessionId: 'second'));
      await controller.drainRuntimeEvents();
      await controller.drainRefinements();
      expect(service.requests.map((r) => r.sessionId), [
        'session_stage1',
        'second',
      ]);
      expect(controller.hasPendingRefinements, isFalse);
      controller.dispose();
      await bridge.close();
    },
  );

  test(
    'a second saved recording reports queued refinement until its turn',
    () async {
      final bridge = _ControllerBridge();
      final service = _SlowRefinement();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: _ControllerProvider(),
        fullTextRefinementService: service,
      );
      final gateway = ProductSessionExperienceGateway(
        bridge,
        transcriptionController: controller,
      );
      await controller.initialize();
      bridge.emit(_snapshot(state: 'recording'));
      bridge.emit(_snapshot(state: 'completed'));
      await controller.drainRuntimeEvents();
      bridge.emit(_snapshot(state: 'recording', sessionId: 'second'));
      bridge.emit(_snapshot(state: 'completed', sessionId: 'second'));
      await controller.drainRuntimeEvents();
      expect(
        gateway.transcriptionPhase('session_stage1'),
        TranscriptionPhase.refining,
      );
      expect(
        gateway.transcriptionPhase('second'),
        TranscriptionPhase.waitingForRefinement,
      );
      service.first.completeError(StateError('test failure'));
      await controller.drainRefinements();
      expect(
        gateway.transcriptionPhase('session_stage1'),
        TranscriptionPhase.idle,
      );
      expect(gateway.transcriptionPhase('second'), TranscriptionPhase.idle);
      controller.dispose();
      await bridge.close();
    },
  );

  test(
    'manual refinement uses saved sources without live ASR and blocks duplicate requests',
    () async {
      final bridge = _ControllerBridge();
      final provider = _ControllerProvider();
      final service = _SlowRefinement();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
        fullTextRefinementService: service,
      );
      final original = TimelineItem.fromMap({
        'kind': 'transcript',
        'segmentId': 'saved',
        'sampleOffset': 16000,
        'endSample': 32000,
        'text': 'Saved source',
      });
      bridge.timelineItems.add(original);
      controller.timeline = [
        TimelineItem.fromMap({'text': 'Unrelated recording'}),
      ];
      final job = controller.refineSavedSession(
        sessionId: 'saved',
        directory: '/tmp/saved',
        forceRebuild: true,
      );
      final result = expectLater(job, throwsStateError);
      expect(controller.isRefinementPending('saved'), isTrue);
      await expectLater(
        controller.refineSavedSession(
          sessionId: 'saved',
          directory: '/tmp/saved',
        ),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.requests.single.timeline.single, same(original));
      expect(service.requests.single.forceRebuild, isTrue);
      expect(provider.initializeCount, 0);
      expect(provider.startCount, 0);
      expect(bridge.persistedEventTypes, isEmpty);
      expect(controller.activeSessionId, isNull);
      service.first.completeError(StateError('simulated failure'));
      await result;
      await controller.drainRefinements();
      expect(controller.isSessionFinishing('saved'), isFalse);
      expect(bridge.timelineItems, [original]);
      await controller.refineSavedSession(
        sessionId: 'saved',
        directory: '/tmp/saved',
      );
      expect(service.requests, hasLength(2));
      controller.activeSessionId = 'recording';
      await expectLater(
        controller.refineSavedSession(
          sessionId: 'saved',
          directory: '/tmp/saved',
        ),
        throwsStateError,
      );
      controller.dispose();
      await bridge.close();
    },
  );

  test('repairs a UTF-8 byte-fallback character split at an endpoint', () {
    final oneByteThenTwo = repairUtf8ByteFallbackBoundary(
      previousText: '字斟句�',
      previousTokens: const ['▁字', '▁斟', '▁句', '<0xE9>'],
      nextText: '��就是因为',
      nextTokens: const ['<0x85>', '<0x8C>', '▁就', '▁是'],
    );
    final twoBytesThenOne = repairUtf8ByteFallbackBoundary(
      previousText: '对��',
      previousTokens: const ['▁对', '<0xE7>', '<0x9F>'],
      nextText: '�铁生',
      nextTokens: const ['<0xB3>', '▁铁', '▁生'],
    );

    expect(oneByteThenTwo?.previousText, '字斟句酌');
    expect(oneByteThenTwo?.nextText, '就是因为');
    expect(twoBytesThenOne?.previousText, '对石');
    expect(twoBytesThenOne?.nextText, '铁生');
  });

  test('does not guess a malformed boundary without valid byte tokens', () {
    final result = repairUtf8ByteFallbackBoundary(
      previousText: '上一段�',
      previousTokens: const ['▁上', '<0xFF>'],
      nextText: '�下一段',
      nextTokens: const ['<0xFF>', '▁下'],
    );

    expect(result, isNull);
  });

  test('initialization callers join the same model-loading future', () async {
    final bridge = _ControllerBridge();
    final provider = _ControllerProvider(pauseInitialization: true);
    final controller = Stage1TranscriptionController(
      bridge: bridge,
      provider: provider,
    );

    final first = controller.initialize();
    final second = controller.initialize();
    expect(identical(first, second), isTrue);
    expect(provider.initializeCount, 1);
    provider.completeInitialization();
    await Future.wait([first, second]);

    controller.dispose();
    await bridge.close();
  });

  test('a committed Chunk can expose an exact suffix without replay', () {
    final chunk = _chunk(1);
    final suffix = chunk.sliceFrom(24000);

    expect(suffix.startSample, 24000);
    expect(suffix.endSample, 32000);
    expect(suffix.fileStartSample, 16000);
    expect(suffix.sampleCount, 8000);
    expect(suffix.toMessage()['fileStartSample'], 16000);
  });

  test(
    'reattaching to a live recorder catches up from durable text on stop',
    () async {
      final bridge = _ControllerBridge()
        ..timelineItems.add(
          TimelineItem.fromMap({
            'kind': 'transcript',
            'sampleOffset': 0,
            'endSample': 24000,
            'text': '已保存文字',
            'startMs': 0,
            'endMs': 1500,
          }),
        );
      final provider = _ControllerProvider(emitCatchUpSegment: true);
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
      );
      await controller.initialize();
      bridge.emit(
        PoCSnapshot.fromMap({
          'state': 'recording',
          'sessionId': 'session_stage1',
          'directory': '/tmp/session_stage1',
          'committedMs': 3000,
          'capturedMs': 3000,
        }),
      );
      await controller.drainRuntimeEvents();
      expect(controller.catchUpRequired, isTrue);
      expect(controller.timeline.single.text, '已保存文字');
      bridge.emit(_snapshot(state: 'completed'));
      await controller.drainRuntimeEvents();
      expect(provider.catchUpChunks.first.startSample, 24000);
      expect(provider.catchUpChunks.last.endSample, 48000);
      expect(controller.catchUpRequired, isFalse);
      expect(controller.activeSessionId, isNull);
      controller.dispose();
      await bridge.close();
    },
  );

  test('recovered Session catch-up is exact and durably idempotent', () async {
    final bridge = _ControllerBridge()
      ..timelineItems.add(
        TimelineItem.fromMap({
          'kind': 'transcript',
          'eventId': 'segment_before_crash',
          'sampleOffset': 0,
          'endSample': 24000,
          'startMs': 0,
          'endMs': 1500,
          'text': '崩溃前转写',
        }),
      );
    final provider = _ControllerProvider(emitCatchUpSegment: true);
    final controller = Stage1TranscriptionController(
      bridge: bridge,
      provider: provider,
    );

    final first = await controller.recoverSessionTranscription(
      sessionId: 'session_stage1',
      directory: '/tmp/session_stage1',
    );

    expect(first.didCatchUp, isTrue);
    expect(first.fromSample, 24000);
    expect(first.toSample, 48000);
    expect(provider.catchUpChunks.map((chunk) => chunk.index), [1, 2]);
    expect(provider.catchUpChunks.first.startSample, 24000);
    expect(provider.catchUpChunks.first.fileStartSample, 16000);
    expect(provider.startCount, 1);
    expect(provider.endCount, 1);
    expect(bridge.persistedEventTypes, [
      'asr_recovery_catchup_started',
      'asr_recovery_catchup_completed',
    ]);
    expect(controller.timeline.where((item) => item.isTranscript).length, 2);
    expect(controller.activeSessionId, isNull);

    final second = await controller.recoverSessionTranscription(
      sessionId: 'session_stage1',
      directory: '/tmp/session_stage1',
    );

    expect(second.didCatchUp, isFalse);
    expect(second.fromSample, 48000);
    expect(provider.startCount, 1);
    expect(provider.endCount, 1);
    expect(bridge.persistedEventTypes.length, 2);
    expect(bridge.requestedAfterSamples, [24000, 48000]);
    expect(controller.timeline.length, bridge.timelineItems.length);
    // First recovery reads once before catch-up and once after all segment
    // commits. The idempotent second recovery needs only its initial read.
    expect(bridge.timelineCallCount, 3);

    controller.dispose();
    await bridge.close();
  });

  test(
    'recovery durably closes ASR when existing transcripts reach high-water',
    () async {
      final bridge = _ControllerBridge()
        ..timelineItems.add(
          TimelineItem.fromMap({
            'kind': 'transcript',
            'eventId': 'segment_complete_before_crash',
            'sampleOffset': 0,
            'endSample': 48000,
            'startMs': 0,
            'endMs': 3000,
            'text': '崩溃前已经完成的转写',
          }),
        );
      final provider = _RecoveryAwareControllerProvider();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
      );

      final first = await controller.recoverSessionTranscription(
        sessionId: 'session_stage1',
        directory: '/tmp/session_stage1',
      );

      expect(first.didCatchUp, isFalse);
      expect(first.fromSample, 48000);
      expect(provider.reconciledHighWater, 48000);
      expect(provider.reconciledFinalSegmentCount, 1);
      expect(provider.startCount, 0);
      expect(provider.endCount, 0);
      expect(bridge.persistedEventTypes, [
        'asr_recovery_catchup_started',
        'asr_recovery_catchup_completed',
      ]);

      final second = await controller.recoverSessionTranscription(
        sessionId: 'session_stage1',
        directory: '/tmp/session_stage1',
      );

      expect(second.didCatchUp, isFalse);
      expect(provider.reconcileCount, 1);
      expect(bridge.persistedEventTypes, hasLength(2));

      controller.dispose();
      await bridge.close();
    },
  );

  test(
    'timeline retries a transient database lock and clears stale warning',
    () async {
      final bridge = _ControllerBridge()..timelineFailuresRemaining = 3;
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: _ControllerProvider(),
      );
      await controller.initialize();

      await controller.refreshTimeline('/tmp/session_stage1');
      expect(controller.error, contains('Database is locked'));
      expect(bridge.timelineCallCount, 3);

      bridge.timelineItems.add(
        TimelineItem.fromMap({
          'kind': 'event',
          'eventId': 'event_after_retry',
          'type': 'session_recovered',
          'sampleOffset': 16000,
        }),
      );
      await controller.refreshTimeline('/tmp/session_stage1');

      expect(controller.error, isNull);
      expect(controller.timeline, hasLength(1));
      expect(bridge.timelineCallCount, 4);

      controller.dispose();
      await bridge.close();
    },
  );

  test('queue overflow becomes a contiguous suffix catch-up on stop', () async {
    final bridge = _ControllerBridge();
    final provider = _ControllerProvider();
    final controller = Stage1TranscriptionController(
      bridge: bridge,
      provider: provider,
    );
    await controller.initialize();

    bridge.emit(_snapshot(state: 'recording'));
    bridge.emit(_snapshot(state: 'recording', chunk: _chunk(0)));
    bridge.emit(_snapshot(state: 'recording', chunk: _chunk(1)));
    bridge.emit(_snapshot(state: 'recording', chunk: _chunk(2)));
    bridge.emit(_snapshot(state: 'completed', event: 'session_stopped'));
    await controller.drainRuntimeEvents();

    expect(provider.liveChunkIndexes, [0, 1]);
    expect(bridge.requestedAfterSample, 16000);
    expect(provider.catchUpChunkIndexes, [1, 2]);
    expect(provider.startCount, 2);
    expect(provider.endCount, 2);
    expect(controller.catchUpRequired, isFalse);

    controller.dispose();
    await bridge.close();
  });

  test('user pause and resume keep one live ASR session open', () async {
    final bridge = _ControllerBridge();
    final provider = _ControllerProvider();
    final controller = Stage1TranscriptionController(
      bridge: bridge,
      provider: provider,
    );
    await controller.initialize();

    bridge.emit(_snapshot(state: 'recording'));
    bridge.emit(_snapshot(state: 'paused', event: 'user_pause_began'));
    bridge.emit(_snapshot(state: 'recording', event: 'user_pause_ended'));
    await controller.drainRuntimeEvents();

    expect(provider.startCount, 1);
    expect(provider.endCount, 0);
    expect(controller.activeSessionId, 'session_stage1');
    expect(controller.catchUpRequired, isFalse);

    bridge.emit(_snapshot(state: 'completed', event: 'session_stopped'));
    await controller.drainRuntimeEvents();

    expect(provider.startCount, 1);
    expect(provider.endCount, 1);
    expect(controller.activeSessionId, isNull);

    controller.dispose();
    await bridge.close();
  });

  test(
    'controlled terminal state ends ASR without session_stopped event',
    () async {
      final bridge = _ControllerBridge();
      final provider = _ControllerProvider();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
      );
      await controller.initialize();

      bridge.emit(_snapshot(state: 'recording'));
      bridge.emit(_snapshot(state: 'recording', chunk: _chunk(0)));
      bridge.emit(
        _snapshot(
          state: 'completed_with_gaps',
          event: 'storage_pressure_controlled_stop',
        ),
      );
      await controller.drainRuntimeEvents();

      expect(provider.endCount, 1);
      expect(controller.activeSessionId, isNull);
      expect(controller.error, isNull);

      controller.dispose();
      await bridge.close();
    },
  );

  test(
    'worker replacement catch-up starts at the final drained high-water',
    () async {
      final bridge = _ControllerBridge();
      final provider = _ResilientControllerProvider();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
        enableFaultInjection: true,
      );
      await controller.initialize();
      bridge.emit(_snapshot(state: 'recording'));
      await controller.drainRuntimeEvents();

      await controller.injectWorkerCrashForTest();
      bridge.emit(_snapshot(state: 'completed', event: 'session_stopped'));
      await controller.drainRuntimeEvents();

      expect(bridge.requestedAfterSample, 16000);
      expect(provider.catchUpChunkIndexes, [1, 2]);

      controller.dispose();
      await bridge.close();
    },
  );

  test(
    'profile resilience controls invoke the real-provider contract and audit',
    () async {
      final bridge = _ControllerBridge();
      final provider = _ResilientControllerProvider();
      final controller = Stage1TranscriptionController(
        bridge: bridge,
        provider: provider,
        enableFaultInjection: true,
      );
      await controller.initialize();
      bridge.emit(_snapshot(state: 'recording'));
      await controller.drainRuntimeEvents();

      expect(controller.faultControlsAvailable, isTrue);
      expect(controller.canInjectFault, isTrue);

      await controller.injectWorkerCrashForTest();
      await controller.injectMissingModelForTest();
      expect(controller.modelFaultActive, isTrue);
      await controller.restoreModelForTest();
      await controller.toggleForcedOverflowForTest();
      expect(controller.forcedProcessingDelayMs, 2500);
      await controller.toggleForcedOverflowForTest();
      await controller.drainDiagnosticEvents();

      expect(provider.workerCrashCount, 1);
      expect(provider.missingModelCount, 1);
      expect(provider.restoreModelCount, 1);
      expect(provider.delayChanges, [2500, 0]);
      expect(
        bridge.persistedEventTypes,
        containsAll([
          'asr_worker_crash_injected',
          'asr_worker_native_resources_released',
          'asr_worker_crashed',
          'asr_worker_restarted',
          'asr_model_missing_injected',
          'asr_model_unavailable',
          'asr_model_restored',
          'asr_processing_delay_changed',
        ]),
      );

      controller.dispose();
      await bridge.close();
    },
  );
}

PoCSnapshot _snapshot({
  required String state,
  String sessionId = 'session_stage1',
  String? event,
  CommittedAudioChunk? chunk,
}) => PoCSnapshot(
  state: state,
  capturedMs: chunk?.endSample == null ? 0 : chunk!.endSample ~/ 16,
  committedMs: chunk?.endSample == null ? 0 : chunk!.endSample ~/ 16,
  rpoMs: 0,
  chunkCount: chunk == null ? 0 : chunk.index + 1,
  asrMode: 'normal',
  asrQueueDepth: 0,
  asrDroppedBuffers: 0,
  asrDroppedSamples: 0,
  asrFailedSamples: 0,
  directory: '/tmp/$sessionId',
  sessionId: sessionId,
  event: event,
  committedChunk: chunk,
);

CommittedAudioChunk _chunk(int index) => CommittedAudioChunk(
  sessionId: 'session_stage1',
  directory: '/tmp/session_stage1',
  index: index,
  path: '/tmp/session_stage1/audio/chunk_$index.pcm',
  startSample: index * 16000,
  endSample: (index + 1) * 16000,
  sampleRate: 16000,
);

class _ControllerBridge implements PoCBridge {
  @override
  Future<PlaybackSoundSettings> getPlaybackSound() async =>
      const PlaybackSoundSettings();
  @override
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  ) async => settings;

  final _events = StreamController<PoCSnapshot>.broadcast(sync: true);
  int? requestedAfterSample;
  final requestedAfterSamples = <int>[];
  final persistedEventTypes = <String>[];
  final timelineItems = <TimelineItem>[];
  var timelineFailuresRemaining = 0;
  var timelineCallCount = 0;

  void emit(PoCSnapshot snapshot) => _events.add(snapshot);

  Future<void> close() => _events.close();

  @override
  Stream<PoCSnapshot> get events => _events.stream;

  @override
  Stream<PlaybackSnapshot> get playbackEvents => const Stream.empty();

  @override
  Future<List<CommittedAudioChunk>> committedChunks(
    String directory, {
    int afterSample = 0,
  }) async {
    requestedAfterSample = afterSample;
    requestedAfterSamples.add(afterSample);
    return [
      _chunk(1),
      _chunk(2),
    ].where((chunk) => chunk.endSample > afterSample).toList(growable: false);
  }

  @override
  Future<void> commitTranscriptSegment(TranscriptSegment segment) async {
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'transcript',
        'eventId': segment.segmentId,
        'sampleOffset': segment.startSample,
        'endSample': segment.endSample,
        'startMs': segment.startMs,
        'endMs': segment.endMs,
        'text': segment.text,
      }),
    );
  }

  @override
  Future<void> commitStage1Event(
    String directory, {
    required String type,
    required int sampleOffset,
    Map<String, Object?> payload = const {},
  }) async {
    persistedEventTypes.add(type);
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'event',
        'eventId': 'event_${timelineItems.length}',
        'type': type,
        'sampleOffset': sampleOffset,
        'atMs': sampleOffset ~/ 16,
        'payload': payload,
      }),
    );
  }

  @override
  Future<List<TimelineItem>> timeline(String directory) async {
    timelineCallCount += 1;
    if (timelineFailuresRemaining > 0) {
      timelineFailuresRemaining -= 1;
      throw StateError('Database is locked');
    }
    return List<TimelineItem>.unmodifiable(timelineItems);
  }

  @override
  Future<SessionExportResult> exportSession(String directory) async =>
      throw UnimplementedError();

  @override
  Future<void> shareExport(String archivePath) async {}

  @override
  Future<Map<Object?, Object?>> openCamera() async => const {};

  @override
  Future<Map<Object?, Object?>> addBookmark() async => const {
    'eventId': 'evt_bookmark',
    'atMs': 1000,
  };

  @override
  Future<Map<Object?, Object?>> addThought(String text) async => {
    'eventId': 'evt_thought',
    'atMs': 1000,
    'text': text,
  };

  @override
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    required int sampleOffset,
    required String anchorId,
    required String anchorType,
  }) async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackSnapshot> pausePlayback() async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackSnapshot> resumePlayback() async => PlaybackSnapshot.idle();

  @override
  Future<PlaybackSnapshot> seekPlayback(int sampleOffset) async =>
      PlaybackSnapshot.idle();

  @override
  Future<PlaybackSnapshot> stopPlayback() async => PlaybackSnapshot.idle();

  @override
  Future<Map<Object?, Object?>> recover(String directory) async => const {};

  @override
  Future<List<RecoveryCandidate>> scanRecovery() async => const [];

  @override
  Future<void> injectAudioInterruptionForTest({int durationMs = 3000}) async {}

  @override
  Future<Map<Object?, Object?>> runInterruptionStressTest({
    int count = 100,
    int durationMs = 500,
    int settleMs = 250,
  }) async => const {};

  @override
  Future<PoCSnapshot> injectLowStorageForTest({
    int simulatedAvailableBytes = 64 * 1024 * 1024,
  }) async => PoCSnapshot.idle();

  @override
  Future<Map<Object?, Object?>> compatibilityReport() async => const {};

  @override
  Future<void> setASRMode(String mode) async {}

  @override
  Future<PoCSnapshot> snapshot() async => PoCSnapshot.idle();

  @override
  Future<PoCSnapshot> start({String title = 'Stage 1 Capture Alpha'}) async =>
      PoCSnapshot.idle();

  @override
  Future<PoCSnapshot> stop() async => PoCSnapshot.idle();

  @override
  Future<PoCSnapshot> pauseRecording() async => PoCSnapshot.idle();

  @override
  Future<PoCSnapshot> resumeRecording() async => PoCSnapshot.idle();

  @override
  Future<void> terminateForRecoveryTest() async {}
}

class _ControllerProvider implements TranscriptionProvider {
  _ControllerProvider({
    this.emitCatchUpSegment = false,
    this.pauseInitialization = false,
  });

  final bool emitCatchUpSegment;
  final bool pauseInitialization;
  final _partials = StreamController<TranscriptPartial>.broadcast();
  final _segments = StreamController<TranscriptSegment>.broadcast();
  final _states = StreamController<TranscriptionWorkerState>.broadcast();
  final liveChunkIndexes = <int>[];
  final catchUpChunkIndexes = <int>[];
  final catchUpChunks = <CommittedAudioChunk>[];
  final _initializationGate = Completer<void>();
  TranscriptionSessionContext? _context;
  var initializeCount = 0;
  var startCount = 0;
  var endCount = 0;

  @override
  Stream<TranscriptPartial> get partials => _partials.stream;

  @override
  Stream<TranscriptSegment> get segments => _segments.stream;

  @override
  Stream<TranscriptionWorkerState> get states => _states.stream;

  @override
  Future<void> initialize() async {
    initializeCount += 1;
    if (pauseInitialization) await _initializationGate.future;
    _states.add(
      const TranscriptionWorkerState(status: TranscriptionWorkerStatus.ready),
    );
  }

  @override
  Future<void> startSession(TranscriptionSessionContext context) async {
    startCount += 1;
    _context = context;
  }

  @override
  EnqueueResult tryEnqueue(CommittedAudioChunk chunk) {
    liveChunkIndexes.add(chunk.index);
    return chunk.index == 1 ? EnqueueResult.queueFull : EnqueueResult.accepted;
  }

  @override
  Future<void> transcribeCommittedChunks(
    List<CommittedAudioChunk> chunks,
  ) async {
    catchUpChunkIndexes.addAll(chunks.map((chunk) => chunk.index));
    catchUpChunks.addAll(chunks);
    final context = _context;
    if (emitCatchUpSegment && chunks.isNotEmpty && context != null) {
      _segments.add(
        TranscriptSegment(
          segmentId:
              '${context.sessionId}_seg_${chunks.first.startSample}_${chunks.last.endSample}',
          sessionId: context.sessionId,
          directory: context.directory,
          startSample: chunks.first.startSample,
          endSample: chunks.last.endSample,
          text: '恢复后的尾段',
          rawText: '恢复后的尾段',
          language: 'zh',
          source: 'sherpa_onnx',
          modelId: 'test-model',
          isFinal: true,
        ),
      );
    }
  }

  @override
  Future<void> endSession() async {
    endCount += 1;
    _context = null;
  }

  void completeInitialization() {
    if (!_initializationGate.isCompleted) _initializationGate.complete();
  }

  @override
  Future<void> dispose() async {
    await _partials.close();
    await _segments.close();
    await _states.close();
  }
}

class _RecoveryAwareControllerProvider extends _ControllerProvider
    implements TranscriptionRecoveryReconciliation {
  var reconcileCount = 0;
  var reconciledHighWater = -1;
  var reconciledFinalSegmentCount = -1;

  @override
  Future<void> completeRecoveredSession({
    required TranscriptionSessionContext context,
    required int completedHighWater,
    required int finalSegmentCount,
  }) async {
    reconcileCount += 1;
    reconciledHighWater = completedHighWater;
    reconciledFinalSegmentCount = finalSegmentCount;
  }
}

class _ResilientControllerProvider extends _ControllerProvider
    implements TranscriptionResilienceControl {
  final _diagnostics = StreamController<TranscriptionDiagnosticEvent>.broadcast(
    sync: true,
  );
  var workerCrashCount = 0;
  var missingModelCount = 0;
  var restoreModelCount = 0;
  final delayChanges = <int>[];
  var _delayMs = 0;
  var _modelFault = false;

  @override
  Stream<TranscriptionDiagnosticEvent> get diagnosticEvents =>
      _diagnostics.stream;

  @override
  int get forcedProcessingDelayMs => _delayMs;

  @override
  bool get modelFaultActive => _modelFault;

  @override
  int get lastTranscribedSample => 16000;

  @override
  Future<void> terminateWorkerForTest() async {
    workerCrashCount += 1;
    _emit('asr_worker_crash_injected');
    _states.add(
      const TranscriptionWorkerState(
        status: TranscriptionWorkerStatus.catchUpRequired,
        lastTranscribedSample: 8000,
      ),
    );
    _emit('asr_worker_native_resources_released');
    _states.add(
      const TranscriptionWorkerState(
        status: TranscriptionWorkerStatus.catchUpRequired,
        lastTranscribedSample: 16000,
      ),
    );
    _emit('asr_worker_crashed');
    _emit('asr_worker_restarted');
  }

  @override
  Future<void> restartWithMissingModelForTest() async {
    missingModelCount += 1;
    _modelFault = true;
    _emit('asr_model_missing_injected');
    _emit('asr_worker_native_resources_released');
    _states.add(
      const TranscriptionWorkerState(
        status: TranscriptionWorkerStatus.failed,
        lastTranscribedSample: 16000,
      ),
    );
    _emit('asr_model_unavailable');
  }

  @override
  Future<void> restoreModelForTest() async {
    restoreModelCount += 1;
    _modelFault = false;
    _emit('asr_model_restored');
    _emit('asr_worker_restarted');
  }

  @override
  Future<void> setProcessingDelayForTest(int delayMs) async {
    _delayMs = delayMs;
    delayChanges.add(delayMs);
    _emit('asr_processing_delay_changed');
  }

  void _emit(String type) {
    _diagnostics.add(
      TranscriptionDiagnosticEvent(type: type, sampleOffset: 16000),
    );
  }

  @override
  Future<void> dispose() async {
    await _diagnostics.close();
    await super.dispose();
  }
}

class _SlowRefinement implements FullTextRefinementService {
  final first = Completer<RefinedFullTextDocument>();
  final requests = <FullTextRefinementRequest>[];
  @override
  Future<RefinedFullTextDocument> refine(FullTextRefinementRequest request) {
    requests.add(request);
    if (requests.length == 1) return first.future;
    return Future.value(
      RefinedFullTextDocument.fromMap({'sessionId': request.sessionId}),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
