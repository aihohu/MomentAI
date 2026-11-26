import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/stage1_transcription_controller.dart';
import 'package:momentai/core/asr/transcription_provider.dart';
import 'package:momentai/core/playback/stage1_playback_controller.dart';
import 'package:momentai/domain/audio/committed_audio_chunk.dart';
import 'package:momentai/domain/audio/playback_snapshot.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/transcript_segment.dart';
import 'package:momentai/features/timeline/stage1_timeline_card.dart';
import 'package:momentai/main.dart';
import 'package:momentai/poc/poc_bridge.dart';

void main() {
  test('paused snapshot remains active and can resume or stop', () {
    final snapshot = PoCSnapshot.fromMap({
      'state': 'paused',
      'capturedMs': 4200,
      'committedMs': 4200,
      'rpoMs': 0,
      'chunkCount': 5,
      'directory': '/tmp/session_pause',
      'sessionId': 'session_pause',
      'userPauseCount': 2,
      'totalUserPausedMs': 3100,
      'currentUserPauseMs': 700,
      'asr': const <String, Object?>{},
    });

    expect(snapshot.isRecording, isFalse);
    expect(snapshot.isUserPaused, isTrue);
    expect(snapshot.isActiveCapture, isTrue);
    expect(snapshot.canResume, isTrue);
    expect(snapshot.canStop, isTrue);
    expect(snapshot.canPause, isFalse);
    expect(snapshot.userPauseCount, 2);
    expect(snapshot.totalUserPausedMs, 3100);
    expect(snapshot.currentUserPauseMs, 700);
  });

  testWidgets('renders the Stage 0 acceptance console', (tester) async {
    final bridge = FakePoCBridge();
    await tester.pumpWidget(MomentAIApp(bridge: bridge));
    await tester.pumpAndSettle();

    expect(find.text('Stage 1 Capture Alpha'), findsOneWidget);
    expect(find.text('开始 Capture Alpha 录音'), findsOneWidget);
    await tester.tap(find.byKey(const Key('record-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('正常停止并冲刷尾帧'), findsOneWidget);
    expect(find.text('RPO PASS'), findsOneWidget);
  });

  testWidgets('shows recovery success and supports three idempotence runs', (
    tester,
  ) async {
    final bridge = FakePoCBridge(showRecoveryCandidate: true);
    final controller = Stage1TranscriptionController(
      bridge: bridge,
      provider: _NoopTranscriptionProvider(),
    );
    await tester.pumpWidget(
      MomentAIApp(bridge: bridge, transcriptionController: controller),
    );
    await tester.pumpAndSettle();

    final recoverButton = find.byKey(const ValueKey('recover-session_crashed'));
    await tester.scrollUntilVisible(recoverButton, 350);
    await tester.tap(recoverButton);
    await tester.pumpAndSettle();
    expect(recoverButton, findsNothing);
    final recoveredCard = find.byKey(
      const ValueKey('recovered-session_crashed'),
    );
    await tester.scrollUntilVisible(recoveredCard, 300);
    expect(recoveredCard, findsOneWidget);
    expect(
      find.descendant(of: recoveredCard, matching: find.text('恢复成功')),
      findsOneWidget,
    );
    expect(find.textContaining('幂等验证 1/3'), findsOneWidget);

    for (var attempt = 2; attempt <= 3; attempt++) {
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      final verifyAgain = find.byKey(
        const ValueKey('reverify-session_crashed'),
      );
      await tester.scrollUntilVisible(verifyAgain, 300);
      await tester.tap(verifyAgain);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: recoveredCard,
          matching: find.textContaining('幂等验证 $attempt/3'),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('3/3 ✓'), findsOneWidget);
    expect(
      find.descendant(
        of: recoveredCard,
        matching: find.textContaining('ASR 已是最新，无需重复补转写'),
      ),
      findsOneWidget,
    );
    expect(bridge.recoveryCount, 3);
    controller.dispose();
  });

  testWidgets('does not offer start while an error finalization is pending', (
    tester,
  ) async {
    final bridge = FakePoCBridge(
      initial: const PoCSnapshot(
        state: 'finalizing',
        capturedMs: 7137488,
        committedMs: 7137000,
        rpoMs: 488,
        chunkCount: 6980,
        asrMode: 'normal',
        asrQueueDepth: 0,
        asrDroppedBuffers: 0,
        asrDroppedSamples: 0,
        asrFailedSamples: 0,
        directory: '/tmp/long-session',
      ),
    );
    await tester.pumpWidget(MomentAIApp(bridge: bridge));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('正在冲刷尾帧，请稍候…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('record-toggle')),
    );
    expect(button.onPressed, isNull);
    expect(bridge.startCount, 0);
  });

  testWidgets('uses a dedicated audio interruption injection control', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    await tester.pumpWidget(MomentAIApp(bridge: bridge));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record-toggle')));
    await tester.pumpAndSettle();
    final interruptionButton = find.byKey(
      const Key('inject-audio-interruption'),
    );
    await tester.scrollUntilVisible(interruptionButton, 300);
    await tester.tap(interruptionButton);
    await tester.pumpAndSettle();

    expect(bridge.interruptionInjectionCount, 1);
    expect(find.textContaining('测试注入：暂停音频 3 秒'), findsOneWidget);
  });

  testWidgets('runs the native S1.5 interruption stress control', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    await tester.pumpWidget(MomentAIApp(bridge: bridge));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-toggle')));
    await tester.pumpAndSettle();

    final stress = find.byKey(const Key('s1-5-run-100-interruptions'));
    await tester.scrollUntilVisible(stress, 350);
    await tester.tap(stress);
    await tester.pumpAndSettle();

    expect(bridge.interruptionStressRunCount, 1);
  });

  testWidgets('lets an interrupted recording stop safely', (tester) async {
    final bridge = FakePoCBridge(
      initial: const PoCSnapshot(
        state: 'interrupted',
        capturedMs: 5000,
        committedMs: 4500,
        rpoMs: 500,
        chunkCount: 4,
        asrMode: 'normal',
        asrQueueDepth: 0,
        asrDroppedBuffers: 0,
        asrDroppedSamples: 0,
        asrFailedSamples: 0,
        directory: '/tmp/interrupted-session',
      ),
    );
    await tester.pumpWidget(MomentAIApp(bridge: bridge));
    await tester.pumpAndSettle();

    expect(find.text('结束中断中的录音并冲刷尾帧'), findsOneWidget);
    await tester.tap(find.byKey(const Key('record-toggle')));
    await tester.pumpAndSettle();
    expect(bridge.stopCount, 1);
    expect(bridge.startCount, 0);
  });

  testWidgets('exposes S1.2A image and Bookmark controls while recording', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    await tester.pumpWidget(MomentAIApp(bridge: bridge));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-toggle')));
    await tester.pumpAndSettle();

    final bookmark = find.byKey(const Key('capture-bookmark'));
    await tester.scrollUntilVisible(bookmark, 350);
    await tester.tap(bookmark);
    await tester.pumpAndSettle();
    expect(bridge.bookmarkCount, 1);

    final image = find.byKey(const Key('capture-image'));
    await tester.ensureVisible(image);
    await tester.tap(image);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();
    expect(bridge.cameraCount, 1);
  });

  testWidgets('commits a trimmed text Thought and renders its atomic anchor', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    final controller = Stage1TranscriptionController(
      bridge: bridge,
      provider: _NoopTranscriptionProvider(),
    );
    await tester.pumpWidget(
      MomentAIApp(bridge: bridge, transcriptionController: controller),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-toggle')));
    await tester.pumpAndSettle();

    final thought = find.byKey(const Key('capture-thought'));
    await tester.scrollUntilVisible(thought, 350);
    await tester.tap(thought);
    await tester.pumpAndSettle();

    var submit = tester.widget<FilledButton>(
      find.byKey(const Key('thought-submit')),
    );
    expect(submit.onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('thought-input')),
      '  这是我的现场判断。  ',
    );
    await tester.pump();
    submit = tester.widget<FilledButton>(
      find.byKey(const Key('thought-submit')),
    );
    expect(submit.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('thought-submit')));
    await tester.pumpAndSettle();

    expect(bridge.thoughts, ['这是我的现场判断。']);
    await tester.scrollUntilVisible(
      find.byKey(const Key('stage1-transcription-card')),
      -350,
    );
    expect(find.text('我的随想 · 用户原文'), findsOneWidget);
    expect(find.text('这是我的现场判断。'), findsOneWidget);
    expect(find.text('文字与锚点已原子提交'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('clicking timeline text seeks committed audio by sample clock', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    final transcriptionController =
        Stage1TranscriptionController(
            bridge: bridge,
            provider: _NoopTranscriptionProvider(),
          )
          ..activeDirectory = '/tmp/session_playback'
          ..timeline = [
            TimelineItem.fromMap({
              'kind': 'transcript',
              'segmentId': 'segment_1',
              'sampleOffset': 32000,
              'endSample': 48000,
              'startMs': 2000,
              'endMs': 3000,
              'text': '点击这段转写',
            }),
            TimelineItem.fromMap({
              'kind': 'captureEvent',
              'eventId': 'thought_1',
              'type': 'thought',
              'captureState': 'committed',
              'sampleOffset': 64000,
              'atMs': 4000,
              'text': '我的文字随想',
            }),
          ];
    final playbackController = Stage1PlaybackController(bridge: bridge);
    await playbackController.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Stage1TimelineCard(
              controller: transcriptionController,
              playbackController: playbackController,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('stage1-playback-controls')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('play-segment_1')));
    await tester.pump();
    expect(bridge.playbackStartCount, 1);
    expect(bridge.lastPlaybackSample, 32000);
    expect(bridge.lastPlaybackAnchorId, 'segment_1');
    expect(bridge.lastPlaybackAnchorType, 'transcript');
    expect(find.text('播放中'), findsOneWidget);
    expect(find.textContaining('输出：扬声器'), findsOneWidget);
    expect(find.textContaining('响度增强 +18.1 dB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('playback-toggle')));
    await tester.pump();
    expect(bridge.playbackPauseCount, 1);
    expect(find.text('已暂停'), findsOneWidget);
    await tester.tap(find.byKey(const Key('playback-toggle')));
    await tester.pump();
    expect(bridge.playbackResumeCount, 1);

    await tester.tap(find.byKey(const ValueKey('play-thought_1')));
    await tester.pump();
    expect(bridge.playbackStartCount, 2);
    expect(bridge.lastPlaybackSample, 64000);
    expect(bridge.lastPlaybackAnchorId, 'thought_1');
    expect(bridge.lastPlaybackAnchorType, 'thought');

    await playbackController.seek(80000);
    expect(bridge.playbackSeekCount, 1);
    expect(bridge.lastPlaybackSample, 80000);
    await tester.pump();
    await tester.tap(find.byKey(const Key('playback-stop')));
    await tester.pump();
    expect(bridge.playbackStopCount, 1);

    transcriptionController.dispose();
    playbackController.dispose();
  });

  testWidgets('disables timeline playback while recording is active', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    final transcriptionController =
        Stage1TranscriptionController(
            bridge: bridge,
            provider: _NoopTranscriptionProvider(),
          )
          ..activeDirectory = '/tmp/session_playback'
          ..timeline = [
            TimelineItem.fromMap({
              'kind': 'transcript',
              'segmentId': 'segment_disabled',
              'sampleOffset': 16000,
              'endSample': 32000,
              'startMs': 1000,
              'endMs': 2000,
              'text': '录音中不能回放',
            }),
          ];
    final playbackController = Stage1PlaybackController(bridge: bridge);
    await playbackController.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stage1TimelineCard(
            controller: transcriptionController,
            playbackController: playbackController,
            playbackEnabled: false,
          ),
        ),
      ),
    );

    final row = tester.widget<InkWell>(
      find.byKey(const ValueKey('play-segment_disabled')),
    );
    expect(row.onTap, isNull);
    expect(find.textContaining('录音进行中不启动回放'), findsOneWidget);
    expect(bridge.playbackStartCount, 0);

    transcriptionController.dispose();
    playbackController.dispose();
  });

  testWidgets('timeline shows 50 items initially and paginates the remainder', (
    tester,
  ) async {
    final controller = Stage1TranscriptionController(
      bridge: FakePoCBridge(),
      provider: _NoopTranscriptionProvider(),
    );
    controller.timeline = List.generate(
      60,
      (index) => TimelineItem.fromMap({
        'kind': 'captureEvent',
        'eventId': 'evt_$index',
        'type': 'bookmark',
        'captureState': 'committed',
        'sampleOffset': index * 16000,
        'atMs': index * 1000,
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Stage1TimelineCard(controller: controller),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('timeline-evt_49')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-evt_50')), findsNothing);
    expect(find.text('50/60'), findsOneWidget);
    final loadMore = find.byKey(const Key('timeline-load-more'));
    await tester.scrollUntilVisible(loadMore, 500);
    await tester.tap(loadMore);
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-evt_59')), findsOneWidget);
    expect(find.text('60/60'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('exports and shares the complete S1.4 package after stop', (
    tester,
  ) async {
    final bridge = FakePoCBridge();
    final controller =
        Stage1TranscriptionController(
            bridge: bridge,
            provider: _NoopTranscriptionProvider(),
          )
          ..activeDirectory = '/tmp/session_export'
          ..timeline = [
            TimelineItem.fromMap({
              'kind': 'transcript',
              'segmentId': 'seg_export',
              'sampleOffset': 0,
              'startMs': 0,
              'endSample': 16000,
              'endMs': 1000,
              'text': '导出验收转写',
            }),
          ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Stage1TimelineCard(controller: controller),
          ),
        ),
      ),
    );

    final export = find.byKey(const Key('stage1-export-session'));
    await tester.scrollUntilVisible(export, 500);
    await tester.tap(export);
    await tester.pumpAndSettle();

    expect(bridge.exportCount, 1);
    expect(bridge.shareCount, 1);
    expect(bridge.lastSharedArchive, endsWith('.momentai'));
    expect(find.byKey(const Key('stage1-export-summary')), findsOneWidget);
    expect(find.textContaining('1 条转写 · 2 张图片'), findsOneWidget);
    expect(find.byKey(const Key('stage1-share-export')), findsOneWidget);
    controller.dispose();
  });
}

class FakePoCBridge implements PoCBridge {
  FakePoCBridge({this.showRecoveryCandidate = false, PoCSnapshot? initial})
    : current = initial ?? PoCSnapshot.idle();

  final bool showRecoveryCandidate;
  PoCSnapshot current;
  var recoveryCount = 0;
  var startCount = 0;
  var stopCount = 0;
  var recordingPauseCount = 0;
  var recordingResumeCount = 0;
  var interruptionInjectionCount = 0;
  var interruptionStressRunCount = 0;
  var bookmarkCount = 0;
  var cameraCount = 0;
  var playbackStartCount = 0;
  var playbackPauseCount = 0;
  var playbackResumeCount = 0;
  var playbackSeekCount = 0;
  var playbackStopCount = 0;
  var exportCount = 0;
  var shareCount = 0;
  String? lastSharedArchive;
  int? lastPlaybackSample;
  String? lastPlaybackAnchorId;
  String? lastPlaybackAnchorType;
  PlaybackSnapshot playback = PlaybackSnapshot.idle();
  final thoughts = <String>[];
  final timelineItems = <TimelineItem>[];

  @override
  Stream<PoCSnapshot> get events => const Stream.empty();

  @override
  Stream<PlaybackSnapshot> get playbackEvents => const Stream.empty();

  @override
  Future<Map<Object?, Object?>> openCamera() async {
    cameraCount += 1;
    return {'photoCount': 1, 'firstMediaMs': 1000, 'lastMediaMs': 1000};
  }

  @override
  Future<Map<Object?, Object?>> addBookmark() async {
    bookmarkCount += 1;
    return {'eventId': 'evt_bookmark', 'atMs': 1000};
  }

  @override
  Future<Map<Object?, Object?>> addThought(String text) async {
    thoughts.add(text);
    final eventId = 'evt_thought_${thoughts.length}';
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'captureEvent',
        'eventId': eventId,
        'type': 'thought',
        'captureState': 'committed',
        'sampleOffset': 24000,
        'atMs': 1500,
        'text': text,
        'payload': {'text': text, 'source': 'user_text'},
      }),
    );
    return {'eventId': eventId, 'atMs': 1500, 'text': text};
  }

  @override
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    required int sampleOffset,
    required String anchorId,
    required String anchorType,
  }) async {
    playbackStartCount += 1;
    lastPlaybackSample = sampleOffset;
    lastPlaybackAnchorId = anchorId;
    lastPlaybackAnchorType = anchorType;
    playback = _playbackSnapshot(
      state: 'playing',
      directory: directory,
      positionSample: sampleOffset,
      anchorId: anchorId,
      anchorType: anchorType,
    );
    return playback;
  }

  PlaybackSoundSettings soundSettings = const PlaybackSoundSettings();

  @override
  Future<PlaybackSoundSettings> getPlaybackSound() async => soundSettings;

  @override
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  ) async => soundSettings = settings;

  @override
  Future<PlaybackSnapshot> pausePlayback() async {
    playbackPauseCount += 1;
    playback = _playbackSnapshot(
      state: 'paused',
      directory: playback.directory,
      positionSample: playback.positionSample,
      anchorId: playback.anchorId,
      anchorType: playback.anchorType,
    );
    return playback;
  }

  @override
  Future<PlaybackSnapshot> resumePlayback() async {
    playbackResumeCount += 1;
    playback = _playbackSnapshot(
      state: 'playing',
      directory: playback.directory,
      positionSample: playback.positionSample,
      anchorId: playback.anchorId,
      anchorType: playback.anchorType,
    );
    return playback;
  }

  @override
  Future<PlaybackSnapshot> seekPlayback(int sampleOffset) async {
    playbackSeekCount += 1;
    lastPlaybackSample = sampleOffset;
    playback = _playbackSnapshot(
      state: playback.state,
      directory: playback.directory,
      positionSample: sampleOffset,
      anchorId: playback.anchorId,
      anchorType: playback.anchorType,
    );
    return playback;
  }

  @override
  Future<PlaybackSnapshot> stopPlayback() async {
    playbackStopCount += 1;
    playback = PlaybackSnapshot.idle();
    return playback;
  }

  @override
  Future<Map<Object?, Object?>> recover(String directory) async {
    recoveryCount += 1;
    return {'state': 'completed', 'rpoMs': 0, 'rpoPass': true};
  }

  @override
  Future<List<CommittedAudioChunk>> committedChunks(
    String directory, {
    int afterSample = 0,
  }) async => const [];

  @override
  Future<void> commitTranscriptSegment(TranscriptSegment segment) async {}

  @override
  Future<void> commitStage1Event(
    String directory, {
    required String type,
    required int sampleOffset,
    Map<String, Object?> payload = const {},
  }) async {}

  @override
  Future<void> injectAudioInterruptionForTest({int durationMs = 3000}) async {
    interruptionInjectionCount += 1;
  }

  @override
  Future<Map<Object?, Object?>> runInterruptionStressTest({
    int count = 100,
    int durationMs = 500,
    int settleMs = 250,
  }) async {
    interruptionStressRunCount += 1;
    return {
      'status': 'completed',
      'completed_count': count,
      'target_count': count,
      'maximum_restart_attempts': 1,
    };
  }

  @override
  Future<PoCSnapshot> injectLowStorageForTest({
    int simulatedAvailableBytes = 64 * 1024 * 1024,
  }) async {
    current = PoCSnapshot(
      state: 'completed_with_gaps',
      capturedMs: current.capturedMs,
      committedMs: current.capturedMs,
      rpoMs: 0,
      chunkCount: current.chunkCount,
      asrMode: current.asrMode,
      asrQueueDepth: 0,
      asrDroppedBuffers: current.asrDroppedBuffers,
      asrDroppedSamples: current.asrDroppedSamples,
      asrFailedSamples: current.asrFailedSamples,
      directory: current.directory,
      sessionId: current.sessionId,
      event: 'storage_pressure_controlled_stop',
    );
    return current;
  }

  @override
  Future<PoCSnapshot> pauseRecording() async {
    recordingPauseCount += 1;
    current = PoCSnapshot(
      state: 'paused',
      capturedMs: current.capturedMs,
      committedMs: current.capturedMs,
      rpoMs: 0,
      chunkCount: current.chunkCount,
      asrMode: current.asrMode,
      asrQueueDepth: current.asrQueueDepth,
      asrDroppedBuffers: current.asrDroppedBuffers,
      asrDroppedSamples: current.asrDroppedSamples,
      asrFailedSamples: current.asrFailedSamples,
      directory: current.directory,
      sessionId: current.sessionId,
      event: 'user_pause_began',
      userPauseCount: current.userPauseCount + 1,
    );
    return current;
  }

  @override
  Future<PoCSnapshot> resumeRecording() async {
    recordingResumeCount += 1;
    current = PoCSnapshot(
      state: 'recording',
      capturedMs: current.capturedMs,
      committedMs: current.committedMs,
      rpoMs: 0,
      chunkCount: current.chunkCount,
      asrMode: current.asrMode,
      asrQueueDepth: current.asrQueueDepth,
      asrDroppedBuffers: current.asrDroppedBuffers,
      asrDroppedSamples: current.asrDroppedSamples,
      asrFailedSamples: current.asrFailedSamples,
      directory: current.directory,
      sessionId: current.sessionId,
      event: 'user_pause_ended',
      userPauseCount: current.userPauseCount,
      totalUserPausedMs: current.totalUserPausedMs + 1000,
    );
    return current;
  }

  @override
  Future<Map<Object?, Object?>> compatibilityReport() async => const {
    'hardware_identifier': 'iPhone18,1',
    'system_version': '26.5',
    'app_version': '1.0.0',
    'app_build': '1',
    'available_storage_bytes': 10 * 1024 * 1024 * 1024,
  };

  @override
  Future<List<RecoveryCandidate>> scanRecovery() async => showRecoveryCandidate
      ? const [
          RecoveryCandidate(
            sessionId: 'session_crashed',
            directory: '/tmp/session_crashed',
            state: 'recording',
            committedMs: 1000,
            rpoMs: 500,
            rpoPass: true,
          ),
        ]
      : const [];

  @override
  Future<void> setASRMode(String mode) async {}

  @override
  Future<List<TimelineItem>> timeline(String directory) async =>
      List<TimelineItem>.unmodifiable(timelineItems);

  @override
  Future<SessionExportResult> exportSession(String directory) async {
    exportCount += 1;
    return const SessionExportResult(
      sessionId: 'session_export',
      exportId: 'session_export_20260816',
      directory: '/tmp/Exports/session_export_20260816',
      archivePath: '/tmp/Exports/session_export_20260816.momentai',
      markdownPath: '/tmp/Exports/session_export_20260816/session.md',
      jsonPath: '/tmp/Exports/session_export_20260816/session.json',
      jsonlPath: '/tmp/Exports/session_export_20260816/timeline.jsonl',
      audioPath: '/tmp/Exports/session_export_20260816/audio/session.wav',
      manifestPath: '/tmp/Exports/session_export_20260816/manifest.json',
      audioSamples: 160000,
      durationMs: 10000,
      timelineItemCount: 4,
      transcriptCount: 1,
      imageCount: 2,
      payloadFileCount: 6,
      archiveByteCount: 2048,
      archiveSha256:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
  }

  @override
  Future<void> shareExport(String archivePath) async {
    shareCount += 1;
    lastSharedArchive = archivePath;
  }

  @override
  Future<PoCSnapshot> snapshot() async => current;

  @override
  Future<PoCSnapshot> start({String title = 'Stage 1 Capture Alpha'}) async {
    startCount += 1;
    current = const PoCSnapshot(
      state: 'recording',
      capturedMs: 1000,
      committedMs: 1000,
      rpoMs: 0,
      chunkCount: 1,
      asrMode: 'normal',
      asrQueueDepth: 0,
      asrDroppedBuffers: 0,
      asrDroppedSamples: 0,
      asrFailedSamples: 0,
      directory: '/tmp/session',
    );
    return current;
  }

  @override
  Future<PoCSnapshot> stop() async {
    stopCount += 1;
    current = PoCSnapshot.idle();
    return current;
  }

  @override
  Future<void> terminateForRecoveryTest() async {}
}

