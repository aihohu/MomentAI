import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/speaker/speaker_diarization.dart';

/// Evaluate distinct identities, not multiple profiles already proven to be the
/// same speaker. Missing embeddings or competing identities require a full pass.
bool speakerFastPassNeedsFallback({
  required Iterable<int> localIds,
  required Map<int, Float32List> embeddings,
  required List<Float32List> profiles,
  required List<int> profileGroups,
  required Map<int, double> speechSeconds,
}) {
  for (final id in localIds) {
    final embedding = embeddings[id];
    if (embedding == null || !speakerCosine(embedding, embedding).isFinite) {
      return true;
    }
    final byIdentity = <int, double>{};
    for (var i = 0; i < profiles.length; i++) {
      final score = speakerCosine(embedding, profiles[i]);
      if (score.isFinite) {
        byIdentity[profileGroups[i]] = math.max(
          byIdentity[profileGroups[i]] ?? double.negativeInfinity,
          score,
        );
      }
    }
    final scores = byIdentity.values.toList()..sort((a, b) => b.compareTo(a));
    if (scores.isNotEmpty &&
        scores.first >= .55 &&
        ((scores.first < .6 && (speechSeconds[id] ?? 0) > 5) ||
            (scores.length > 1 && scores.first - scores[1] < .15))) {
      return true;
    }
  }
  return false;
}

/// Match as many local speakers as possible, then maximize their total score.
/// Dummy columns let weak or missing embeddings remain unmatched.
Map<int, int> matchSpeakerEmbeddings(
  Map<int, Float32List> local,
  List<Float32List> profiles, {
  double threshold = 0.55,
}) {
  if (local.isEmpty || profiles.isEmpty) return {};
  final ids = local.keys.toList()..sort();
  final rows = ids.length;
  final columns = profiles.length + rows;
  final scores = [
    for (final id in ids)
      [for (final profile in profiles) speakerCosine(local[id]!, profile)],
  ];
  // Rectangular Hungarian assignment. A match bonus larger than the possible
  // total score difference makes cardinality take precedence over similarity.
  final bonus = 2.0 * rows + 1;
  double cost(int row, int column) {
    if (column >= profiles.length) return 0;
    final score = scores[row][column];
    return score >= threshold ? -bonus - score : bonus;
  }

  final u = List<double>.filled(rows + 1, 0);
  final v = List<double>.filled(columns + 1, 0);
  final p = List<int>.filled(columns + 1, 0);
  final way = List<int>.filled(columns + 1, 0);
  for (var row = 1; row <= rows; row++) {
    p[0] = row;
    var column = 0;
    final minimum = List<double>.filled(columns + 1, double.infinity);
    final used = List<bool>.filled(columns + 1, false);
    do {
      used[column] = true;
      final currentRow = p[column];
      var delta = double.infinity;
      var next = 0;
      for (var candidate = 1; candidate <= columns; candidate++) {
        if (used[candidate]) continue;
        final value =
            cost(currentRow - 1, candidate - 1) - u[currentRow] - v[candidate];
        if (value < minimum[candidate]) {
          minimum[candidate] = value;
          way[candidate] = column;
        }
        if (minimum[candidate] < delta) {
          delta = minimum[candidate];
          next = candidate;
        }
      }
      for (var candidate = 0; candidate <= columns; candidate++) {
        if (used[candidate]) {
          u[p[candidate]] += delta;
          v[candidate] -= delta;
        } else {
          minimum[candidate] -= delta;
        }
      }
      column = next;
    } while (p[column] != 0);
    do {
      final previous = way[column];
      p[column] = p[previous];
      column = previous;
    } while (column != 0);
  }
  return {
    for (var column = 1; column <= profiles.length; column++)
      if (p[column] != 0 && scores[p[column] - 1][column - 1] >= threshold)
        ids[p[column] - 1]: column - 1,
  };
}

/// Apply a known count once, using embeddings from the whole Session.
/// Complete linkage avoids merging two groups through one weak bridge.
/// Missing embeddings stay separate: a count cannot establish their identity.
List<int> clusterSessionSpeakers(
  List<Float32List> embeddings, {
  required int requestedSpeakerCount,
}) {
  if (requestedSpeakerCount < 1) {
    throw ArgumentError.value(requestedSpeakerCount);
  }
  if (embeddings.length <= requestedSpeakerCount) {
    return List<int>.generate(embeddings.length, (index) => index);
  }
  return _clusterSpeakerSimilarities(
    _speakerSimilarities(embeddings),
    // Unusable profiles cannot participate in clustering. Counting them toward
    // the target would collapse valid speakers to compensate for noise/short
    // turns that can never merge (even collapsing every valid voice into one).
    targetCount:
        requestedSpeakerCount +
        embeddings.where((e) => !speakerCosine(e, e).isFinite).length,
  );
}

