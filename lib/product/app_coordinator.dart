import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../core/capture/capture_gateway.dart';
import '../core/session/session_repository.dart';
import '../core/system/product_system_gateway.dart';
import '../domain/session/session_summary.dart';
import '../domain/timeline/timeline_item.dart';
import '../poc/poc_bridge.dart';

class AppCoordinator extends ChangeNotifier with WidgetsBindingObserver {
  AppCoordinator({
    required this.captureGateway,
    required this.sessionRepository,
    required this.systemGateway,
    this.modelOperationActive,
    this.modelOperationChanges,
  });

  final CaptureGateway captureGateway;
  final SessionRepository sessionRepository;
  final ProductSystemGateway systemGateway;
  final bool Function()? modelOperationActive;
  final Listenable? modelOperationChanges;

  StreamSubscription<PoCSnapshot>? _captureSubscription;
  StreamSubscription<List<SessionSummary>>? _sessionSubscription;
  bool _initialized = false;
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  PoCSnapshot _capture = PoCSnapshot.idle();
  List<SessionSummary> _sessions = const [];
  List<RecoveryCandidate> _recoveryCandidates = const [];
  StorageOverview _storage = const StorageOverview.empty();
  ProductSystemOverview _system = const ProductSystemOverview.empty();
  Object? _systemError;
  List<TimelineItem> _captureTimeline = const [];
  Object? _timelineError;
  String? _captureAction;
  String? _backgroundExitAcknowledgedSessionId;
  bool _cameraPurposeExplained = false;
  Future<void> _timelineRefreshTail = Future<void>.value();

  bool get isLoading => _loading;
  bool get isBusy => _busy;
  Object? get error => _error;
  PoCSnapshot get capture => _capture;
  List<SessionSummary> get sessions => _sessions;
  List<RecoveryCandidate> get recoveryCandidates => _recoveryCandidates;
  StorageOverview get storage => _storage;
  ProductSystemOverview get system => _system;
  Object? get systemError => _systemError;
  List<TimelineItem> get captureTimeline => _captureTimeline;
  Object? get timelineError => _timelineError;
  String? get captureAction => _captureAction;
  bool get isCaptureActionBusy => _captureAction != null;
  bool get canAddCaptureEvent =>
      const {'recording', 'paused'}.contains(_capture.state) &&
      !_busy &&
      !isCaptureActionBusy;
  bool get cameraPurposeExplained => _cameraPurposeExplained;
  bool get needsBackgroundExitConfirmation =>
      _capture.sessionId.isNotEmpty &&
      _backgroundExitAcknowledgedSessionId != _capture.sessionId;

  bool get hasActiveCapture =>
      _capture.isActiveCapture || _capture.isTransitioning;
  bool get isModelOperationActive => modelOperationActive?.call() ?? false;

  SessionSummary? get activeSession {
    final sessionId = _capture.sessionId;
    if (sessionId.isEmpty) return null;
    for (final session in _sessions) {
      if (session.sessionId == sessionId) return session;
    }
    return null;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    modelOperationChanges?.addListener(notifyListeners);
    WidgetsBinding.instance.addObserver(this);
    _captureSubscription = captureGateway.events.listen(
      _handleCaptureEvent,
      onError: _handleBackgroundError,
    );
    _sessionSubscription = sessionRepository.watchSessions().listen((sessions) {
      _sessions = sessions;
      notifyListeners();
    }, onError: _handleBackgroundError);
    await refresh();
  }

