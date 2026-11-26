import 'package:momentai/l10n/app_localization.dart';

enum SpeakerDiarizationStatus { unavailable, processing, ready, failed }

const maximumRequestedSpeakerCount = 12;
const speakerDiarizationAlgorithmVersion = 5;
const maximumSpeakerEditHistory = 20;

enum SpeakerEditKind { rename, merge, undo }

class SpeakerEdit {
  const SpeakerEdit.rename(String speakerId, String name)
    : this._(SpeakerEditKind.rename, speakerId, name);
  const SpeakerEdit.merge(String speakerId, String targetId)
    : this._(SpeakerEditKind.merge, speakerId, targetId);
  const SpeakerEdit.undo() : this._(SpeakerEditKind.undo, '', '');
  const SpeakerEdit._(this.kind, this.speakerId, this.value);

  final SpeakerEditKind kind;
  final String speakerId;
  final String value;
}

/// User labels are separate from the immutable model segments.
class SpeakerLabels {
  const SpeakerLabels({this.names = const {}, this.mergedInto = const {}});

  factory SpeakerLabels.fromMap(Map<Object?, Object?> map) => SpeakerLabels(
    names: _speakerStringMap(map['names']),
    mergedInto: _speakerStringMap(map['mergedInto']),
  );

  final Map<String, String> names;
  final Map<String, String> mergedInto;

  String resolve(String id) => mergedInto[id] ?? id;

  Map<String, Object?> toMap() => {'names': names, 'mergedInto': mergedInto};
}

Map<String, String> _speakerStringMap(Object? value) {
  if (value is! Map ||
      value.entries.any(
        (entry) => entry.key is! String || entry.value is! String,
      )) {
    throw const FormatException('Invalid speaker labels.');
  }
  return Map.unmodifiable(Map<String, String>.from(value));
}

class SpeakerDiarizationSegment {
  const SpeakerDiarizationSegment({
    required this.speakerId,
    required this.startSample,
    required this.endSample,
  });

  factory SpeakerDiarizationSegment.fromMap(Map<Object?, Object?> map) =>
      SpeakerDiarizationSegment(
        speakerId: map['speakerId']?.toString() ?? '',
        startSample: _integer(map['startSample']),
        endSample: _integer(map['endSample']),
      );

  final String speakerId;
  final int startSample;
  final int endSample;

  int get sampleCount => endSample - startSample;

  Map<String, Object?> toMap() => {
    'speakerId': speakerId,
    'startSample': startSample,
    'endSample': endSample,
  };
}

class SpeakerDiarizationDocument {
  const SpeakerDiarizationDocument({
    required this.sessionId,
    required this.modelId,
    required this.sourceAudioSamples,
    required this.sampleRate,
    required this.sourceChunkFingerprint,
    required this.createdAt,
    required this.segments,
    required this.processingMs,
    required this.realTimeFactor,
    required this.peakRssBytes,
    required this.windowCount,
    this.requestedSpeakerCount,
    this.algorithmVersion = speakerDiarizationAlgorithmVersion,
    this.labels = const SpeakerLabels(),
    this.editHistory = const [],
    this.editRevision = 0,
  });

