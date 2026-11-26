import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../core/session/session_experience_gateway.dart';
import '../core/session/session_transfer_gateway.dart';
import '../domain/audio/playback_snapshot.dart';
import '../domain/session/session_summary.dart';
import '../domain/speaker/speaker_diarization.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/refined_full_text.dart';
import '../poc/poc_bridge.dart';
import 'full_text_search.dart';

class SessionDetailController extends ChangeNotifier {
  SessionDetailController({
    required this.session,
    required this.gateway,
    this.transferGateway = const NativeSessionTransferGateway(),
  });

  final SessionSummary session;
  final SessionExperienceGateway gateway;
  final SessionTransferGateway transferGateway;

  List<TimelineItem> timeline = const [];
  PlaybackSnapshot playback = PlaybackSnapshot.idle();
  SessionExportResult? exportResult;
  FullTextRefinementSnapshot fullTextRefinement =
      const FullTextRefinementSnapshot.unavailable();
  SpeakerDiarizationSnapshot speakerDiarization =
      const SpeakerDiarizationSnapshot.unavailable();
  Object? timelineError;
  Object? playbackError;
  Object? exportError;
  String? exportNotice;
  String? playbackAnchorItemId;
  String? currentPlaybackItemId;
  bool loadingTimeline = true;
  bool loadingFullTextRefinement = true;
  bool loadingSpeakerDiarization = true;
  bool speakerDiarizationBusy = false;
  String? speakerEditError;
  bool playbackBusy = false;
  PlaybackSoundSettings playbackSound = const PlaybackSoundSettings();
  PlaybackSoundSettings _savedSound = const PlaybackSoundSettings();
  PlaybackSoundSettings? _pendingSound;
  bool soundLoading = true;
  bool soundSaving = false;
  Object? soundError;

  bool exporting = false;
  bool sharing = false;

  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  Future<void>? _speakerDiarizationRefresh;
  Future<void>? _timelineRefresh;
  Future<void>? _fullTextRefresh;
  bool _disposed = false;
  Timer? _speakerProgressTimer;
  bool _readingSpeakerProgress = false;

  bool get canPlay =>
      session.status == SessionStatus.completed ||
      session.status == SessionStatus.completedWithGaps;

  Future<void> initialize() async {
    _playbackSubscription ??= gateway.playbackEvents.listen(
      _handlePlaybackEvent,
      onError: (Object error) {
        if (_disposed) return;
        playbackError = error;
        notifyListeners();
      },
    );
    unawaited(loadPlaybackSound());
    await refreshContent();
  }

  void _invalidateExportIfChanged(
    Map<String, Object?> Function()? previous,
    Map<String, Object?> Function()? next,
  ) {
    // Native refreshes can return new objects containing the same saved data.
    if (exportResult != null &&
        jsonEncode(previous?.call()) != jsonEncode(next?.call())) {
      exportResult = null;
    }
  }

  Future<void> refreshContent() => Future.wait([
    refreshTimeline(),
    refreshFullTextRefinement(),
    refreshSpeakerDiarization(),
  ]);

  Future<void> refreshSpeakerDiarization() {
    if (speakerDiarizationBusy) return Future<void>.value();
    final existing = _speakerDiarizationRefresh;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    late final Future<void> refresh;
    refresh = _refreshSpeakerDiarization().whenComplete(() {
      if (identical(_speakerDiarizationRefresh, refresh)) {
        _speakerDiarizationRefresh = null;
      }
    });
    _speakerDiarizationRefresh = refresh;
    return refresh;
  }