  Future<void> refresh() async {
    Object? refreshError;
    try {
      _sessions = await sessionRepository.listSessions();
    } catch (error) {
      refreshError = error;
    }
    try {
      _storage = await sessionRepository.storageOverview();
    } catch (error) {
      refreshError ??= error;
    }
    try {
      _system = await systemGateway.overview();
      _systemError = null;
    } catch (error) {
      _systemError = error;
      refreshError ??= error;
    }
    try {
      _capture = await captureGateway.snapshot();
      await refreshCaptureTimeline();
    } catch (error) {
      refreshError ??= error;
    }
    try {
      _recoveryCandidates = await captureGateway.scanRecovery();
    } catch (error) {
      refreshError ??= error;
    } finally {
      _error = refreshError;
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshSessions() async {
    Object? refreshError;
    try {
      _sessions = await sessionRepository.listSessions();
    } catch (error) {
      refreshError = error;
    }
    try {
      _storage = await sessionRepository.storageOverview();
    } catch (error) {
      refreshError ??= error;
    } finally {
      _error = refreshError;
      notifyListeners();
    }
  }

  Future<PoCSnapshot> startRecording(String title) async {
    if (isModelOperationActive) {
      throw StateError(l10n.aLocalModelTaskIsRunningWait);
    }
    if (_busy || hasActiveCapture) return _capture;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await _requirePermission(ProductPermission.microphone);
      _captureTimeline = const [];
      _timelineError = null;
      _capture = await captureGateway.start(title: title);
      await refreshCaptureTimeline();
      await refreshSessions();
      return _capture;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<PoCSnapshot> stopRecording() async {
    if (_busy || isCaptureActionBusy || !_capture.canStop) return _capture;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      _capture = await captureGateway.stop();
      await refreshCaptureTimeline();
      await _refreshRecoveryCandidates();
      await refreshSessions();
      return _capture;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<PoCSnapshot> pauseRecording() async {
    if (_busy || isCaptureActionBusy || !_capture.canPause) return _capture;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      _capture = await captureGateway.pause();
      await refreshCaptureTimeline();
      await refreshSessions();
      return _capture;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<PoCSnapshot> resumeRecording() async {
    if (_busy || isCaptureActionBusy || !_capture.canResume) return _capture;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      _capture = await captureGateway.resume();
      await refreshCaptureTimeline();
      await refreshSessions();
      return _capture;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<RecoveryOutcome> recoverSession(RecoveryCandidate candidate) async {
    if (isModelOperationActive) {
      throw StateError(l10n.aModelIsDownloadingVerifyingInstallingOr);
    }
    if (_busy) throw StateError(l10n.anotherOperationIsInProgress);
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final currentCandidates = await captureGateway.scanRecovery();
      _recoveryCandidates = currentCandidates;
      final isStillRecoverable = currentCandidates.any(
        (current) =>
            current.sessionId == candidate.sessionId &&
            current.directory == candidate.directory,
      );
      if (!isStillRecoverable) {
        throw StateError(l10n.thisRecordingHasEndedOrItsRecovery);
      }
      final outcome = await captureGateway.recover(candidate.directory);
      _recoveryCandidates = await captureGateway.scanRecovery();
      await refreshSessions();
      return outcome;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<SessionSummary> renameSession(
    SessionSummary session,
    String title,
  ) async {
    if (_busy ||
        session.status.isActive ||
        session.status == SessionStatus.recovering) {
      throw StateError(l10n.thisRecordingCannotBeRenamedInIts);
    }
    _busy = true;
    notifyListeners();
    try {
      final renamed = await sessionRepository.renameSession(
        session.sessionId,
        title,
      );
      _sessions = _sessions
          .map((item) => item.sessionId == renamed.sessionId ? renamed : item)
          .toList(growable: false);
      return renamed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> deleteSession(SessionSummary session) async {
    if (_busy ||
        session.status.isActive ||
        session.status == SessionStatus.recovering) {
      throw StateError(l10n.thisRecordingCannotBeDeletedInIts);
    }
    _busy = true;
    notifyListeners();
    try {
      await sessionRepository.deleteSession(session.sessionId);
      _sessions = _sessions
          .where((item) => item.sessionId != session.sessionId)
          .toList(growable: false);
      _storage = await sessionRepository.storageOverview();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> openSystemSettings() => systemGateway.openSystemSettings();

  Future<void>? _permissionRequest;
  bool get requestingPermission => _permissionRequest != null;

  Future<void> requestPermission(ProductPermission permission) {
    final pending = _permissionRequest;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _requestAndRefreshPermission(permission).whenComplete(() {
      if (identical(_permissionRequest, operation)) _permissionRequest = null;
      notifyListeners();
    });
    _permissionRequest = operation;
    notifyListeners();
    return operation;
  }

  Future<void> _requestAndRefreshPermission(
    ProductPermission permission,
  ) async {
    await systemGateway.requestPermission(permission);
    await _refreshSystemOverview();
  }

  Future<void> _refreshSystemOverview() async {
    try {
      _system = await systemGateway.overview();
      _systemError = null;
    } catch (error) {
      _systemError = error;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _requirePermission(ProductPermission permission) async {
    try {
      final pending = _permissionRequest;
      if (pending != null) await pending;
      // Re-read at the point of use: Settings may have revoked a cached grant.
      await _refreshSystemOverview();
      if (_permissionStatus(permission).canRequest) {
        await requestPermission(permission);
      }
    } catch (_) {
      throw ProductPermissionException(
        permission,
        ProductPermissionStatus.unknown,
      );
    }
    final status = _permissionStatus(permission);
    if (status != ProductPermissionStatus.authorized) {
      throw ProductPermissionException(permission, status);
    }
  }

  ProductPermissionStatus _permissionStatus(ProductPermission permission) =>
      permission == ProductPermission.microphone
      ? _system.microphonePermission
      : _system.cameraPermission;

  Future<Map<Object?, Object?>> openCamera() =>
      _runCaptureAction('camera', () async {
        await _requirePermission(ProductPermission.camera);
        return captureGateway.openCamera();
      });

  Future<Map<Object?, Object?>> addBookmark() =>
      _runCaptureAction('bookmark', captureGateway.addBookmark);

  Future<Map<Object?, Object?>> addThought(String text) =>
      _runCaptureAction('thought', () => captureGateway.addThought(text));

  void markCameraPurposeExplained() {
    _cameraPurposeExplained = true;
  }

  void acknowledgeBackgroundExit() {
    _backgroundExitAcknowledgedSessionId = _capture.sessionId;
  }

  Future<void> refreshCaptureTimeline() {
    final directory = _capture.directory;
    if (directory.isEmpty) {
      _captureTimeline = const [];
      _timelineError = null;
      notifyListeners();
      return Future<void>.value();
    }
    final refresh = _timelineRefreshTail.then((_) async {
      try {
        _captureTimeline = await captureGateway.timeline(directory);
        _timelineError = null;
      } catch (error) {
        _timelineError = error;
      }
      notifyListeners();
    });
    _timelineRefreshTail = refresh.catchError((_) {});
    return refresh;
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void _handleCaptureEvent(PoCSnapshot snapshot) {
    final previousState = _capture.state;
    final previousSession = _capture.sessionId;
    _capture = snapshot;
    notifyListeners();
    if (previousSession != snapshot.sessionId &&
        snapshot.sessionId.isNotEmpty) {
      _captureTimeline = const [];
      _timelineError = null;
    }
    if (const {
      'image',
      'image_failed',
      'bookmark',
      'thought',
      'user_pause_began',
      'user_pause_ended',
    }.contains(snapshot.event)) {
      unawaited(refreshCaptureTimeline());
    }
    if (previousState != snapshot.state ||
        previousSession != snapshot.sessionId ||
        snapshot.event == 'session_stopped') {
      unawaited(refreshSessions());
      if (snapshot.event == 'session_stopped') {
        unawaited(_refreshRecoveryCandidates().then((_) => notifyListeners()));
      }
    }
  }

  void _handleBackgroundError(Object error, StackTrace stackTrace) {
    _error = error;
    notifyListeners();
  }

  Future<void> _refreshRecoveryCandidates() async {
    _recoveryCandidates = const [];
    try {
      _recoveryCandidates = await captureGateway.scanRecovery();
    } catch (error) {
      _error ??= error;
    }
  }

  Future<Map<Object?, Object?>> _runCaptureAction(
    String action,
    Future<Map<Object?, Object?>> Function() operation,
  ) async {
    if (!canAddCaptureEvent) {
      throw StateError(l10n.notesCannotBeAddedInTheCurrent);
    }
    _captureAction = action;
    notifyListeners();
    try {
      final result = await operation();
      await refreshCaptureTimeline();
      return result;
    } finally {
      _captureAction = null;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    modelOperationChanges?.removeListener(notifyListeners);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_captureSubscription?.cancel());
    unawaited(_sessionSubscription?.cancel());
    super.dispose();
  }
}
