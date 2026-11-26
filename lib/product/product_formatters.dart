import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../domain/session/session_summary.dart';

String formatDuration(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).floor().clamp(0, 359999);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(hours)}:${two(minutes)}:${two(seconds)}';
}

String formatSessionDate(DateTime date) {
  initializeDateFormatting(l10n.localeName);
  final pattern = l10n.localeName == 'zh' ? 'M月d日 HH:mm' : 'MMM d, HH:mm';
  return DateFormat(pattern, l10n.localeName).format(date.toLocal());
}

String defaultSessionTitle(DateTime date) =>
    l10n.recordingAtDate(formatSessionDate(date));

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final decimals = value >= 10 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unit]}';
}

String sessionStatusLabel(SessionStatus status) => switch (status) {
  SessionStatus.authorizing => l10n.waitingForPermission,
  SessionStatus.preparing => l10n.starting,
  SessionStatus.recording => l10n.recording,
  SessionStatus.pausing => l10n.pausing,
  SessionStatus.paused => l10n.paused,
  SessionStatus.resuming => l10n.resuming,
  SessionStatus.interrupted => l10n.interrupted,
  SessionStatus.finalizing => l10n.finishingSafely,
  SessionStatus.completed => l10n.complete,
  SessionStatus.completedWithGaps => l10n.hasGaps,
  SessionStatus.recovering => l10n.recovering,
  SessionStatus.failed => l10n.needsAttention,
  SessionStatus.unknown => l10n.unknownStatus,
};

String? localizedTextLayer(String? value) => switch (value) {
  '精修文字（部分回退实时原文）' => l10n.refinedTextWithSomeOriginalSegments,
  '精修文字' => l10n.refinedText,
  '实时原文' => l10n.originalTranscript,
  _ => value,
};
