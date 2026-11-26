import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/audio/committed_audio_chunk.dart';
import '../domain/audio/playback_snapshot.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/transcript_segment.dart';

class PoCSnapshot {
  const PoCSnapshot({
    required this.state,
    required this.capturedMs,
    required this.committedMs,
    required this.rpoMs,
    required this.chunkCount,
    required this.asrMode,
    required this.asrQueueDepth,
    required this.asrDroppedBuffers,
    required this.asrDroppedSamples,
    required this.asrFailedSamples,
    required this.directory,
    this.sessionId = '',
    this.event,
    this.error,
    this.committedChunk,
    this.s15ElapsedMs = 0,
    this.s15TargetMs = 10800000,
    this.s15BackgroundCount = 0,
    this.s15ProtectedDataUnavailableCount = 0,
    this.interruptionStressCompleted = 0,
    this.interruptionStressTarget = 0,
    this.interruptionStressStatus = '',
    this.userPauseCount = 0,
    this.totalUserPausedMs = 0,
    this.currentUserPauseMs = 0,
    this.canResumeAfterInterruption = false,
  });

  factory PoCSnapshot.idle() => const PoCSnapshot(
    state: 'idle',
    capturedMs: 0,
    committedMs: 0,
    rpoMs: 0,
    chunkCount: 0,
    asrMode: 'normal',
    asrQueueDepth: 0,
    asrDroppedBuffers: 0,
    asrDroppedSamples: 0,
    asrFailedSamples: 0,
    directory: '',
    sessionId: '',
  );

  factory PoCSnapshot.fromMap(Map<Object?, Object?> map) {
    final asr = mapValue(map['asr']);
    final s15 = mapValue(map['s15']);
    final stress = mapValue(map['interruptionStress']);
    return PoCSnapshot(
      state: map['state']?.toString() ?? 'idle',
      capturedMs: numberValue(map['capturedMs']),
      committedMs: numberValue(map['committedMs']),
      rpoMs: numberValue(map['rpoMs']),
      chunkCount: numberValue(map['chunkCount']),
      asrMode: asr['mode']?.toString() ?? 'normal',
      asrQueueDepth: numberValue(asr['queueDepth']),
      asrDroppedBuffers: numberValue(asr['droppedBuffers']),
      asrDroppedSamples: numberValue(asr['droppedSamples']),
      asrFailedSamples: numberValue(asr['failedSamples']),
      directory: map['directory']?.toString() ?? '',
      sessionId: map['sessionId']?.toString() ?? '',
      event: map['event']?.toString(),
      error: map['error']?.toString(),
      committedChunk: map['chunk'] == null
          ? null
          : CommittedAudioChunk.fromMap(mapValue(map['chunk'])),
      s15ElapsedMs: numberValue(s15['elapsed_ms']),
      s15TargetMs: numberValue(s15['target_ms']),
      s15BackgroundCount: numberValue(s15['background_count']),
      s15ProtectedDataUnavailableCount: numberValue(
        s15['protected_data_unavailable_count'],
      ),
      interruptionStressCompleted: numberValue(stress['completed_count']),
      interruptionStressTarget: numberValue(stress['target_count']),
      interruptionStressStatus: stress['status']?.toString() ?? '',
      userPauseCount: numberValue(map['userPauseCount']),
      totalUserPausedMs: numberValue(map['totalUserPausedMs']),
      currentUserPauseMs: numberValue(map['currentUserPauseMs']),
      canResumeAfterInterruption: map['canResumeAfterInterruption'] == true,
    );
  }

  final String state;
  final int capturedMs;
  final int committedMs;
  final int rpoMs;
  final int chunkCount;
  final String asrMode;
  final int asrQueueDepth;
  final int asrDroppedBuffers;
  final int asrDroppedSamples;
  final int asrFailedSamples;
  final String directory;
  final String sessionId;
  final String? event;
  final String? error;
  final CommittedAudioChunk? committedChunk;
  final int s15ElapsedMs;
  final int s15TargetMs;
  final int s15BackgroundCount;
  final int s15ProtectedDataUnavailableCount;
  final int interruptionStressCompleted;
  final int interruptionStressTarget;
  final String interruptionStressStatus;
  final int userPauseCount;
  final int totalUserPausedMs;
  final int currentUserPauseMs;
  final bool canResumeAfterInterruption;

