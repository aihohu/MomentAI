import '../core/asr/full_text_refinement_service.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/refined_full_text.dart';
import 'timeline_display_item.dart';

const canonicalSessionTextSchemaVersion = 1;

class CanonicalSessionTextSegment {
  const CanonicalSessionTextSegment({
    required this.segmentId,
    required this.startSample,
    required this.endSample,
    required this.liveText,
    required this.text,
    required this.textLayer,
    this.refinedText,
  });

  final String segmentId;
  final int startSample;
  final int endSample;
  final String liveText;
  final String? refinedText;
  final String text;
  final TimelineTextLayer textLayer;

  Map<String, Object?> toMap() => <String, Object?>{
    'segmentId': segmentId,
    'startSample': startSample,
    'endSample': endSample,
    'liveText': liveText,
    'refinedText': refinedText,
    'text': text,
    'textLayer': textLayer.name,
  };
}

class CanonicalSessionText {
  const CanonicalSessionText({
    required this.availability,
    required this.defaultTextLayer,
    required this.fullText,
    required this.modelId,
    required this.sourceTimelineFingerprint,
    required this.segments,
  });

  final TimelineDisplayAvailability availability;
  final TimelineTextLayer defaultTextLayer;
  final String fullText;
  final String modelId;
  final String sourceTimelineFingerprint;
  final List<CanonicalSessionTextSegment> segments;

  Map<String, Object?> toMap() => <String, Object?>{
    'schemaVersion': canonicalSessionTextSchemaVersion,
    'format': 'org.hohu.momentai.canonical-text',
    'status': availability.name,
    'defaultTextLayer': defaultTextLayer.name,
    'fullText': fullText,
    'modelId': modelId,
    'sourceTimelineFingerprint': sourceTimelineFingerprint,
    'segmentCount': segments.length,
    'segments': segments.map((segment) => segment.toMap()).toList(),
  };
}

CanonicalSessionText canonicalSessionText({
  required List<TimelineItem> timeline,
  required FullTextRefinementSnapshot refinement,
}) {
  final projection = projectTimelineForDisplay(
    timeline: timeline,
    refinement: refinement,
    preference: TimelineTextPreference.refined,
  );
  final sourceSegments = refinementTimelineSources(timeline);
  final sourceFingerprint = sourceTimelineFingerprint(sourceSegments);
  final validRefinement =
      projection.availability == TimelineDisplayAvailability.ready ||
      projection.availability == TimelineDisplayAvailability.partial;
  final refinedById = <String, RefinedTimelineSegment>{
    if (validRefinement)
      for (final segment
          in refinement.document?.timelineProjection ??
              const <RefinedTimelineSegment>[])
        segment.segmentId: segment,
  };
  final segments = projection.items
      .where((item) => item.source.isTranscript)
      .map((item) {
        final refined = refinedById[item.source.eventId];
        return CanonicalSessionTextSegment(
          segmentId: item.source.eventId,
          startSample: item.source.sampleOffset,
          endSample: item.source.endSample,
          liveText: item.source.text,
          refinedText: item.textLayer == TimelineTextLayer.refined
              ? refined?.refinedText
              : null,
          text: item.displayText,
          textLayer: item.textLayer,
        );
      })
      .toList(growable: false);
  final persistedFullText = validRefinement
      ? refinement.document?.fullText.trim() ?? ''
      : '';
  return CanonicalSessionText(
    availability: projection.availability,
    defaultTextLayer: validRefinement
        ? TimelineTextLayer.refined
        : TimelineTextLayer.live,
    fullText: persistedFullText.isNotEmpty
        ? persistedFullText
        : segments.map((segment) => segment.text).join('\n\n'),
    modelId: validRefinement ? refinement.document?.modelId ?? '' : '',
    sourceTimelineFingerprint: sourceFingerprint,
    segments: segments,
  );
}
