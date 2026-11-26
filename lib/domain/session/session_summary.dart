enum SessionStatus {
  authorizing,
  preparing,
  recording,
  pausing,
  paused,
  resuming,
  interrupted,
  finalizing,
  completed,
  completedWithGaps,
  recovering,
  failed,
  unknown;

  factory SessionStatus.fromWireValue(String value) => switch (value) {
    'authorizing' => authorizing,
    'preparing' => preparing,
    'recording' => recording,
    'pausing' => pausing,
    'paused' => paused,
    'resuming' => resuming,
    'interrupted' => interrupted,
    'finalizing' => finalizing,
    'completed' => completed,
    'completed_with_gaps' => completedWithGaps,
    'recovering' => recovering,
    'failed' || 'failed_to_start' => failed,
    _ => unknown,
  };

  bool get isActive => switch (this) {
    authorizing ||
    preparing ||
    recording ||
    pausing ||
    paused ||
    resuming ||
    interrupted ||
    finalizing => true,
    _ => false,
  };
}

class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.directory,
    required this.title,
    required this.status,
    required this.startedAt,
    required this.durationSamples,
    required this.durationMs,
    required this.chunkCount,
    required this.transcriptCount,
    required this.imageCount,
    required this.thoughtCount,
    required this.bookmarkCount,
    required this.recoveryCount,
    required this.hasConfirmedGaps,
    required this.exportAvailable,
    this.stoppedAt,
    this.importedFromSessionId = '',
  });

  factory SessionSummary.fromMap(Map<Object?, Object?> map) {
    return SessionSummary(
      sessionId: map['sessionId']?.toString() ?? '',
      directory: map['directory']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      status: SessionStatus.fromWireValue(map['state']?.toString() ?? ''),
      startedAt:
          _date(map['startedAtWall']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      stoppedAt: _date(map['stoppedAtWall']),
      durationSamples: _integer(map['durationSamples']),
      durationMs: _integer(map['durationMs']),
      chunkCount: _integer(map['chunkCount']),
      transcriptCount: _integer(map['transcriptCount']),
      imageCount: _integer(map['imageCount']),
      thoughtCount: _integer(map['thoughtCount']),
      bookmarkCount: _integer(map['bookmarkCount']),
      recoveryCount: _integer(map['recoveryCount']),
      hasConfirmedGaps: map['hasConfirmedGaps'] == true,
      exportAvailable: map['exportAvailable'] == true,
      importedFromSessionId: map['importedFromSessionId']?.toString() ?? '',
    );
  }

  final String sessionId;
  final String directory;
  final String title;
  final SessionStatus status;
  final DateTime startedAt;
  final DateTime? stoppedAt;
  final int durationSamples;
  final int durationMs;
  final int chunkCount;
  final int transcriptCount;
  final int imageCount;
  final int thoughtCount;
  final int bookmarkCount;
  final int recoveryCount;
  final bool hasConfirmedGaps;
  final bool exportAvailable;
  final String importedFromSessionId;

  int get anchorCount => imageCount + thoughtCount + bookmarkCount;
}

class StorageOverview {
  const StorageOverview({
    required this.appUsedBytes,
    required this.availableBytes,
    required this.totalBytes,
    required this.minimumRequiredBytes,
    required this.canStartRecording,
    required this.sessionCount,
  });

  const StorageOverview.empty()
    : appUsedBytes = 0,
      availableBytes = 0,
      totalBytes = 0,
      minimumRequiredBytes = 512 * 1024 * 1024,
      canStartRecording = true,
      sessionCount = 0;

  factory StorageOverview.fromMap(Map<Object?, Object?> map) => StorageOverview(
    appUsedBytes: _integer(map['appUsedBytes']),
    availableBytes: _integer(map['availableBytes']),
    totalBytes: _integer(map['totalBytes']),
    minimumRequiredBytes: _integer(map['minimumRequiredBytes']),
    canStartRecording: map['canStartRecording'] != false,
    sessionCount: _integer(map['sessionCount']),
  );

  final int appUsedBytes;
  final int availableBytes;
  final int totalBytes;
  final int minimumRequiredBytes;
  final bool canStartRecording;
  final int sessionCount;
}

int _integer(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;

DateTime? _date(Object? value) {
  final raw = value?.toString() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