  factory SpeakerDiarizationDocument.fromMap(Map<Object?, Object?> map) {
    final rawSegments = map['segments'];
    if (rawSegments is! List ||
        rawSegments.length > 100000 ||
        rawSegments.any(
          (item) =>
              item is! Map ||
              item['speakerId'] is! String ||
              item['startSample'] is! int ||
              item['endSample'] is! int ||
              (item['startSample'] as int) < 0 ||
              (item['endSample'] as int) <= (item['startSample'] as int) ||
              (item['endSample'] as int) > _integer(map['sourceAudioSamples']),
        )) {
      throw const FormatException('Invalid speaker segments.');
    }
    final requestedSpeakerCount = _integer(map['requestedSpeakerCount']);
    final edits = map['labelEdits'];
    if (edits != null &&
        (edits is! Map ||
            edits['schemaVersion'] != 1 ||
            edits['current'] is! Map ||
            edits['history'] is! List ||
            edits['revision'] is! int ||
            (edits['revision'] as int) < 0 ||
            (edits['history'] as List).length > maximumSpeakerEditHistory)) {
      throw const FormatException('Unsupported speaker edits.');
    }
    final editMap = edits as Map?;
    return SpeakerDiarizationDocument(
      labels: editMap == null
          ? const SpeakerLabels()
          : SpeakerLabels.fromMap(
              Map<Object?, Object?>.from(editMap['current'] as Map),
            ),
      editHistory: editMap == null
          ? const []
          : List.unmodifiable(
              (editMap['history'] as List).map((item) {
                if (item is! Map) {
                  throw const FormatException('Invalid speaker history.');
                }
                return SpeakerLabels.fromMap(Map<Object?, Object?>.from(item));
              }),
            ),
      editRevision: editMap == null ? 0 : editMap['revision'] as int,
      algorithmVersion: _integer(map['algorithmVersion'], fallback: 1),
      sessionId: map['sessionId']?.toString() ?? '',
      modelId: map['modelId']?.toString() ?? '',
      sourceAudioSamples: _integer(map['sourceAudioSamples']),
      sampleRate: _integer(map['sampleRate'], fallback: 16000),
      sourceChunkFingerprint: map['sourceChunkFingerprint']?.toString() ?? '',
      createdAt: map['createdAt']?.toString() ?? '',
      processingMs: _integer(map['processingMs']),
      realTimeFactor: _decimal(map['realTimeFactor']),
      peakRssBytes: _integer(map['peakRssBytes']),
      windowCount: _integer(map['windowCount']),
      requestedSpeakerCount: requestedSpeakerCount > 0
          ? requestedSpeakerCount
          : null,
      segments: (map['segments'] as List<Object?>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => SpeakerDiarizationSegment.fromMap(
              Map<Object?, Object?>.from(item),
            ),
          )
          .where(
            (segment) =>
                segment.speakerId.isNotEmpty && segment.sampleCount > 0,
          )
          .toList(growable: false),
    );
  }

  final String sessionId;
  final String modelId;
  final int sourceAudioSamples;
  final int sampleRate;
  final String sourceChunkFingerprint;
  final String createdAt;
  final List<SpeakerDiarizationSegment> segments;
  final int processingMs;
  final double realTimeFactor;
  final int peakRssBytes;
  final int windowCount;
  final int? requestedSpeakerCount;
  final int algorithmVersion;
  final SpeakerLabels labels;
  final List<SpeakerLabels> editHistory;
  final int editRevision;

  List<String> get speakerIds => segments
      .map((item) => labels.resolve(item.speakerId))
      .toSet()
      .toList(growable: false);
  int get speakerCount => speakerIds.length;
  int get detectedSpeakerCount =>
      segments.map((item) => item.speakerId).toSet().length;
  bool get hasUserEdits =>
      labels.names.isNotEmpty || labels.mergedInto.isNotEmpty;
  bool get canUndoEdit => editHistory.isNotEmpty;

  String displayName(String id) =>
      labels.names[labels.resolve(id)] ??
      speakerDisplayName(labels.resolve(id));

  List<SpeakerDiarizationSegment> get effectiveSegments => segments
      .map(
        (segment) => SpeakerDiarizationSegment(
          speakerId: labels.resolve(segment.speakerId),
          startSample: segment.startSample,
          endSample: segment.endSample,
        ),
      )
      .toList(growable: false);

  bool canMergeSpeakers(String sourceId, String targetId) {
    if (sourceId == targetId ||
        !speakerIds.contains(sourceId) ||
        !speakerIds.contains(targetId)) {
      return false;
    }
    final source = <SpeakerDiarizationSegment>[];
    final target = <SpeakerDiarizationSegment>[];
    for (final segment in effectiveSegments) {
      if (segment.speakerId == sourceId) source.add(segment);
      if (segment.speakerId == targetId) target.add(segment);
    }
    source.sort((a, b) => a.startSample.compareTo(b.startSample));
    target.sort((a, b) => a.startSample.compareTo(b.startSample));
    var left = 0;
    var right = 0;
    while (left < source.length && right < target.length) {
      final a = source[left];
      final b = target[right];
      if (a.startSample < b.endSample && b.startSample < a.endSample) {
        return false;
      }
      if (a.endSample <= b.endSample) {
        left++;
      } else {
        right++;
      }
    }
    return true;
  }