  bool get isRecording => state == 'recording' || state == 'interrupted';
  bool get isUserPaused => state == 'paused';
  bool get isActiveCapture => const {
    'preparing',
    'recording',
    'pausing',
    'paused',
    'resuming',
    'interrupted',
    'finalizing',
  }.contains(state);
  bool get isTransitioning =>
      state == 'authorizing' ||
      state == 'preparing' ||
      state == 'pausing' ||
      state == 'resuming' ||
      state == 'finalizing';
  bool get canStart =>
      state == 'idle' || state == 'completed' || state == 'completed_with_gaps';
  bool get canStop =>
      state == 'recording' || state == 'interrupted' || state == 'paused';
  bool get canPause => state == 'recording';
  bool get canResume =>
      state == 'paused' ||
      (state == 'interrupted' && canResumeAfterInterruption);
  bool get rpoPass => rpoMs <= 2000;
}

class RecoveryCandidate {
  const RecoveryCandidate({
    required this.sessionId,
    required this.directory,
    required this.state,
    required this.committedMs,
    required this.rpoMs,
    required this.rpoPass,
    this.rpoKnown = true,
    this.title = '',
    this.startedAt,
    this.observedMs = 0,
    this.imageCommittedCount = 0,
    this.imagePendingCount = 0,
  });

  factory RecoveryCandidate.fromMap(Map<Object?, Object?> map) {
    final samples = numberValue(map['lastCommittedSample']);
    final observedSamples = numberValue(map['observedSamples']);
    return RecoveryCandidate(
      sessionId: map['sessionId']?.toString() ?? 'unknown',
      directory: map['directory']?.toString() ?? '',
      state: map['state']?.toString() ?? 'recovering',
      committedMs: (samples / 16).round(),
      rpoMs: numberValue(map['rpoMs']),
      rpoPass: map['rpoPass'] == true,
      rpoKnown: map['rpoKnown'] != false,
      title: map['title']?.toString() ?? '',
      startedAt: DateTime.tryParse(
        map['startedAtWall']?.toString() ?? '',
      )?.toLocal(),
      observedMs: (observedSamples / 16).round(),
      imageCommittedCount: numberValue(map['imageCommittedCount']),
      imagePendingCount: numberValue(map['imagePendingCount']),
    );
  }

  final String sessionId;
  final String directory;
  final String state;
  final int committedMs;
  final int rpoMs;
  final bool rpoPass;
  final bool rpoKnown;
  final String title;
  final DateTime? startedAt;
  final int observedMs;
  final int imageCommittedCount;
  final int imagePendingCount;
}

class RecoveryOutcome {
  const RecoveryOutcome({
    required this.sessionId,
    required this.directory,
    required this.state,
    required this.committedMs,
    required this.observedMs,
    required this.rpoMs,
    required this.rpoPass,
    required this.quarantinedFiles,
    required this.corruptChunks,
    required this.discardedSamples,
    required this.imageCommittedCount,
    required this.imageFailedCount,
    required this.capturePendingCount,
    this.rpoKnown = true,
    this.rpoIsUpperBound = false,
  });

  factory RecoveryOutcome.fromMap(Map<Object?, Object?> map) {
    final committedSamples = numberValue(map['lastCommittedSample']);
    final observedSamples = numberValue(map['observedSamples']);
    return RecoveryOutcome(
      sessionId: map['sessionId']?.toString() ?? '',
      directory: map['directory']?.toString() ?? '',
      state: map['state']?.toString() ?? 'completed',
      committedMs: (committedSamples / 16).round(),
      observedMs: (observedSamples / 16).round(),
      rpoMs: numberValue(map['rpoMs']),
      rpoPass: map['rpoPass'] == true,
      quarantinedFiles: numberValue(map['quarantinedFiles']),
      corruptChunks: numberValue(map['corruptChunks']),
      discardedSamples: numberValue(map['discardedSamples']),
      imageCommittedCount: numberValue(map['imageCommittedCount']),
      imageFailedCount: numberValue(map['imageFailedCount']),
      capturePendingCount: numberValue(map['capturePendingCount']),
      rpoKnown: map['rpoKnown'] != false,
      rpoIsUpperBound: map['rpoIsUpperBound'] == true,
    );
  }

  final String sessionId;
  final String directory;
  final String state;
  final int committedMs;
  final int observedMs;
  final int rpoMs;
  final bool rpoPass;
  final int quarantinedFiles;
  final int corruptChunks;
  final int discardedSamples;
  final int imageCommittedCount;
  final int imageFailedCount;
  final int capturePendingCount;
  final bool rpoKnown;
  final bool rpoIsUpperBound;

  bool get hasConfirmedGaps => state == 'completed_with_gaps';
}

