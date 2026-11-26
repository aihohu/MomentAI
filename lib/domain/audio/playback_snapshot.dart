class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.state,
    required this.sessionId,
    required this.directory,
    required this.sampleRate,
    required this.positionSample,
    required this.durationSamples,
    required this.positionMs,
    required this.durationMs,
    required this.anchorId,
    required this.anchorType,
    required this.peakBufferedBytes,
    this.outputPortType = '',
    this.outputPortName = '',
    this.outputVolume = 0,
    this.signalGainDb = 0,
    this.limiterThreshold = 0,
    this.error,
  });

  factory PlaybackSnapshot.idle() => const PlaybackSnapshot(
    state: 'idle',
    sessionId: '',
    directory: '',
    sampleRate: 16000,
    positionSample: 0,
    durationSamples: 0,
    positionMs: 0,
    durationMs: 0,
    anchorId: '',
    anchorType: '',
    peakBufferedBytes: 0,
  );

  factory PlaybackSnapshot.fromMap(Map<Object?, Object?> map) =>
      PlaybackSnapshot(
        state: map['state']?.toString() ?? 'idle',
        sessionId: map['sessionId']?.toString() ?? '',
        directory: map['directory']?.toString() ?? '',
        sampleRate: _number(map['sampleRate'], fallback: 16000),
        positionSample: _number(map['positionSample']),
        durationSamples: _number(map['durationSamples']),
        positionMs: _number(map['positionMs']),
        durationMs: _number(map['durationMs']),
        anchorId: map['anchorId']?.toString() ?? '',
        anchorType: map['anchorType']?.toString() ?? '',
        peakBufferedBytes: _number(map['peakBufferedBytes']),
        outputPortType: map['outputPortType']?.toString() ?? '',
        outputPortName: map['outputPortName']?.toString() ?? '',
        outputVolume: _decimal(map['outputVolume']),
        signalGainDb: _decimal(map['signalGainDb']),
        limiterThreshold: _decimal(map['limiterThreshold']),
        error: map['error']?.toString(),
      );

  final String state;
  final String sessionId;
  final String directory;
  final int sampleRate;
  final int positionSample;
  final int durationSamples;
  final int positionMs;
  final int durationMs;
  final String anchorId;
  final String anchorType;
  final int peakBufferedBytes;
  final String outputPortType;
  final String outputPortName;
  final double outputVolume;
  final double signalGainDb;
  final double limiterThreshold;
  final String? error;

  bool get isIdle => state == 'idle';
  bool get isPlaying => state == 'playing';
  bool get isPaused => state == 'paused';
  bool get isCompleted => state == 'completed';
  bool get isPrepared => !isIdle && durationSamples > 0;
}

int _number(Object? value, {int fallback = 0}) =>
    value is num ? value.round() : int.tryParse('$value') ?? fallback;

double _decimal(Object? value, {double fallback = 0}) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;

/// Application playback preferences, independent of system media volume.
class PlaybackSoundSettings {
  const PlaybackSoundSettings({this.volume = 1, this.enhanced = true});

  factory PlaybackSoundSettings.fromMap(Map<Object?, Object?> map) {
    final value = _decimal(map['volume'], fallback: 1);
    return PlaybackSoundSettings(
      volume: value.isFinite ? value.clamp(0.0, 1.0) : 1,
      enhanced: map['enhanced'] != false,
    );
  }

  final double volume;
  final bool enhanced;
}