  SpeakerDiarizationDocument applyEdit(SpeakerEdit edit) {
    validateSpeakerLabels();
    final history = editHistory.toList();
    late final SpeakerLabels updated;
    if (edit.kind == SpeakerEditKind.undo) {
      if (history.isEmpty) throw StateError(l10n.noChangesToUndo);
      updated = history.removeLast();
    } else {
      if (!speakerIds.contains(edit.speakerId)) {
        throw StateError(l10n.speakersHaveChangedReopenBeforeEditing);
      }
      final names = Map<String, String>.from(labels.names);
      final merged = Map<String, String>.from(labels.mergedInto);
      switch (edit.kind) {
        case SpeakerEditKind.rename:
          final name = edit.value.trim();
          _validateSpeakerName(name);
          if (name.isNotEmpty &&
              speakerIds.any(
                (id) => id != edit.speakerId && displayName(id) == name,
              )) {
            throw ArgumentError(l10n.aSpeakerWithThisNameAlreadyExists);
          }
          if ((names[edit.speakerId] ?? '') == name) return this;
          if (name.isEmpty) {
            names.remove(edit.speakerId);
          } else {
            names[edit.speakerId] = name;
          }
        case SpeakerEditKind.merge:
          if (!canMergeSpeakers(edit.speakerId, edit.value)) {
            throw StateError(l10n.theseSpeakersCannotBeMergedListenAgain);
          }
          for (final id
              in segments.map((segment) => segment.speakerId).toSet()) {
            if (labels.resolve(id) == edit.speakerId) merged[id] = edit.value;
          }
          names.remove(edit.speakerId);
        case SpeakerEditKind.undo:
          throw StateError('Unexpected undo.');
      }
      updated = SpeakerLabels(
        names: Map.unmodifiable(names),
        mergedInto: Map.unmodifiable(merged),
      );
      history.add(labels);
      if (history.length > maximumSpeakerEditHistory) history.removeAt(0);
    }
    return SpeakerDiarizationDocument(
      sessionId: sessionId,
      modelId: modelId,
      sourceAudioSamples: sourceAudioSamples,
      sampleRate: sampleRate,
      sourceChunkFingerprint: sourceChunkFingerprint,
      createdAt: createdAt,
      segments: segments,
      processingMs: processingMs,
      realTimeFactor: realTimeFactor,
      peakRssBytes: peakRssBytes,
      windowCount: windowCount,
      requestedSpeakerCount: requestedSpeakerCount,
      algorithmVersion: algorithmVersion,
      labels: updated,
      editHistory: List.unmodifiable(history),
      editRevision: editRevision + 1,
    );
  }

  void validateSpeakerLabels() {
    final rawIds = segments.map((segment) => segment.speakerId).toSet();
    if (editRevision < editHistory.length ||
        editHistory.length > maximumSpeakerEditHistory) {
      throw const FormatException('Invalid speaker edit history.');
    }
    for (final state in [labels, ...editHistory]) {
      for (final entry in state.mergedInto.entries) {
        if (!rawIds.contains(entry.key) ||
            !rawIds.contains(entry.value) ||
            entry.key == entry.value ||
            state.mergedInto.containsKey(entry.value)) {
          throw const FormatException('Invalid speaker merge.');
        }
      }
      final active = rawIds.map(state.resolve).toSet();
      for (final entry in state.names.entries) {
        if (!active.contains(entry.key) ||
            entry.value.isEmpty ||
            entry.value.trim() != entry.value) {
          throw const FormatException('Invalid speaker name.');
        }
        _validateSpeakerName(entry.value);
      }
      final displayNames = active.map(
        (id) => state.names[id] ?? speakerDisplayName(id),
      );
      if (displayNames.toSet().length != active.length) {
        throw const FormatException('Duplicate speaker names.');
      }
      final ordered = segments.toList()
        ..sort((a, b) => a.startSample.compareTo(b.startSample));
      final activeEnds = <String, Map<String, int>>{};
      for (final segment in ordered) {
        final group = activeEnds.putIfAbsent(
          state.resolve(segment.speakerId),
          () => {},
        );
        if (group.entries.any(
          (entry) =>
              entry.key != segment.speakerId &&
              entry.value > segment.startSample,
        )) {
          throw const FormatException('Cannot merge overlapping speakers.');
        }
        final previous = group[segment.speakerId] ?? 0;
        if (segment.endSample > previous) {
          group[segment.speakerId] = segment.endSample;
        }
      }
    }
  }