class SessionExportResult {
  const SessionExportResult({
    required this.sessionId,
    required this.exportId,
    required this.directory,
    required this.archivePath,
    required this.markdownPath,
    required this.jsonPath,
    required this.jsonlPath,
    required this.audioPath,
    required this.manifestPath,
    required this.audioSamples,
    required this.durationMs,
    required this.timelineItemCount,
    required this.transcriptCount,
    required this.imageCount,
    required this.payloadFileCount,
    required this.archiveByteCount,
    required this.archiveSha256,
    this.canonicalTextStatus = 'live',
    this.canonicalTextLayer = 'live',
    this.refinedTranscriptCount = 0,
    this.fallbackTranscriptCount = 0,
  });

  factory SessionExportResult.fromMap(Map<Object?, Object?> map) =>
      SessionExportResult(
        sessionId: map['sessionId']?.toString() ?? '',
        exportId: map['exportId']?.toString() ?? '',
        directory: map['directory']?.toString() ?? '',
        archivePath: map['archivePath']?.toString() ?? '',
        markdownPath: map['markdownPath']?.toString() ?? '',
        jsonPath: map['jsonPath']?.toString() ?? '',
        jsonlPath: map['jsonlPath']?.toString() ?? '',
        audioPath: map['audioPath']?.toString() ?? '',
        manifestPath: map['manifestPath']?.toString() ?? '',
        audioSamples: numberValue(map['audioSamples']),
        durationMs: numberValue(map['durationMs']),
        timelineItemCount: numberValue(map['timelineItemCount']),
        transcriptCount: numberValue(map['transcriptCount']),
        imageCount: numberValue(map['imageCount']),
        payloadFileCount: numberValue(map['payloadFileCount']),
        archiveByteCount: numberValue(map['archiveByteCount']),
        archiveSha256: map['archiveSha256']?.toString() ?? '',
        canonicalTextStatus: map['canonicalTextStatus']?.toString() ?? 'live',
        canonicalTextLayer: map['canonicalTextLayer']?.toString() ?? 'live',
        refinedTranscriptCount: numberValue(map['refinedTranscriptCount']),
        fallbackTranscriptCount: numberValue(map['fallbackTranscriptCount']),
      );

  final String sessionId;
  final String exportId;
  final String directory;
  final String archivePath;
  final String markdownPath;
  final String jsonPath;
  final String jsonlPath;
  final String audioPath;
  final String manifestPath;
  final int audioSamples;
  final int durationMs;
  final int timelineItemCount;
  final int transcriptCount;
  final int imageCount;
  final int payloadFileCount;
  final int archiveByteCount;
  final String archiveSha256;
  final String canonicalTextStatus;
  final String canonicalTextLayer;
  final int refinedTranscriptCount;
  final int fallbackTranscriptCount;
}

abstract interface class PoCBridge {
  Stream<PoCSnapshot> get events;
  Stream<PlaybackSnapshot> get playbackEvents;
  Future<PoCSnapshot> start({String title = 'Stage 1 Capture Alpha'});
  Future<PoCSnapshot> stop();
  Future<PoCSnapshot> pauseRecording();
  Future<PoCSnapshot> resumeRecording();
  Future<PoCSnapshot> snapshot();
  Future<void> injectAudioInterruptionForTest({int durationMs = 3000});
  Future<Map<Object?, Object?>> runInterruptionStressTest({
    int count = 100,
    int durationMs = 500,
    int settleMs = 250,
  });
  Future<PoCSnapshot> injectLowStorageForTest({
    int simulatedAvailableBytes = 64 * 1024 * 1024,
  });
  Future<Map<Object?, Object?>> compatibilityReport();
  Future<void> setASRMode(String mode);
  Future<Map<Object?, Object?>> openCamera();
  Future<Map<Object?, Object?>> addBookmark();
  Future<Map<Object?, Object?>> addThought(String text);
  Future<List<RecoveryCandidate>> scanRecovery();
  Future<Map<Object?, Object?>> recover(String directory);
  Future<List<CommittedAudioChunk>> committedChunks(
    String directory, {
    int afterSample = 0,
  });
  Future<void> commitTranscriptSegment(TranscriptSegment segment);
  Future<void> commitStage1Event(
    String directory, {
    required String type,
    required int sampleOffset,
    Map<String, Object?> payload = const {},
  });
  Future<List<TimelineItem>> timeline(String directory);
  Future<SessionExportResult> exportSession(String directory);
  Future<void> shareExport(String archivePath);
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    required int sampleOffset,
    required String anchorId,
    required String anchorType,
  });
  Future<PlaybackSoundSettings> getPlaybackSound();
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  );
  Future<PlaybackSnapshot> pausePlayback();
  Future<PlaybackSnapshot> resumePlayback();
  Future<PlaybackSnapshot> seekPlayback(int sampleOffset);
  Future<PlaybackSnapshot> stopPlayback();
  Future<void> terminateForRecoveryTest();
}