PlaybackSnapshot _playbackSnapshot({
  required String state,
  required String directory,
  required int positionSample,
  required String anchorId,
  required String anchorType,
}) => PlaybackSnapshot(
  state: state,
  sessionId: 'session_playback',
  directory: directory,
  sampleRate: 16000,
  positionSample: positionSample,
  durationSamples: 160000,
  positionMs: positionSample ~/ 16,
  durationMs: 10000,
  anchorId: anchorId,
  anchorType: anchorType,
  peakBufferedBytes: 64000,
  outputPortType: 'Speaker',
  outputPortName: 'iPhone Speaker',
  outputVolume: 0.75,
  signalGainDb: 18.0618,
  limiterThreshold: 0.9,
);

class _NoopTranscriptionProvider implements TranscriptionProvider {
  @override
  Stream<TranscriptPartial> get partials => const Stream.empty();

  @override
  Stream<TranscriptSegment> get segments => const Stream.empty();

  @override
  Stream<TranscriptionWorkerState> get states => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> startSession(TranscriptionSessionContext context) async {}

  @override
  EnqueueResult tryEnqueue(CommittedAudioChunk chunk) => EnqueueResult.accepted;

  @override
  Future<void> endSession() async {}

  @override
  Future<void> transcribeCommittedChunks(
    List<CommittedAudioChunk> chunks,
  ) async {}

  @override
  Future<void> dispose() async {}
}