/// Consolidate strongly similar automatic labels, including labels produced
/// within one native window. Never merge labels that occur simultaneously.
/// Complete linkage requires every original pair in a group to meet the
/// stronger threshold; cross-window matching uses a separate, weaker threshold.
List<int> consolidateAutomaticSpeakers(
  List<Float32List> embeddings, {
  required Iterable<SpeakerDiarizationTurn> turns,
  double minimumSimilarity = 0.8,
}) {
  if (!minimumSimilarity.isFinite ||
      minimumSimilarity < -1 ||
      minimumSimilarity > 1) {
    throw ArgumentError.value(minimumSimilarity);
  }
  final similarity = _speakerSimilarities(embeddings);
  final ordered = turns.toList()
    ..sort((left, right) => left.startSample.compareTo(right.startSample));
  for (var index = 0; index < ordered.length; index++) {
    final left = ordered[index];
    for (var other = index + 1; other < ordered.length; other++) {
      final right = ordered[other];
      if (right.startSample >= left.endSample) break;
      if (left.speakerIndex == right.speakerIndex ||
          right.endSample <= left.startSample) {
        continue;
      }
      similarity[left.speakerIndex][right.speakerIndex] =
          similarity[right.speakerIndex][left.speakerIndex] =
              double.negativeInfinity;
    }
  }
  final groups = _clusterSpeakerSimilarities(
    similarity,
    targetCount: 1,
    minimumSimilarity: minimumSimilarity,
  );
  return reconcileBriefSpeakerLabels(
    embeddings,
    turns: ordered,
    groups: groups,
  );
}

/// A brief, mixed-voice turn can form a spurious native cluster. Reattach only
/// to an established voice with a clear embedding margin. Duration alone never
/// removes a person; concurrent labels and ambiguous/unusable voices stay apart.
List<int> reconcileBriefSpeakerLabels(
  List<Float32List> embeddings, {
  required List<SpeakerDiarizationTurn> turns,
  required List<int> groups,
}) {
  final members = <int, List<int>>{};
  for (var i = 0; i < groups.length; i++) {
    (members[groups[i]] ??= []).add(i);
  }
  final samples = <int, int>{}, counts = <int, int>{};
  var total = 0;
  for (final turn in turns) {
    final group = groups[turn.speakerIndex];
    final length = turn.endSample - turn.startSample;
    samples[group] = (samples[group] ?? 0) + length;
    counts[group] = (counts[group] ?? 0) + 1;
    total += length;
  }
  final stable = members.keys
      .where((id) => (samples[id] ?? 0) >= 30 * 16000)
      .toList();
  final assignments = <int, int>{};
  final similarity = _speakerSimilarities(embeddings);
  final conflicts = <(int, int)>{};
  final ordered = [...turns]
    ..sort((a, b) => a.startSample.compareTo(b.startSample));
  for (var i = 0; i < ordered.length; i++) {
    for (
      var j = i + 1;
      j < ordered.length && ordered[j].startSample < ordered[i].endSample;
      j++
    ) {
      final a = groups[ordered[i].speakerIndex],
          b = groups[ordered[j].speakerIndex];
      if (a != b) {
        conflicts.add((a, b));
        conflicts.add((b, a));
      }
    }
  }
  for (final id in members.keys) {
    final length = samples[id] ?? 0;
    if (length <= 0 ||
        length > 5 * 16000 ||
        length > total * .03 ||
        (counts[id] ?? 0) > 2) {
      continue;
    }
    final candidates = <(int, double)>[];
    for (final target in stable) {
      if (target == id || conflicts.contains((id, target))) continue;
      var score = double.infinity;
      for (final a in members[id]!) {
        for (final b in members[target]!) {
          score = math.min(score, similarity[a][b]);
        }
      }
      if (score.isFinite) candidates.add((target, score));
    }
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    if (candidates.isEmpty ||
        candidates.first.$2 < .6 ||
        (candidates.length > 1 &&
            candidates.first.$2 - candidates[1].$2 < .2)) {
      continue;
    }
    final target = candidates.first.$1;
    // Two brief clusters must not collapse their own detected overlap through
    // a shared stable anchor, or create an unsupported transitive merge.
    final prior = assignments.entries
        .where((entry) => entry.value == target)
        .map((entry) => entry.key);
    if (prior.any(
      (other) =>
          conflicts.contains((id, other)) ||
          members[id]!.any(
            (a) => members[other]!.any((b) => similarity[a][b] < .6),
          ),
    )) {
      continue;
    }
    assignments[id] = target;
  }
  return [for (final group in groups) assignments[group] ?? group];
}

