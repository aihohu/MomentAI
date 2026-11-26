import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/audio/playback_snapshot.dart';
import '../../domain/timeline/timeline_item.dart';
import '../../poc/poc_bridge.dart';

class Stage1PlaybackController extends ChangeNotifier {
  Stage1PlaybackController({required this.bridge});

  final PoCBridge bridge;
  PlaybackSnapshot snapshot = PlaybackSnapshot.idle();
  String? selectedItemId;
  String? error;
  bool operationInProgress = false;

  StreamSubscription<PlaybackSnapshot>? _subscription;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_subscription != null || _disposed) return;
    _subscription = bridge.playbackEvents.listen(
      (value) {
        if (_disposed) return;
        snapshot = value;
        error = value.error;
        notifyListeners();
      },
      onError: (Object value) {
        if (_disposed) return;
        error = '$value';
        notifyListeners();
      },
    );
  }

  Future<void> playFrom(String directory, TimelineItem item) => _run(() async {
    selectedItemId = item.playbackId;
    snapshot = await bridge.startPlayback(
      directory,
      sampleOffset: item.sampleOffset,
      anchorId: item.playbackId,
      anchorType: item.isTranscript ? 'transcript' : item.type,
    );
  });

  Future<void> toggle() => _run(() async {
    if (snapshot.isPlaying) {
      snapshot = await bridge.pausePlayback();
    } else if (snapshot.isPaused || snapshot.isCompleted) {
      snapshot = await bridge.resumePlayback();
    }
  });

  Future<void> seek(int sampleOffset) => _run(() async {
    snapshot = await bridge.seekPlayback(sampleOffset);
  });

  Future<void> stop() => _run(() async {
    snapshot = await bridge.stopPlayback();
    selectedItemId = null;
  });

  Future<void> _run(Future<void> Function() operation) async {
    if (operationInProgress || _disposed) return;
    operationInProgress = true;
    error = null;
    notifyListeners();
    try {
      await operation();
    } catch (value) {
      error = '$value';
    } finally {
      operationInProgress = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
