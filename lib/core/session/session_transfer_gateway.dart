import 'package:flutter/services.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/session/session_summary.dart';

enum SessionShareFormat { text, markdown, audio }

class SessionImportPreview {
  const SessionImportPreview({
    required this.token,
    required this.sessionId,
    required this.title,
    required this.startedAt,
    required this.stoppedAt,
    required this.durationSamples,
    required this.archiveBytes,
    required this.timelineItemCount,
    required this.hasConfirmedGaps,
    required this.conflict,
  });

  factory SessionImportPreview.fromMap(Map<Object?, Object?> map) =>
      SessionImportPreview(
        token: map['token'] as String,
        sessionId: map['sessionId'] as String,
        title: map['title'] as String,
        startedAt: DateTime.parse(map['startedAtWall'] as String).toLocal(),
        stoppedAt: DateTime.parse(map['stoppedAtWall'] as String).toLocal(),
        durationSamples: (map['durationSamples'] as num).toInt(),
        archiveBytes: (map['archiveBytes'] as num).toInt(),
        timelineItemCount: (map['timelineItemCount'] as num).toInt(),
        hasConfirmedGaps: map['hasConfirmedGaps'] == true,
        conflict: map['conflict'] == true,
      );

  final String token;
  final String sessionId;
  final String title;
  final DateTime startedAt;
  final DateTime stoppedAt;
  final int durationSamples;
  final int archiveBytes;
  final int timelineItemCount;
  final bool hasConfirmedGaps;
  final bool conflict;
}

abstract interface class SessionTransferGateway {
  Future<void> shareSession(
    String sessionId,
    SessionShareFormat format, {
    String? readingText,
  });
  Future<String> readSessionText(String sessionId, {String? readingText});
  Future<SessionImportPreview?> pickImport();
  Future<SessionSummary> commitImport(String token, {required bool asCopy});
  Future<void> cancelImport();
}

class NativeSessionTransferGateway implements SessionTransferGateway {
  const NativeSessionTransferGateway();
  static const _channel = MethodChannel('org.hohu.momentai.product/transfer');

  @override
  Future<void> shareSession(
    String sessionId,
    SessionShareFormat format, {
    String? readingText,
  }) => _channel.invokeMethod<void>('shareSession', {
    'sessionId': sessionId,
    'format': format.name,
    'readingText': ?readingText,
  });

  @override
  Future<String> readSessionText(
    String sessionId, {
    String? readingText,
  }) async {
    final text = await _channel.invokeMethod<String>('readSessionText', {
      'sessionId': sessionId,
      'readingText': ?readingText,
    });
    if (text == null) throw StateError(l10n.noTextWasReturnedToCopy);
    return text;
  }

  @override
  Future<SessionImportPreview?> pickImport() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('pickImport');
    return raw == null ? null : SessionImportPreview.fromMap(raw);
  }

  @override
  Future<SessionSummary> commitImport(
    String token, {
    required bool asCopy,
  }) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'commitImport',
      {'token': token, 'asCopy': asCopy},
    );
    if (raw == null) throw StateError(l10n.importDidNotReturnARecording);
    return SessionSummary.fromMap(raw);
  }

  @override
  Future<void> cancelImport() => _channel.invokeMethod<void>('cancelImport');
}

String sessionTransferError(Object error) => error is PlatformException
    ? error.message ?? l10n.operationFailedTryAgain
    : l10n.operationFailedExistingRecordingsAreUnchangedSelect;
