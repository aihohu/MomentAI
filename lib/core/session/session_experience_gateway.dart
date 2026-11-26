import 'package:momentai/l10n/app_localization.dart';
import '../../domain/audio/playback_snapshot.dart';
import '../../domain/speaker/speaker_diarization.dart';
import '../../domain/timeline/timeline_item.dart';
import '../../domain/transcript/refined_full_text.dart';
import '../../poc/poc_bridge.dart';
import '../asr/full_text_refinement_service.dart';
import '../asr/stage1_transcription_controller.dart';
import '../speaker/speaker_diarization_service.dart';

enum TranscriptionPhase { idle, transcribing, waitingForRefinement, refining }

abstract interface class SessionExperienceGateway {
  Stream<PlaybackSnapshot> get playbackEvents;

  bool isTranscriptionFinishing(String sessionId);
  TranscriptionPhase transcriptionPhase(String sessionId);
  Future<void> refineFullText({
    required String sessionId,
    required String directory,
    bool forceRebuild = false,
  });
  Future<void> recoverTranscription({
    required String sessionId,
    required String directory,
  });
  Future<FullTextRefinementSnapshot> fullTextRefinement(String directory);
  Future<SpeakerDiarizationSnapshot> speakerDiarization(String directory);
  Future<SpeakerDiarizationDocument> analyzeSpeakers({
    required String sessionId,
    required String directory,
    int? requestedSpeakerCount,
    bool forceRebuild = false,
  });
  Future<void> deleteSpeakerDiarization(String directory);
  Future<SpeakerDiarizationDocument> editSpeakers(
    String directory, {
    required SpeakerDiarizationDocument expectedDocument,
    required SpeakerEdit edit,
  });
  Future<List<TimelineItem>> timeline(String directory);
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
  Future<SessionExportResult> exportSession(String directory);
  Future<void> shareExport(String archivePath);
}

class ProductSessionExperienceGateway implements SessionExperienceGateway {
  const ProductSessionExperienceGateway(
    this._bridge, {
    this.transcriptionController,
    this.fullTextRefinementService,
    this.speakerDiarizationService,
    this.refinementResourceBusy,
  });

  final PoCBridge _bridge;
  final bool Function()? refinementResourceBusy;
  final Stage1TranscriptionController? transcriptionController;
  final FullTextRefinementService? fullTextRefinementService;
  final SpeakerDiarizationService? speakerDiarizationService;

  @override
  Stream<PlaybackSnapshot> get playbackEvents => _bridge.playbackEvents;

  @override
  bool isTranscriptionFinishing(String sessionId) =>
      transcriptionController?.isSessionFinishing(sessionId) ?? false;

  @override
  TranscriptionPhase transcriptionPhase(String sessionId) {
    final controller = transcriptionController;
    if (controller == null) return TranscriptionPhase.idle;
    if (controller.isRefinementRunning(sessionId)) {
      return TranscriptionPhase.refining;
    }
    if (controller.isRefinementPending(sessionId)) {
      return TranscriptionPhase.waitingForRefinement;
    }
    return controller.isSessionFinishing(sessionId)
        ? TranscriptionPhase.transcribing
        : TranscriptionPhase.idle;
  }

  @override
  Future<void> refineFullText({
    required String sessionId,
    required String directory,
    bool forceRebuild = false,
  }) {
    final controller = transcriptionController;
    if (controller == null) {
      return Future.error(StateError(l10n.manualRefinementUnavailable));
    }
    if ((refinementResourceBusy?.call() ?? false) ||
        (speakerDiarizationService?.hasActiveJobs ?? false)) {
      return Future.error(StateError(l10n.manualRefinementBusy));
    }
    return controller.refineSavedSession(
      sessionId: sessionId,
      directory: directory,
      forceRebuild: forceRebuild,
    );
  }

  @override
  Future<void> recoverTranscription({
    required String sessionId,
    required String directory,
  }) async {
    final controller = transcriptionController;
    if (controller == null) return;
    await controller.recoverSessionTranscription(
      sessionId: sessionId,
      directory: directory,
    );
  }

  @override
  Future<FullTextRefinementSnapshot> fullTextRefinement(
    String directory,
  ) async {
    final service = fullTextRefinementService;
    if (service == null) {
      return const FullTextRefinementSnapshot.unavailable();
    }
    return service.snapshot(directory);
  }

