import '../../domain/timeline/timeline_item.dart';
import '../../poc/poc_bridge.dart';

abstract interface class CaptureGateway {
  Stream<PoCSnapshot> get events;
  Future<PoCSnapshot> snapshot();
  Future<PoCSnapshot> start({required String title});
  Future<PoCSnapshot> stop();
  Future<PoCSnapshot> pause();
  Future<PoCSnapshot> resume();
  Future<List<RecoveryCandidate>> scanRecovery();
  Future<RecoveryOutcome> recover(String directory);
  Future<Map<Object?, Object?>> openCamera();
  Future<Map<Object?, Object?>> addBookmark();
  Future<Map<Object?, Object?>> addThought(String text);
  Future<List<TimelineItem>> timeline(String directory);
}

class ProductCaptureGateway implements CaptureGateway {
  const ProductCaptureGateway(this._bridge);

  final PoCBridge _bridge;

  @override
  Stream<PoCSnapshot> get events => _bridge.events;

  @override
  Future<List<RecoveryCandidate>> scanRecovery() => _bridge.scanRecovery();

  @override
  Future<RecoveryOutcome> recover(String directory) async =>
      RecoveryOutcome.fromMap(await _bridge.recover(directory));

  @override
  Future<Map<Object?, Object?>> openCamera() => _bridge.openCamera();

  @override
  Future<Map<Object?, Object?>> addBookmark() => _bridge.addBookmark();

  @override
  Future<Map<Object?, Object?>> addThought(String text) =>
      _bridge.addThought(text);

  @override
  Future<List<TimelineItem>> timeline(String directory) =>
      _bridge.timeline(directory);

  @override
  Future<PoCSnapshot> snapshot() => _bridge.snapshot();

  @override
  Future<PoCSnapshot> start({required String title}) =>
      _bridge.start(title: title);

  @override
  Future<PoCSnapshot> stop() => _bridge.stop();

  @override
  Future<PoCSnapshot> pause() => _bridge.pauseRecording();

  @override
  Future<PoCSnapshot> resume() => _bridge.resumeRecording();
}