  Map<String, Object?> toMap() => {
    'schemaVersion': 1,
    'algorithmVersion': algorithmVersion,
    'status': 'ready',
    'sessionId': sessionId,
    'modelId': modelId,
    'sourceAudioSamples': sourceAudioSamples,
    'sampleRate': sampleRate,
    'sourceChunkFingerprint': sourceChunkFingerprint,
    'createdAt': createdAt,
    'processingMs': processingMs,
    'realTimeFactor': realTimeFactor,
    'peakRssBytes': peakRssBytes,
    'windowCount': windowCount,
    'requestedSpeakerCount': requestedSpeakerCount,
    'speakerCount': speakerCount,
    'segments': segments.map((item) => item.toMap()).toList(),
    if (editRevision > 0 || hasUserEdits || editHistory.isNotEmpty)
      'labelEdits': {
        'schemaVersion': 1,
        'revision': editRevision,
        'current': labels.toMap(),
        'history': editHistory.map((state) => state.toMap()).toList(),
      },
  };
}

void _validateSpeakerName(String name) {
  if (name.runes.length > 40 ||
      RegExp(r'[\x00-\x1f\x7f\u2028\u2029]').hasMatch(name)) {
    throw ArgumentError(l10n.namesMayContainUpToCharactersWith);
  }
}

class SpeakerDiarizationSnapshot {
  const SpeakerDiarizationSnapshot({
    required this.status,
    this.document,
    this.message,
    this.requestedSpeakerCount,
  });

  const SpeakerDiarizationSnapshot.unavailable({this.message})
    : status = SpeakerDiarizationStatus.unavailable,
      document = null,
      requestedSpeakerCount = null;

  const SpeakerDiarizationSnapshot.processing({
    this.requestedSpeakerCount,
    this.document,
    this.message,
  }) : status = SpeakerDiarizationStatus.processing;

  final SpeakerDiarizationStatus status;
  final SpeakerDiarizationDocument? document;
  final String? message;
  final int? requestedSpeakerCount;
}

class SpeakerAttribution {
  const SpeakerAttribution({
    required this.speakerIds,
    required this.dominantSpeakerId,
    this.hasOverlappingSpeech = false,
  });

  final List<String> speakerIds;
  final String? dominantSpeakerId;
  final bool hasOverlappingSpeech;

  bool get hasMultipleSpeakers => speakerIds.length > 1;
}

SpeakerAttribution? attributeSpeakerRange({
  required Iterable<SpeakerDiarizationSegment> segments,
  required int startSample,
  required int endSample,
}) {
  if (endSample <= startSample) return null;
  final overlapBySpeaker = <String, int>{};
  final clipped = <SpeakerDiarizationSegment>[];
  for (final segment in segments) {
    final start = segment.startSample > startSample
        ? segment.startSample
        : startSample;
    final end = segment.endSample < endSample ? segment.endSample : endSample;
    if (end <= start) continue;
    clipped.add(
      SpeakerDiarizationSegment(
        speakerId: segment.speakerId,
        startSample: start,
        endSample: end,
      ),
    );
    overlapBySpeaker.update(
      segment.speakerId,
      (value) => value + end - start,
      ifAbsent: () => end - start,
    );
  }
  if (overlapBySpeaker.isEmpty) return null;
  clipped.sort((a, b) => a.startSample.compareTo(b.startSample));
  final activeEnds = <String, int>{};
  var hasOverlappingSpeech = false;
  for (final segment in clipped) {
    if (activeEnds.entries.any(
      (entry) =>
          entry.key != segment.speakerId && entry.value > segment.startSample,
    )) {
      hasOverlappingSpeech = true;
      break;
    }
    final previous = activeEnds[segment.speakerId] ?? 0;
    if (segment.endSample > previous) {
      activeEnds[segment.speakerId] = segment.endSample;
    }
  }
  final ordered = overlapBySpeaker.entries.toList(growable: false)
    ..sort((left, right) {
      final byDuration = right.value.compareTo(left.value);
      return byDuration != 0 ? byDuration : left.key.compareTo(right.key);
    });
  return SpeakerAttribution(
    speakerIds: ordered.map((item) => item.key).toList(growable: false),
    dominantSpeakerId: ordered.first.key,
    hasOverlappingSpeech: hasOverlappingSpeech,
  );
}

String speakerDisplayName(String speakerId) {
  final match = RegExp(r'^speaker_(\d+)$').firstMatch(speakerId);
  final number = match == null ? null : int.tryParse(match.group(1)!);
  return number == null ? '说话人' : '说话人 $number';
}

int _integer(Object? value, {int fallback = 0}) =>
    value is num ? value.round() : int.tryParse('$value') ?? fallback;

double _decimal(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