  Future<void> _refreshSpeakerDiarization() async {
    if (!_disposed) notifyListeners();
    try {
      final snapshot = await gateway.speakerDiarization(session.directory);
      if (_disposed) return;
      _invalidateExportIfChanged(
        speakerDiarization.document?.toMap,
        snapshot.document?.toMap,
      );
      speakerDiarization = snapshot;
      loadingSpeakerDiarization = false;
      notifyListeners();
      if (snapshot.status == SpeakerDiarizationStatus.processing) {
        _startSpeakerProgress();
        final document = await gateway.analyzeSpeakers(
          sessionId: session.sessionId,
          directory: session.directory,
          requestedSpeakerCount: snapshot.requestedSpeakerCount,
        );
        if (_disposed) return;
        _invalidateExportIfChanged(
          speakerDiarization.document?.toMap,
          document.toMap,
        );
        speakerDiarization = SpeakerDiarizationSnapshot(
          status: SpeakerDiarizationStatus.ready,
          document: document,
          requestedSpeakerCount: document.requestedSpeakerCount,
        );
      }
    } catch (error) {
      var previous = speakerDiarization.document;
      try {
        previous ??= (await gateway.speakerDiarization(
          session.directory,
        )).document;
      } catch (_) {}
      if (_disposed) return;
      speakerDiarization = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.failed,
        document: previous,
        message: '$error',
      );
    } finally {
      _speakerProgressTimer?.cancel();
      loadingSpeakerDiarization = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> analyzeSpeakers({
    int? requestedSpeakerCount,
    bool forceRebuild = false,
  }) async {
    if (!canPlay ||
        speakerDiarizationBusy ||
        exporting ||
        sharing ||
        _disposed) {
      return;
    }
    final previousDocument = speakerDiarization.document;
    speakerEditError = null;
    speakerDiarizationBusy = true;
    speakerDiarization = SpeakerDiarizationSnapshot.processing(
      document: previousDocument,
      requestedSpeakerCount: requestedSpeakerCount,
    );
    notifyListeners();
    _startSpeakerProgress();
    try {
      final document = await gateway.analyzeSpeakers(
        sessionId: session.sessionId,
        directory: session.directory,
        requestedSpeakerCount: requestedSpeakerCount,
        forceRebuild: forceRebuild,
      );
      exportResult = null;
      speakerDiarization = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: document,
        requestedSpeakerCount: document.requestedSpeakerCount,
      );
    } catch (error) {
      speakerDiarization = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.failed,
        document: previousDocument,
        requestedSpeakerCount: requestedSpeakerCount,
        message: '$error',
      );
    } finally {
      _speakerProgressTimer?.cancel();
      speakerDiarizationBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _startSpeakerProgress() {
    _speakerProgressTimer?.cancel();
    _speakerProgressTimer = Timer.periodic(const Duration(seconds: 1), (
      _,
    ) async {
      if (_disposed || _readingSpeakerProgress) return;
      _readingSpeakerProgress = true;
      try {
        final snapshot = await gateway.speakerDiarization(session.directory);
        if (!_disposed &&
            _speakerProgressTimer?.isActive == true &&
            speakerDiarization.status == SpeakerDiarizationStatus.processing &&
            snapshot.status == SpeakerDiarizationStatus.processing) {
          speakerDiarization = snapshot;
          notifyListeners();
        }
      } catch (_) {
        // The joined analysis future owns failures.
      } finally {
        _readingSpeakerProgress = false;
      }
    });
  }

  Future<void> deleteSpeakerDiarization() async {
    if (speakerDiarizationBusy || exporting || sharing || _disposed) return;
    final previous = speakerDiarization;
    speakerEditError = null;
    speakerDiarizationBusy = true;
    notifyListeners();
    try {
      await gateway.deleteSpeakerDiarization(session.directory);
      exportResult = null;
      speakerDiarization = const SpeakerDiarizationSnapshot.unavailable();
    } catch (error) {
      speakerDiarization = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.failed,
        document: previous.document,
        message: '$error',
      );
    } finally {
      speakerDiarizationBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> rebuildSpeakerDiarization({int? requestedSpeakerCount}) =>
      analyzeSpeakers(
        requestedSpeakerCount: requestedSpeakerCount,
        forceRebuild: true,
      );

  Future<bool> editSpeakers(
    SpeakerDiarizationDocument expectedDocument,
    SpeakerEdit edit,
  ) async {
    if (!canPlay ||
        speakerDiarizationBusy ||
        exporting ||
        sharing ||
        _disposed ||
        speakerDiarization.status == SpeakerDiarizationStatus.processing) {
      return false;
    }
    speakerDiarizationBusy = true;
    speakerEditError = null;
    notifyListeners();
    try {
      final document = await gateway.editSpeakers(
        session.directory,
        expectedDocument: expectedDocument,
        edit: edit,
      );
      exportResult = null;
      speakerDiarization = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: document,
        requestedSpeakerCount: document.requestedSpeakerCount,
      );
      return true;
    } catch (error) {
      speakerEditError = '$error';
      try {
        final latest = await gateway.speakerDiarization(session.directory);
        if (latest.document != null) speakerDiarization = latest;
      } catch (_) {}
      return false;
    } finally {
      speakerDiarizationBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refreshFullTextRefinement() => _fullTextRefresh ??=
      _refreshFullTextRefinement().whenComplete(() => _fullTextRefresh = null);

  Future<void> _refreshFullTextRefinement() async {
    if (loadingFullTextRefinement && !_disposed) notifyListeners();
    try {
      final next = await gateway.fullTextRefinement(session.directory);
      if (_disposed) return;
      _invalidateExportIfChanged(
        fullTextRefinement.document?.toMap,
        next.document?.toMap,
      );
      fullTextRefinement = next;
    } catch (error) {
      fullTextRefinement = FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.failed,
        message: '$error',
      );
    } finally {
      loadingFullTextRefinement = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refreshTimeline() => _timelineRefresh ??= _refreshTimeline()
      .whenComplete(() => _timelineRefresh = null);

  Future<void> _refreshTimeline() async {
    timelineError = null;
    if (loadingTimeline) notifyListeners();
    try {
      final next = await gateway.timeline(session.directory);
      if (_disposed) return;
      // Stable input identities preserve long-text and timeline projection
      // caches while the poll observes an unchanged saved recording.
      if (!_sameTimeline(timeline, next)) {
        timeline = next;
        exportResult = null;
      }
      _syncCurrentPlaybackItem();
    } catch (error) {
      timelineError = error;
    } finally {
      loadingTimeline = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> playFrom(TimelineItem item) => _runPlayback(() async {
    if (!canPlay) throw StateError(l10n.anActiveRecordingCannotBePlayed);
    playbackAnchorItemId = item.playbackId;
    final next = await gateway.startPlayback(
      session.directory,
      sampleOffset: item.sampleOffset,
      anchorId: item.playbackId,
      anchorType: item.isTranscript ? 'transcript' : item.type,
    );
    _applyPlaybackSnapshot(next);
  });

  Future<void> togglePlayback() => _runPlayback(() async {
    if (!canPlay) throw StateError(l10n.anActiveRecordingCannotBePlayed);
    if (playback.isIdle) {
      playbackAnchorItemId = null;
      _applyPlaybackSnapshot(
        await gateway.startPlayback(
          session.directory,
          sampleOffset: 0,
          anchorId: session.sessionId,
          anchorType: 'session',
        ),
      );
    } else if (playback.isPlaying) {
      _applyPlaybackSnapshot(await gateway.pausePlayback());
    } else if (playback.isPaused || playback.isCompleted) {
      _applyPlaybackSnapshot(await gateway.resumePlayback());
    }
  });

  Future<void> seekToMs(int positionMs) => _runPlayback(() async {
    final sampleRate = playback.sampleRate > 0 ? playback.sampleRate : 16_000;
    final sample = positionMs * sampleRate ~/ 1_000;
    _applyPlaybackSnapshot(await gateway.seekPlayback(sample));
  });

  Future<void> stopPlayback() => _runPlayback(() async {
    _applyPlaybackSnapshot(await gateway.stopPlayback());
  });

  Future<void> loadPlaybackSound() async {
    if (_disposed || soundSaving) return;
    soundLoading = true;
    soundError = null;
    if (!_disposed) notifyListeners();
    try {
      final settings = await gateway.getPlaybackSound();
      if (_disposed) return;
      playbackSound = _savedSound = settings;
    } catch (error) {
      soundError = error;
    } finally {
      soundLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> setPlaybackSound(PlaybackSoundSettings settings) async {
    if (_disposed || soundLoading || !settings.volume.isFinite) return;
    playbackSound = PlaybackSoundSettings(
      volume: settings.volume.clamp(0.0, 1.0),
      enhanced: settings.enhanced,
    );
    _pendingSound = playbackSound;
    soundError = null;
    notifyListeners();
    if (soundSaving) return;
    soundSaving = true;
    // Serialize native updates, retaining the latest slider position during a write.
    while (_pendingSound != null) {
      final requested = _pendingSound!;
      _pendingSound = null;
      try {
        _savedSound = await gateway.setPlaybackSound(requested);
        if (_pendingSound == null) playbackSound = _savedSound;
        soundError = null;
      } catch (error) {
        soundError = error;
        if (_pendingSound == null) playbackSound = _savedSound;
      }
    }
    soundSaving = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> generateExport() async {
    if (!session.exportAvailable ||
        exporting ||
        sharing ||
        speakerDiarizationBusy ||
        speakerDiarization.status == SpeakerDiarizationStatus.processing) {
      return;
    }
    exporting = true;
    exportError = null;
    exportNotice = null;
    notifyListeners();
    try {
      exportResult = await gateway.exportSession(session.directory);
    } catch (error) {
      exportError = error;
    } finally {
      exporting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> shareExport() async {
    final result = exportResult;
    if (result == null ||
        sharing ||
        exporting ||
        speakerDiarizationBusy ||
        speakerDiarization.status == SpeakerDiarizationStatus.processing) {
      return;
    }
    sharing = true;
    exportError = null;
    exportNotice = null;
    notifyListeners();
    try {
      await gateway.shareExport(result.archivePath);
    } catch (error) {
      exportError = error;
    } finally {
      sharing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> shareStandalone(SessionShareFormat format) async {
    if (!session.exportAvailable ||
        sharing ||
        exporting ||
        _disposed ||
        speakerDiarizationBusy ||
        speakerDiarization.status == SpeakerDiarizationStatus.processing) {
      return;
    }
    sharing = true;
    exportError = null;
    exportNotice = null;
    notifyListeners();
    try {
      await transferGateway.shareSession(
        session.sessionId,
        format,
        readingText: format == SessionShareFormat.text ? _readingText : null,
      );
    } catch (error) {
      exportError = error;
    } finally {
      sharing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> copyFullText() async {
    if (!session.exportAvailable ||
        sharing ||
        exporting ||
        _disposed ||
        speakerDiarizationBusy ||
        speakerDiarization.status == SpeakerDiarizationStatus.processing) {
      return;
    }
    sharing = true;
    exportError = null;
    exportNotice = null;
    notifyListeners();
    try {
      final text = await transferGateway.readSessionText(
        session.sessionId,
        readingText: _readingText,
      );
      if (_disposed) return;
      await Clipboard.setData(ClipboardData(text: text));
      exportNotice = l10n.transcriptCopiedPasteItIntoAnotherApp;
    } catch (error) {
      exportError = error;
    } finally {
      sharing = false;
      if (!_disposed) notifyListeners();
    }
  }

  String? get _readingText =>
      loadingTimeline || timelineError != null || loadingFullTextRefinement
      ? null
      : projectFullTextForSearch(
          sessionId: session.sessionId,
          timeline: timeline,
          refinement: fullTextRefinement,
        ).text;

  Future<void> _runPlayback(Future<void> Function() operation) async {
    if (playbackBusy || _disposed) return;
    playbackBusy = true;
    playbackError = null;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      if (_disposed) return;
      playbackError = error;
      try {
        playback = await gateway.stopPlayback();
      } catch (_) {
        playback = PlaybackSnapshot.idle();
      }
      playbackAnchorItemId = null;
      currentPlaybackItemId = null;
    } finally {
      playbackBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void clearPlaybackError() {
    playbackError = null;
    notifyListeners();
  }

  void _handlePlaybackEvent(PlaybackSnapshot value) {
    if (_disposed) return;
    final belongsToSession = value.directory == session.directory;
    final stopsCurrentSession =
        value.isIdle && playback.directory == session.directory;
    if (!belongsToSession && !stopsCurrentSession) return;
    _applyPlaybackSnapshot(value);
    playbackError = value.error;
    notifyListeners();
  }

  void _applyPlaybackSnapshot(PlaybackSnapshot value) {
    if (_disposed) return;
    playback = value;
    if (value.isIdle) {
      playbackAnchorItemId = null;
      currentPlaybackItemId = null;
      return;
    }
    _syncCurrentPlaybackItem();
  }

  void _syncCurrentPlaybackItem() {
    if (playback.isIdle) {
      currentPlaybackItemId = null;
      return;
    }
    currentPlaybackItemId = timelineItemAtSample(
      timeline,
      playback.positionSample,
    )?.playbackId;
  }

  @override
  void dispose() {
    _disposed = true;
    _speakerProgressTimer?.cancel();
    unawaited(_playbackSubscription?.cancel());
    // Native playback commands are serialized. Enqueue stop now, before a new
    // page can enqueue play, even when this page's start has not replied yet.
    if (playbackBusy ||
        (playback.directory == session.directory && !playback.isIdle)) {
      unawaited(
        gateway.stopPlayback().catchError(
          (Object _) => PlaybackSnapshot.idle(),
        ),
      );
    }
    super.dispose();
  }
}

TimelineItem? timelineItemAtSample(
  List<TimelineItem> timeline,
  int positionSample,
) {
  var lower = 0;
  var upper = timeline.length;
  while (lower < upper) {
    final middle = lower + ((upper - lower) >> 1);
    if (timeline[middle].sampleOffset <= positionSample) {
      lower = middle + 1;
    } else {
      upper = middle;
    }
  }
  return lower == 0 ? null : timeline[lower - 1];
}

bool _sameTimeline(List<TimelineItem> left, List<TimelineItem> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    final a = left[i];
    final b = right[i];
    if (a.kind != b.kind ||
        a.sampleOffset != b.sampleOffset ||
        a.endSample != b.endSample ||
        a.atMs != b.atMs ||
        a.type != b.type ||
        a.text != b.text ||
        a.endMs != b.endMs ||
        a.sequence != b.sequence ||
        a.eventId != b.eventId ||
        a.captureState != b.captureState ||
        a.assetState != b.assetState ||
        a.assetPath != b.assetPath ||
        a.monotonicElapsedNs != b.monotonicElapsedNs ||
        a.wallTime != b.wallTime ||
        !mapEquals(a.payload, b.payload)) {
      return false;
    }
  }
  return true;
}