List<Float64List> _speakerSimilarities(List<Float32List> embeddings) {
  final count = embeddings.length;
  final similarity = List.generate(count, (_) => Float64List(count));
  for (var left = 0; left < count; left++) {
    for (var right = left + 1; right < count; right++) {
      similarity[left][right] = similarity[right][left] = speakerCosine(
        embeddings[left],
        embeddings[right],
      );
    }
  }
  return similarity;
}

List<int> _clusterSpeakerSimilarities(
  List<Float64List> similarity, {
  required int targetCount,
  double minimumSimilarity = double.negativeInfinity,
}) {
  final count = similarity.length;
  final parent = List<int>.generate(count, (index) => index);
  final active = List<bool>.filled(count, true);
  var remaining = count;
  while (remaining > targetCount) {
    var best = double.negativeInfinity;
    var first = -1;
    var second = -1;
    for (var left = 0; left < count; left++) {
      if (!active[left]) continue;
      for (var right = left + 1; right < count; right++) {
        if (!active[right]) continue;
        if (similarity[left][right] > best) {
          best = similarity[left][right];
          first = left;
          second = right;
        }
      }
    }
    if (first < 0 || best < minimumSimilarity) break;
    active[second] = false;
    parent[second] = first;
    remaining--;
    for (var other = 0; other < count; other++) {
      if (!active[other] || other == first) continue;
      similarity[first][other] = similarity[other][first] = math.min(
        similarity[first][other],
        similarity[second][other],
      );
    }
  }
  return [for (var index = 0; index < count; index++) _root(parent, index)];
}

int _root(List<int> parent, int index) {
  while (parent[index] != index) {
    index = parent[index];
  }
  return index;
}

double speakerCosine(Float32List left, Float32List right) {
  if (left.isEmpty || left.length != right.length) {
    return double.negativeInfinity;
  }
  var product = 0.0;
  var leftNorm = 0.0;
  var rightNorm = 0.0;
  for (var index = 0; index < left.length; index++) {
    product += left[index] * right[index];
    leftNorm += left[index] * left[index];
    rightNorm += right[index] * right[index];
  }
  if (!product.isFinite || leftNorm <= 0 || rightNorm <= 0) {
    return double.negativeInfinity;
  }
  final score = product / math.sqrt(leftNorm * rightNorm);
  return score.isFinite ? score.clamp(-1, 1) : double.negativeInfinity;
}

class SpeakerDiarizationTurn {
  const SpeakerDiarizationTurn({
    required this.speakerIndex,
    required this.startSample,
    required this.endSample,
    required this.islandIndex,
  });

  final int speakerIndex;
  final int startSample;
  final int endSample;
  final int islandIndex;
}

List<SpeakerDiarizationSegment> canonicalizeSpeakerTurns(
  Iterable<SpeakerDiarizationTurn> input,
) {
  final ordered = input.toList()
    ..sort((left, right) {
      final byStart = left.startSample.compareTo(right.startSample);
      return byStart != 0
          ? byStart
          : left.speakerIndex.compareTo(right.speakerIndex);
    });
  final ids = <int, String>{};
  final merged = <SpeakerDiarizationSegment>[];
  int? previousIsland;
  for (final turn in ordered) {
    final id = ids.putIfAbsent(
      turn.speakerIndex,
      () => 'speaker_${ids.length + 1}',
    );
    if (merged.isNotEmpty && previousIsland == turn.islandIndex) {
      final previous = merged.last;
      if (previous.speakerId == id &&
          turn.startSample <= previous.endSample + 8000) {
        merged[merged.length - 1] = SpeakerDiarizationSegment(
          speakerId: id,
          startSample: previous.startSample,
          endSample: math.max(previous.endSample, turn.endSample),
        );
        continue;
      }
    }
    merged.add(
      SpeakerDiarizationSegment(
        speakerId: id,
        startSample: turn.startSample,
        endSample: turn.endSample,
      ),
    );
    previousIsland = turn.islandIndex;
  }
  return merged;
}
