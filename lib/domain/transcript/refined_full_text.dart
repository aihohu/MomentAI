enum FullTextRefinementStatus { unavailable, processing, ready, failed }

const refinedFullTextSchemaVersion = 4;
const refinedTimelineComposerVersion = 4;

class RefinedFullTextSegment {
  const RefinedFullTextSegment({
    required this.startSample,
    required this.endSample,
    required this.text,
    required this.language,
    required this.emotion,
    required this.event,
  });

  factory RefinedFullTextSegment.fromMap(Map<String, dynamic> map) =>
      RefinedFullTextSegment(
        startSample: _integer(map['startSample']),
        endSample: _integer(map['endSample']),
        text: map['text']?.toString() ?? '',
        language: map['language']?.toString() ?? '',
        emotion: map['emotion']?.toString() ?? '',
        event: map['event']?.toString() ?? '',
      );

  final int startSample;
  final int endSample;
  final String text;
  final String language;
  final String emotion;
  final String event;

  Map<String, Object?> toMap() => <String, Object?>{
    'startSample': startSample,
    'endSample': endSample,
    'text': text,
    'language': language,
    'emotion': emotion,
    'event': event,
  };
}

class RefinedFullTextToken {
  const RefinedFullTextToken({
    required this.text,
    required this.atSample,
    required this.sourceWindowIndex,
    required this.sourceTokenIndex,
  });

  factory RefinedFullTextToken.fromMap(Map<String, dynamic> map) =>
      RefinedFullTextToken(
        text: map['text']?.toString() ?? '',
        atSample: _integer(map['atSample']),
        sourceWindowIndex: _integer(map['sourceWindowIndex']),
        sourceTokenIndex: _integer(map['sourceTokenIndex']),
      );

  final String text;
  final int atSample;
  final int sourceWindowIndex;
  final int sourceTokenIndex;

  Map<String, Object?> toMap() => <String, Object?>{
    'text': text,
    'atSample': atSample,
    'sourceWindowIndex': sourceWindowIndex,
    'sourceTokenIndex': sourceTokenIndex,
  };
}

class RefinedTimelineSegment {
  const RefinedTimelineSegment({
    required this.segmentId,
    required this.startSample,
    required this.endSample,
    required this.refinedText,
    required this.fallback,
  });

  factory RefinedTimelineSegment.fromMap(Map<String, dynamic> map) =>
      RefinedTimelineSegment(
        segmentId: map['segmentId']?.toString() ?? '',
        startSample: _integer(map['startSample']),
        endSample: _integer(map['endSample']),
        refinedText: map['refinedText']?.toString() ?? '',
        fallback: map['fallback'] == true,
      );

  final String segmentId;
  final int startSample;
  final int endSample;
  final String refinedText;
  final bool fallback;

  Map<String, Object?> toMap() => <String, Object?>{
    'segmentId': segmentId,
    'startSample': startSample,
    'endSample': endSample,
    'refinedText': refinedText,
    'fallback': fallback,
  };
}

class RefinedFullTextDocument {
  const RefinedFullTextDocument({
    required this.sessionId,
    required this.modelId,
    required this.fullText,
    required this.sourceAudioSamples,
    required this.sampleRate,
    required this.createdAt,
    required this.segments,
    required this.initializationMs,
    required this.decodeMs,
    required this.realTimeFactor,
    required this.peakRssBytes,
    this.sourceTimelineFingerprint = '',
    this.composerVersion = refinedTimelineComposerVersion,
    this.canonicalTokens = const [],
    this.timelineProjection = const [],
  });

  factory RefinedFullTextDocument.fromMap(
    Map<String, dynamic> map,
  ) => RefinedFullTextDocument(
    sessionId: map['sessionId']?.toString() ?? '',
    modelId: map['modelId']?.toString() ?? '',
    fullText: map['fullText']?.toString() ?? '',
    sourceAudioSamples: _integer(map['sourceAudioSamples']),
    sampleRate: _integer(map['sampleRate'], fallback: 16000),
    createdAt:
        DateTime.tryParse(map['createdAt']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    segments: (map['segments'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              RefinedFullTextSegment.fromMap(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false),
    initializationMs: _integer(map['initializationMs']),
    decodeMs: _integer(map['decodeMs']),
    realTimeFactor: _decimal(map['realTimeFactor']),
    peakRssBytes: _integer(map['peakRssBytes']),
    sourceTimelineFingerprint:
        map['sourceTimelineFingerprint']?.toString() ?? '',
    composerVersion: _integer(map['composerVersion']),
    canonicalTokens: (map['canonicalTokens'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              RefinedFullTextToken.fromMap(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false),
    timelineProjection:
        (map['timelineProjection'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map(
              (item) => RefinedTimelineSegment.fromMap(
                Map<String, dynamic>.from(item),
              ),
            )
            .toList(growable: false),
  );

  final String sessionId;
  final String modelId;
  final String fullText;
  final int sourceAudioSamples;
  final int sampleRate;
  final DateTime createdAt;
  final List<RefinedFullTextSegment> segments;
  final int initializationMs;
  final int decodeMs;
  final double realTimeFactor;
  final int peakRssBytes;
  final String sourceTimelineFingerprint;
  final int composerVersion;
  final List<RefinedFullTextToken> canonicalTokens;
  final List<RefinedTimelineSegment> timelineProjection;

  Map<String, Object?> toMap() => <String, Object?>{
    'schemaVersion': refinedFullTextSchemaVersion,
    'status': 'ready',
    'sessionId': sessionId,
    'modelId': modelId,
    'fullText': fullText,
    'sourceAudioSamples': sourceAudioSamples,
    'sampleRate': sampleRate,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'initializationMs': initializationMs,
    'decodeMs': decodeMs,
    'realTimeFactor': realTimeFactor,
    'peakRssBytes': peakRssBytes,
    'sourceTimelineFingerprint': sourceTimelineFingerprint,
    'composerVersion': composerVersion,
    'canonicalTokens': canonicalTokens.map((token) => token.toMap()).toList(),
    'timelineProjection': timelineProjection
        .map((segment) => segment.toMap())
        .toList(),
    'segments': segments.map((segment) => segment.toMap()).toList(),
  };
}

class FullTextRefinementSnapshot {
  const FullTextRefinementSnapshot({
    required this.status,
    this.document,
    this.message,
  });

  const FullTextRefinementSnapshot.unavailable()
    : status = FullTextRefinementStatus.unavailable,
      document = null,
      message = null;

  const FullTextRefinementSnapshot.processing()
    : status = FullTextRefinementStatus.processing,
      document = null,
      message = null;

  final FullTextRefinementStatus status;
  final RefinedFullTextDocument? document;
  final String? message;
}

int _integer(Object? value, {int fallback = 0}) =>
    value is num ? value.round() : int.tryParse('$value') ?? fallback;

double _decimal(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
