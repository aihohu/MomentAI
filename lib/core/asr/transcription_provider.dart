import '../../domain/audio/committed_audio_chunk.dart';
import '../../domain/transcript/transcript_segment.dart';

enum EnqueueResult { accepted, queueFull, workerUnavailable, sessionClosed }

enum TranscriptionWorkerStatus {
  uninitialized,
  loadingModel,
  ready,
  transcribing,
  catchUpRequired,
  failed,
  disposed,
}

class TranscriptionSessionContext {
  const TranscriptionSessionContext({
    required this.sessionId,
    required this.directory,
    this.sampleRate = 16000,
  });

  final String sessionId;
  final String directory;
  final int sampleRate;
}

class TranscriptPartial {
  const TranscriptPartial({
    required this.sessionId,
    required this.startSample,
    required this.endSample,
    required this.text,
  });

  final String sessionId;
  final int startSample;
  final int endSample;
  final String text;
}

class TranscriptionWorkerState {
  const TranscriptionWorkerState({
    required this.status,
    this.pendingChunks = 0,
    this.lastTranscribedSample = 0,
    this.message,
  });

  final TranscriptionWorkerStatus status;
  final int pendingChunks;
  final int lastTranscribedSample;
  final String? message;
}

class TranscriptionDiagnosticEvent {
  const TranscriptionDiagnosticEvent({
    required this.type,
    required this.sampleOffset,
    this.payload = const {},
  });

  final String type;
  final int sampleOffset;
  final Map<String, Object?> payload;
}

abstract interface class TranscriptionResilienceControl {
  Stream<TranscriptionDiagnosticEvent> get diagnosticEvents;

  int get forcedProcessingDelayMs;

  bool get modelFaultActive;

  int get lastTranscribedSample;

  Future<void> terminateWorkerForTest();

  Future<void> restartWithMissingModelForTest();

  Future<void> restoreModelForTest();

  Future<void> setProcessingDelayForTest(int delayMs);
}

/// Reconciles durable ASR metrics when a recovered Session already has final
/// transcripts through the committed audio high-water and needs no replay.
abstract interface class TranscriptionRecoveryReconciliation {
  Future<void> completeRecoveredSession({
    required TranscriptionSessionContext context,
    required int completedHighWater,
    required int finalSegmentCount,
  });
}

/// Releases an idle native ASR runtime before another large local model is
/// loaded. The provider must remain reusable and recreate its Worker on the
/// next [TranscriptionProvider.startSession].
abstract interface class TranscriptionIdleResourceControl {
  Future<void> releaseIdleResources();
}

abstract interface class TranscriptionProvider {
  Future<void> initialize();

  Future<void> startSession(TranscriptionSessionContext context);

  EnqueueResult tryEnqueue(CommittedAudioChunk chunk);

  Stream<TranscriptPartial> get partials;

  Stream<TranscriptSegment> get segments;

  Stream<TranscriptionWorkerState> get states;

  Future<void> endSession();

  Future<void> transcribeCommittedChunks(List<CommittedAudioChunk> chunks);

  Future<void> dispose();
}
