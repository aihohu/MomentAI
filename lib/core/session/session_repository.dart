import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/session/session_summary.dart';

abstract interface class SessionRepository {
  Stream<List<SessionSummary>> watchSessions();
  Future<List<SessionSummary>> listSessions();
  Future<SessionSummary> getSession(String sessionId);
  Future<SessionSummary> renameSession(String sessionId, String title);
  Future<void> deleteSession(String sessionId);
  Future<StorageOverview> storageOverview();
}

class NativeSessionRepository implements SessionRepository {
  static const _channel = MethodChannel(
    'org.hohu.momentai.product/session_repository',
  );

  final _sessions = StreamController<List<SessionSummary>>.broadcast();

  @override
  Stream<List<SessionSummary>> watchSessions() => _sessions.stream;

  @override
  Future<List<SessionSummary>> listSessions() async {
    _ensureMobile();
    final raw =
        await _channel.invokeListMethod<Object?>('listSessions') ?? const [];
    final sessions = raw
        .map((item) => SessionSummary.fromMap(_map(item)))
        .toList(growable: false);
    _sessions.add(sessions);
    return sessions;
  }

  @override
  Future<SessionSummary> getSession(String sessionId) async {
    _ensureMobile();
    return SessionSummary.fromMap(
      _map(
        await _channel.invokeMethod<Object?>('getSession', {
          'sessionId': sessionId,
        }),
      ),
    );
  }

  @override
  Future<SessionSummary> renameSession(String sessionId, String title) async {
    _ensureMobile();
    final renamed = SessionSummary.fromMap(
      _map(
        await _channel.invokeMethod<Object?>('renameSession', {
          'sessionId': sessionId,
          'title': title,
        }),
      ),
    );
    await listSessions();
    return renamed;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _ensureMobile();
    await _channel.invokeMethod<Object?>('deleteSession', {
      'sessionId': sessionId,
    });
    await listSessions();
  }

  @override
  Future<StorageOverview> storageOverview() async {
    _ensureMobile();
    return StorageOverview.fromMap(
      _map(await _channel.invokeMethod<Object?>('storageOverview')),
    );
  }

  void _ensureMobile() {
    if (!Platform.isIOS && !Platform.isAndroid) {
      throw UnsupportedError(l10n.momentaiRecordingStorageIsAvailableOnlyOn);
    }
  }
}

Map<Object?, Object?> _map(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return Map<Object?, Object?>.from(value);
  return const {};
}