  @override
  Future<List<TimelineItem>> timeline(String directory) =>
      _bridge.timeline(directory);

  @override
  Future<SpeakerDiarizationSnapshot> speakerDiarization(
    String directory,
  ) async {
    final service = speakerDiarizationService;
    if (service == null) {
      return SpeakerDiarizationSnapshot.unavailable(
        message: l10n.theSpeakerAnalysisServiceIsNotConnected,
      );
    }
    final snapshot = await service.snapshot(directory);
    final document = snapshot.document;
    if (document == null) return snapshot;
    final chunks = await _bridge.committedChunks(directory);
    final events = await _bridge.timeline(directory);
    final samples = chunks.fold<int>(
      0,
      (n, c) => c.endSample > n ? c.endSample : n,
    );
    final boundaries = speakerInterruptionBoundaries(
      events,
    ).where((sample) => sample > 0 && sample < samples);
    if (chunks.isEmpty ||
        chunks.first.sessionId != document.sessionId ||
        document.sourceAudioSamples != samples ||
        document.sourceChunkFingerprint !=
            sourceChunkFingerprint(chunks, boundarySamples: boundaries)) {
      return SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.failed,
        message: l10n.speakerResultsDoNotMatchTheCurrent,
      );
    }
    return snapshot;
  }

  @override
  Future<SpeakerDiarizationDocument> analyzeSpeakers({
    required String sessionId,
    required String directory,
    int? requestedSpeakerCount,
    bool forceRebuild = false,
  }) async {
    final service = speakerDiarizationService;
    if (service == null) {
      throw StateError(l10n.theSpeakerAnalysisServiceIsNotConnected);
    }
    return service.analyze(
      SpeakerDiarizationRequest(
        sessionId: sessionId,
        directory: directory,
        forceRebuild: forceRebuild,
        loadSource: () async {
          final chunks = await _bridge.committedChunks(directory);
          final events = await _bridge.timeline(directory);
          return SpeakerDiarizationSource(
            chunks: chunks,
            boundarySamples: speakerInterruptionBoundaries(events),
          );
        },
        requestedSpeakerCount: requestedSpeakerCount,
      ),
    );
  }

  @override
  Future<SpeakerDiarizationDocument> editSpeakers(
    String directory, {
    required SpeakerDiarizationDocument expectedDocument,
    required SpeakerEdit edit,
  }) async {
    final service = speakerDiarizationService;
    if (service == null) {
      throw StateError(l10n.theSpeakerAnalysisServiceIsNotConnected);
    }
    return service.editResult(
      directory,
      expectedDocument: expectedDocument,
      edit: edit,
    );
  }

  @override
  Future<void> deleteSpeakerDiarization(String directory) async {
    final service = speakerDiarizationService;
    if (service == null) return;
    await service.deleteResult(directory);
  }

  @override
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    required int sampleOffset,
    required String anchorId,
    required String anchorType,
  }) => _bridge.startPlayback(
    directory,
    sampleOffset: sampleOffset,
    anchorId: anchorId,
    anchorType: anchorType,
  );

  @override
  Future<PlaybackSoundSettings> getPlaybackSound() =>
      _bridge.getPlaybackSound();

  @override
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  ) => _bridge.setPlaybackSound(settings);

  @override
  Future<PlaybackSnapshot> pausePlayback() => _bridge.pausePlayback();

  @override
  Future<PlaybackSnapshot> resumePlayback() => _bridge.resumePlayback();

  @override
  Future<PlaybackSnapshot> seekPlayback(int sampleOffset) =>
      _bridge.seekPlayback(sampleOffset);

  @override
  Future<PlaybackSnapshot> stopPlayback() => _bridge.stopPlayback();

  @override
  Future<SessionExportResult> exportSession(String directory) =>
      _bridge.exportSession(directory);

  @override
  Future<void> shareExport(String archivePath) =>
      _bridge.shareExport(archivePath);
}

/// Interruptions and user pauses use the committed sample clock; wall-clock
/// durations must not shift either the PCM or existing transcript anchors.
List<int> speakerInterruptionBoundaries(Iterable<TimelineItem> events) =>
    events
        .where(
          (event) => const {
            'audio_interruption_began',
            'audio_interruption_ended',
            'user_pause_began',
            'user_pause_ended',
          }.contains(event.type),
        )
        .map((event) => event.sampleOffset)
        .toSet()
        .toList()
      ..sort();
