class TranscriptSegment {
  const TranscriptSegment({
    required this.segmentId,
    required this.sessionId,
    required this.directory,
    required this.startSample,
    required this.endSample,
    required this.text,
    required this.rawText,
    required this.language,
    required this.source,
    required this.modelId,
    required this.isFinal,
  });

  factory TranscriptSegment.fromMap(Map<Object?, Object?> map) {
    return TranscriptSegment(
      segmentId: map['segmentId']?.toString() ?? '',
      sessionId: map['sessionId']?.toString() ?? '',
      directory: map['directory']?.toString() ?? '',
      startSample: _number(map['startSample']),
      endSample: _number(map['endSample']),
      text: map['text']?.toString() ?? '',
      rawText: map['rawText']?.toString() ?? map['text']?.toString() ?? '',
      language: map['language']?.toString() ?? 'zh',
      source: map['source']?.toString() ?? 'sherpa_onnx',
      modelId: map['modelId']?.toString() ?? 'unknown',
      isFinal: map['isFinal'] != false,
    );
  }

  final String segmentId;
  final String sessionId;
  final String directory;
  final int startSample;
  final int endSample;
  final String text;
  final String rawText;
  final String language;
  final String source;
  final String modelId;
  final bool isFinal;

  int get startMs => startSample * 1000 ~/ 16000;
  int get endMs => endSample * 1000 ~/ 16000;

  Map<String, Object?> toMap() => {
    'segmentId': segmentId,
    'sessionId': sessionId,
    'startSample': startSample,
    'endSample': endSample,
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
    'rawText': rawText,
    'language': language,
    'source': source,
    'modelId': modelId,
    'isFinal': isFinal,
  };
}

int _number(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;
