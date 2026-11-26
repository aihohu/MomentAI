import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/speaker/speaker_diarization.dart';
import 'canonical_session_text.dart';
import 'timeline_display_item.dart';

/// A separate v1 extension. canonical-text v1 and its checksum never change.
const speakerTextNotice = '说话人按整段音频估计，不是逐字对齐；多人、重叠或归属不确定的段落不能确定每句话由谁说。';

String speakerTextVersion(SpeakerDiarizationDocument document) {
  List<List<String>> pairs(Map<String, String> values) =>
      (values.keys.toList()..sort()).map((key) => [key, values[key]!]).toList();
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode([
    1,
    document.modelId,
    document.algorithmVersion,
    document.createdAt,
    document.editRevision,
    document.segments.map((s) => [s.speakerId, s.startSample, s.endSample]).toList(),
    pairs(document.labels.names),
    pairs(document.labels.mergedInto),
  ])))}';
}

Map<String, Object?> speakerTextAttribution({
  required SpeakerDiarizationDocument document,
  required int startSample,
  required int endSample,
  List<SpeakerDiarizationSegment>? effectiveSegments,
}) {
  final segments = effectiveSegments ?? document.effectiveSegments;
  final attribution = attributeSpeakerRange(
    segments: segments,
    startSample: startSample,
    endSample: endSample,
  );
  final ids = attribution?.speakerIds ?? const <String>[];
  final clipped =
      segments
          .where((s) => s.startSample < endSample && s.endSample > startSample)
          .toList()
        ..sort((a, b) => a.startSample.compareTo(b.startSample));
  var covered = 0;
  var cursor = startSample;
  for (final segment in clipped) {
    final start = segment.startSample.clamp(cursor, endSample);
    final end = segment.endSample.clamp(start, endSample);
    covered += end - start;
    cursor = end;
  }
  final state = ids.isEmpty
      ? 'unattributed'
      : attribution!.hasOverlappingSpeech
      ? 'overlap'
      : ids.length > 1
      ? 'multiple'
      : covered * 5 >= (endSample - startSample) * 4
      ? 'single'
      : 'uncertain';
  final names = ids.map(document.displayName).toList();
  final label = switch (state) {
    'single' => names.single,
    'multiple' => '多人轮流：${names.join('、')}',
    'overlap' => '多人 · 有重叠：${names.join('、')}',
    'uncertain' => '归属不确定：${names.join('、')}',
    _ => '说话人未确定',
  };
  return {
    'speakerIds': ids,
    'displayNames': names,
    'attribution': state,
    'coveredSamples': covered,
    'label': label,
  };
}

Map<String, Object?> speakerSessionText({
  required CanonicalSessionText canonical,
  required SpeakerDiarizationDocument document,
}) {
  final ordered = document.effectiveSegments
    ..sort((a, b) => a.startSample.compareTo(b.startSample));
  final textRanges = canonical.segments.toList()
    ..sort((a, b) => a.startSample.compareTo(b.startSample));
  final active = <SpeakerDiarizationSegment>[];
  final attributions = <String, Map<String, Object?>>{};
  var next = 0;
  for (final range in textRanges) {
    active.removeWhere((s) => s.endSample <= range.startSample);
    while (next < ordered.length &&
        ordered[next].startSample < range.endSample) {
      final segment = ordered[next++];
      if (segment.endSample > range.startSample) active.add(segment);
    }
    attributions[range.segmentId] = speakerTextAttribution(
      document: document,
      startSample: range.startSample,
      endSample: range.endSample,
      effectiveSegments: active,
    );
  }
  final segments = canonical.segments
      .map(
        (segment) => <String, Object?>{
          'segmentId': segment.segmentId,
          'startSample': segment.startSample,
          'endSample': segment.endSample,
          'text': segment.text,
          'textLayer': segment.textLayer.name,
          ...attributions[segment.segmentId]!,
        },
      )
      .toList();
  return {
    'schemaVersion': 1,
    'format': 'org.hohu.momentai.speaker-text',
    'speakerVersion': speakerTextVersion(document),
    'textVersion':
        'sha256:${sha256.convert(utf8.encode(jsonEncode([
          1,
          switch (canonical.availability) {
            TimelineDisplayAvailability.unavailable || TimelineDisplayAvailability.processing => 'live',
            _ => canonical.availability.name,
          },
          canonical.defaultTextLayer.name,
          canonical.modelId,
          canonical.sourceTimelineFingerprint,
          canonical.fullText,
          canonical.segments.map((s) => [s.segmentId, s.startSample, s.endSample, s.text, s.textLayer.name]).toList(),
        ])))}',
    'sourceTimelineFingerprint': canonical.sourceTimelineFingerprint,
    'notice': speakerTextNotice,
    // Retain the continuous refined text separately: segment alignment may not
    // reproduce punctuation/composition in canonical.fullText exactly.
    'fullText': canonical.fullText,
    'segments': segments,
  };
}