class NativePoCBridge implements PoCBridge {
  static const _methods = MethodChannel('org.hohu.momentai.poc/methods');
  static const _eventChannel = EventChannel('org.hohu.momentai.poc/events');
  static const _playbackEventChannel = EventChannel(
    'org.hohu.momentai.poc/playback_events',
  );
  Stream<PoCSnapshot>? _eventStream;
  Stream<PlaybackSnapshot>? _playbackEventStream;

  @override
  Stream<PoCSnapshot> get events {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const Stream<PoCSnapshot>.empty();
    }
    return _eventStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => PoCSnapshot.fromMap(mapValue(event)))
        .asBroadcastStream();
  }

  @override
  Stream<PlaybackSnapshot> get playbackEvents {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const Stream<PlaybackSnapshot>.empty();
    }
    return _playbackEventStream ??= _playbackEventChannel
        .receiveBroadcastStream()
        .map((event) => PlaybackSnapshot.fromMap(mapValue(event)))
        .asBroadcastStream();
  }

  @override
  Future<PoCSnapshot> start({String title = 'Stage 1 Capture Alpha'}) async {
    ensureMobile();
    return PoCSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('start', {'title': title})),
    );
  }

  @override
  Future<PoCSnapshot> stop() async {
    ensureMobile();
    return PoCSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('stop')),
    );
  }

  @override
  Future<PoCSnapshot> pauseRecording() async {
    ensureMobile();
    return PoCSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('pauseRecording')),
    );
  }

  @override
  Future<PoCSnapshot> resumeRecording() async {
    ensureMobile();
    return PoCSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('resumeRecording')),
    );
  }

  @override
  Future<PoCSnapshot> snapshot() async {
    ensureMobile();
    return PoCSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('snapshot')),
    );
  }

  @override
  Future<void> injectAudioInterruptionForTest({int durationMs = 3000}) async {
    ensureMobile();
    await _methods.invokeMethod<Object?>('injectAudioInterruptionForTest', {
      'durationMs': durationMs,
    });
  }

  @override
  Future<Map<Object?, Object?>> runInterruptionStressTest({
    int count = 100,
    int durationMs = 500,
    int settleMs = 250,
  }) async {
    ensureMobile();
    return mapValue(
      await _methods.invokeMethod<Object?>('runInterruptionStressTest', {
        'count': count,
        'durationMs': durationMs,
        'settleMs': settleMs,
      }),
    );
  }

  @override
  Future<PoCSnapshot> injectLowStorageForTest({
    int simulatedAvailableBytes = 64 * 1024 * 1024,
  }) async {
    ensureMobile();
    return PoCSnapshot.fromMap(
      mapValue(
        await _methods.invokeMethod<Object?>('injectLowStorageForTest', {
          'simulatedAvailableBytes': simulatedAvailableBytes,
        }),
      ),
    );
  }

  @override
  Future<Map<Object?, Object?>> compatibilityReport() async {
    ensureMobile();
    return mapValue(
      await _methods.invokeMethod<Object?>('compatibilityReport'),
    );
  }

  @override
  Future<void> setASRMode(String mode) async {
    ensureMobile();
    await _methods.invokeMethod<Object?>('setASRMode', {'mode': mode});
  }

  @override
  Future<Map<Object?, Object?>> openCamera() async {
    ensureMobile();
    return mapValue(await _methods.invokeMethod<Object?>('openCamera'));
  }

  @override
  Future<Map<Object?, Object?>> addBookmark() async {
    ensureMobile();
    return mapValue(await _methods.invokeMethod<Object?>('addBookmark'));
  }

  @override
  Future<Map<Object?, Object?>> addThought(String text) async {
    ensureMobile();
    return mapValue(
      await _methods.invokeMethod<Object?>('addThought', {'text': text}),
    );
  }

  @override
  Future<List<RecoveryCandidate>> scanRecovery() async {
    if (!Platform.isIOS && !Platform.isAndroid) return const [];
    final raw =
        await _methods.invokeListMethod<Object?>('scanRecovery') ?? const [];
    return raw
        .map((item) => RecoveryCandidate.fromMap(mapValue(item)))
        .toList();
  }

  @override
  Future<Map<Object?, Object?>> recover(String directory) async {
    ensureMobile();
    return mapValue(
      await _methods.invokeMethod<Object?>('recover', {'directory': directory}),
    );
  }

  @override
  Future<List<CommittedAudioChunk>> committedChunks(
    String directory, {
    int afterSample = 0,
  }) async {
    ensureMobile();
    final raw =
        await _methods.invokeListMethod<Object?>('committedChunks', {
          'directory': directory,
          'afterSample': afterSample,
        }) ??
        const [];
    return raw
        .map((item) => CommittedAudioChunk.fromMap(mapValue(item)))
        .toList(growable: false);
  }

  @override
  Future<void> commitTranscriptSegment(TranscriptSegment segment) async {
    ensureMobile();
    await _methods.invokeMethod<Object?>('commitTranscriptSegment', {
      'directory': segment.directory,
      'segment': segment.toMap(),
    });
  }

  @override
  Future<void> commitStage1Event(
    String directory, {
    required String type,
    required int sampleOffset,
    Map<String, Object?> payload = const {},
  }) async {
    ensureMobile();
    await _methods.invokeMethod<Object?>('commitStage1Event', {
      'directory': directory,
      'type': type,
      'sampleOffset': sampleOffset,
      'payload': payload,
    });
  }

  @override
  Future<List<TimelineItem>> timeline(String directory) async {
    ensureMobile();
    final raw =
        await _methods.invokeListMethod<Object?>('timeline', {
          'directory': directory,
        }) ??
        const [];
    return raw
        .map((item) => TimelineItem.fromMap(mapValue(item)))
        .toList(growable: false);
  }

  @override
  Future<SessionExportResult> exportSession(String directory) async {
    ensureMobile();
    return SessionExportResult.fromMap(
      mapValue(
        await _methods.invokeMethod<Object?>('exportSession', {
          'directory': directory,
        }),
      ),
    );
  }

  @override
  Future<void> shareExport(String archivePath) async {
    ensureMobile();
    await _methods.invokeMethod<Object?>('shareExport', {
      'archivePath': archivePath,
    });
  }

  @override
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    required int sampleOffset,
    required String anchorId,
    required String anchorType,
  }) async {
    ensureMobile();
    return PlaybackSnapshot.fromMap(
      mapValue(
        await _methods.invokeMethod<Object?>('startPlayback', {
          'directory': directory,
          'sampleOffset': sampleOffset,
          'anchorId': anchorId,
          'anchorType': anchorType,
        }),
      ),
    );
  }

  @override
  Future<PlaybackSoundSettings> getPlaybackSound() async {
    ensureMobile();
    return PlaybackSoundSettings.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('getPlaybackSound')),
    );
  }

  @override
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  ) async {
    ensureMobile();
    return PlaybackSoundSettings.fromMap(
      mapValue(
        await _methods.invokeMethod<Object?>('setPlaybackSound', {
          'volume': settings.volume,
          'enhanced': settings.enhanced,
        }),
      ),
    );
  }

  @override
  Future<PlaybackSnapshot> pausePlayback() async {
    ensureMobile();
    return PlaybackSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('pausePlayback')),
    );
  }

  @override
  Future<PlaybackSnapshot> resumePlayback() async {
    ensureMobile();
    return PlaybackSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('resumePlayback')),
    );
  }

  @override
  Future<PlaybackSnapshot> seekPlayback(int sampleOffset) async {
    ensureMobile();
    return PlaybackSnapshot.fromMap(
      mapValue(
        await _methods.invokeMethod<Object?>('seekPlayback', {
          'sampleOffset': sampleOffset,
        }),
      ),
    );
  }

  @override
  Future<PlaybackSnapshot> stopPlayback() async {
    ensureMobile();
    return PlaybackSnapshot.fromMap(
      mapValue(await _methods.invokeMethod<Object?>('stopPlayback')),
    );
  }

  @override
  Future<void> terminateForRecoveryTest() async {
    ensureMobile();
    await _methods.invokeMethod<Object?>('terminateForRecoveryTest');
  }

  void ensureMobile() {
    if (!Platform.isIOS && !Platform.isAndroid) {
      throw UnsupportedError('录音运行时仅支持 iOS 和 Android。');
    }
  }
}

Map<Object?, Object?> mapValue(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return Map<Object?, Object?>.from(value);
  return const {};
}

int numberValue(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;
