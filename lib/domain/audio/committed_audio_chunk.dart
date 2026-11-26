class CommittedAudioChunk {
  const CommittedAudioChunk({
    required this.sessionId,
    required this.directory,
    required this.index,
    required this.path,
    required this.startSample,
    required this.endSample,
    required this.sampleRate,
    int? fileStartSample,
  }) : fileStartSample = fileStartSample ?? startSample;

  factory CommittedAudioChunk.fromMap(Map<Object?, Object?> map) {
    final startSample = _number(map['startSample']);
    return CommittedAudioChunk(
      sessionId: map['sessionId']?.toString() ?? '',
      directory: map['directory']?.toString() ?? '',
      index: _number(map['index']),
      path: map['path']?.toString() ?? '',
      startSample: startSample,
      endSample: _number(map['endSample']),
      sampleRate: _number(map['sampleRate'], fallback: 16000),
      fileStartSample: _number(map['fileStartSample'], fallback: startSample),
    );
  }

  final String sessionId;
  final String directory;
  final int index;
  final String path;
  final int startSample;
  final int endSample;
  final int sampleRate;
  final int fileStartSample;

  int get sampleCount => endSample - startSample;

  CommittedAudioChunk sliceFrom(int sample) {
    if (sample <= startSample) return this;
    if (sample >= endSample) {
      throw RangeError.range(sample, startSample, endSample - 1, 'sample');
    }
    return CommittedAudioChunk(
      sessionId: sessionId,
      directory: directory,
      index: index,
      path: path,
      startSample: sample,
      endSample: endSample,
      sampleRate: sampleRate,
      fileStartSample: fileStartSample,
    );
  }

  Map<String, Object?> toMessage() => {
    'sessionId': sessionId,
    'directory': directory,
    'index': index,
    'path': path,
    'startSample': startSample,
    'fileStartSample': fileStartSample,
    'endSample': endSample,
    'sampleRate': sampleRate,
  };
}

int _number(Object? value, {int fallback = 0}) =>
    value is num ? value.round() : int.tryParse('$value') ?? fallback;
