import 'package:momentai/l10n/app_localization.dart';
import '../core/asr/full_text_refinement_service.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/refined_full_text.dart';

enum TimelineTextPreference { refined, live }

enum TimelineTextLayer { refined, live, fallback }

enum TimelineDisplayAvailability {
  unavailable,
  processing,
  ready,
  partial,
  failed,
  stale,
}

class TimelineDisplayItem {
  const TimelineDisplayItem({
    required this.source,
    required this.displayText,
    required this.textLayer,
  });

  final TimelineItem source;
  final String displayText;
  final TimelineTextLayer textLayer;
}

class TimelineDisplayProjection {
  const TimelineDisplayProjection({
    required this.items,
    required this.availability,
    required this.fallbackCount,
    required this.canSelectRefined,
    required this.signature,
  });

  final List<TimelineDisplayItem> items;
  final TimelineDisplayAvailability availability;
  final int fallbackCount;
  final bool canSelectRefined;
  final String signature;

  String? statusMessage({
    required TimelineTextPreference preference,
    bool refinementMayBeFinishing = false,
  }) {
    if (refinementMayBeFinishing &&
        (availability == TimelineDisplayAvailability.unavailable ||
            availability == TimelineDisplayAvailability.processing)) {
      return l10n.refiningTextOnThisDeviceShowingThe;
    }
    if (canSelectRefined && preference == TimelineTextPreference.live) {
      return l10n.originalTranscriptGeneratedDuringRecording;
    }
    return switch (availability) {
      TimelineDisplayAvailability.ready =>
        l10n.sensevoiceLocalRefinementOriginalTimingAndAudio,
      TimelineDisplayAvailability.partial =>
        l10n.sensevoiceLocalRefinementSegmentsUseTheLive(
          (fallbackCount).toString(),
        ),
      TimelineDisplayAvailability.processing =>
        l10n.refiningTextOnThisDeviceShowingThe,
      TimelineDisplayAvailability.failed =>
        l10n.refinementIsNotCompleteShowingTheLive,
      TimelineDisplayAvailability.stale =>
        l10n.theTimelineChangedOrTheRefinementVersion,
      TimelineDisplayAvailability.unavailable => null,
    };
  }
}

TimelineDisplayProjection projectTimelineForDisplay({
  required List<TimelineItem> timeline,
  required FullTextRefinementSnapshot refinement,
  required TimelineTextPreference preference,
}) {
  final document = refinement.document;
  final baseSignature = <Object?>[
    refinement.status.name,
    document?.composerVersion,
    document?.sourceTimelineFingerprint,
    document?.createdAt.toUtc().toIso8601String(),
  ].join('|');

  if (refinement.status != FullTextRefinementStatus.ready || document == null) {
    final availability = switch (refinement.status) {
      FullTextRefinementStatus.processing =>
        TimelineDisplayAvailability.processing,
      FullTextRefinementStatus.failed => TimelineDisplayAvailability.failed,
      FullTextRefinementStatus.ready || FullTextRefinementStatus.unavailable =>
        TimelineDisplayAvailability.unavailable,
    };
    return _liveProjection(
      timeline,
      availability: availability,
      signature: baseSignature,
    );
  }

  final sources = refinementTimelineSources(timeline);
  final fingerprint = sourceTimelineFingerprint(sources);
  if (document.composerVersion != refinedTimelineComposerVersion ||
      document.sourceTimelineFingerprint != fingerprint) {
    return _liveProjection(
      timeline,
      availability: TimelineDisplayAvailability.stale,
      signature: '$baseSignature|$fingerprint|stale',
    );
  }

  final sourceById = <String, RefinementTimelineSource>{
    for (final source in sources) source.segmentId: source,
  };
  final projectionById = <String, RefinedTimelineSegment>{};
  for (final segment in document.timelineProjection) {
    final source = sourceById[segment.segmentId];
    if (source == null ||
        source.startSample != segment.startSample ||
        source.endSample != segment.endSample ||
        projectionById.containsKey(segment.segmentId)) {
      return _liveProjection(
        timeline,
        availability: TimelineDisplayAvailability.stale,
        signature: '$baseSignature|$fingerprint|invalid-projection',
      );
    }
    projectionById[segment.segmentId] = segment;
  }

  var fallbackCount = 0;
  var refinedCount = 0;
  final items = timeline
      .map((item) {
        if (!item.isTranscript) {
          return TimelineDisplayItem(
            source: item,
            displayText: item.text,
            textLayer: TimelineTextLayer.live,
          );
        }
        final segment = projectionById[item.eventId];
        final hasRefinedText =
            segment != null &&
            !segment.fallback &&
            segment.refinedText.trim().isNotEmpty;
        if (!hasRefinedText) fallbackCount += 1;
        if (hasRefinedText) refinedCount += 1;
        if (preference == TimelineTextPreference.refined && hasRefinedText) {
          return TimelineDisplayItem(
            source: item,
            displayText: segment.refinedText,
            textLayer: TimelineTextLayer.refined,
          );
        }
        return TimelineDisplayItem(
          source: item,
          displayText: item.text,
          textLayer: preference == TimelineTextPreference.refined
              ? TimelineTextLayer.fallback
              : TimelineTextLayer.live,
        );
      })
      .toList(growable: false);

  final availability = fallbackCount == 0
      ? TimelineDisplayAvailability.ready
      : TimelineDisplayAvailability.partial;
  return TimelineDisplayProjection(
    items: items,
    availability: availability,
    fallbackCount: fallbackCount,
    canSelectRefined: refinedCount > 0,
    signature:
        '$baseSignature|$fingerprint|${document.timelineProjection.length}|'
        '$fallbackCount',
  );
}

TimelineDisplayProjection _liveProjection(
  List<TimelineItem> timeline, {
  required TimelineDisplayAvailability availability,
  required String signature,
}) => TimelineDisplayProjection(
  items: timeline
      .map(
        (item) => TimelineDisplayItem(
          source: item,
          displayText: item.text,
          textLayer: TimelineTextLayer.live,
        ),
      )
      .toList(growable: false),
  availability: availability,
  fallbackCount: 0,
  canSelectRefined: false,
  signature: signature,
);
