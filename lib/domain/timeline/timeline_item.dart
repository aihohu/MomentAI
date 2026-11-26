class TimelineItem {
  const TimelineItem({
    required this.kind,
    required this.sampleOffset,
    required this.endSample,
    required this.atMs,
    required this.type,
    required this.text,
    required this.endMs,
    required this.payload,
    required this.sequence,
    required this.eventId,
    required this.captureState,
    required this.assetState,
    required this.assetPath,
    required this.monotonicElapsedNs,
    this.wallTime = '',
  });

  factory TimelineItem.fromMap(Map<Object?, Object?> map) {
    final kind = map['kind']?.toString() ?? 'event';
    final sampleOffset = _number(map['sampleOffset']);
    return TimelineItem(
      kind: kind,
      sampleOffset: sampleOffset,
      endSample: _number(map['endSample'], fallback: sampleOffset),
      atMs: _number(
        kind == 'transcript' ? map['startMs'] : map['atMs'],
        fallback: sampleOffset * 1000 ~/ 16000,
      ),
      type: map['type']?.toString() ?? kind,
      text: map['text']?.toString() ?? '',
      endMs: _number(map['endMs']),
      payload: _map(map['payload']),
      sequence: _number(map['sequence']),
      eventId: map['eventId']?.toString() ?? map['segmentId']?.toString() ?? '',
      captureState: map['captureState']?.toString() ?? '',
      assetState: _map(map['payload'])['assetState']?.toString() ?? '',
      assetPath: map['assetPath']?.toString() ?? '',
      monotonicElapsedNs: _number(map['monotonicElapsedNs']),
      wallTime: map['wallTime']?.toString() ?? '',
    );
  }

  final String kind;
  final int sampleOffset;
  final int endSample;
  final int atMs;
  final String type;
  final String text;
  final int endMs;
  final Map<Object?, Object?> payload;
  final int sequence;
  final String eventId;
  final String captureState;
  final String assetState;
  final String assetPath;
  final int monotonicElapsedNs;
  final String wallTime;

  bool get isTranscript => kind == 'transcript';
  bool get isCaptureEvent => kind == 'captureEvent';
  bool get isImage => isCaptureEvent && type == 'image';
  bool get isBookmark => isCaptureEvent && type == 'bookmark';
  bool get isThought => isCaptureEvent && type == 'thought';
  bool get isCommitted => captureState == 'committed';
  String get playbackId =>
      eventId.isNotEmpty ? eventId : '$kind:$type:$sampleOffset:$sequence';
}

int _number(Object? value, {int fallback = 0}) =>
    value is num ? value.round() : int.tryParse('$value') ?? fallback;

Map<Object?, Object?> _map(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return Map<Object?, Object?>.from(value);
  return const {};
}
