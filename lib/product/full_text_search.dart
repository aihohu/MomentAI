import 'package:momentai/l10n/app_localization.dart';

import '../domain/speaker/speaker_diarization.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/refined_full_text.dart';
import 'local_search.dart';
import 'reading_text.dart';
import 'speaker_localization.dart';
import 'timeline_display_item.dart';

class FullTextSearchHit extends RecordSearchHit {
  const FullTextSearchHit({
    required this.text,
    required this.range,
    required this.sourceLabel,
    this.playbackItem,
  });

  @override
  final String text;
  @override
  final SearchTextRange range;
  @override
  final TimelineItem? playbackItem;
  @override
  final String sourceLabel;
  @override
  String get identity => 'fullText:${range.start}';
}

/// The exact read-only text shown by RefinedTranscriptFullText. Playback
/// mappings are optional: matching text alone is not a trustworthy timestamp.
class FullTextSearchDocument {
  const FullTextSearchDocument({
    required this.text,
    required this.sourceLabel,
    required this.anchors,
    this.paragraphs = const [],
  });

  final String text;
  final String sourceLabel;
  final List<FullTextAnchor> anchors;
  final List<SpeakerFullTextParagraph> paragraphs;

  List<FullTextSearchHit> search(String query) {
    var anchorIndex = 0;
    return searchTextRanges(text, query)
        .map((range) {
          TimelineItem? item;
          while (anchorIndex < anchors.length &&
              anchors[anchorIndex].end <= range.start) {
            anchorIndex += 1;
          }
          if (anchorIndex < anchors.length) {
            final anchor = anchors[anchorIndex];
            if (anchor.start <= range.start && range.start < anchor.end) {
              item = anchor.item;
            }
          }
          return FullTextSearchHit(
            text: text,
            range: range,
            sourceLabel: item?.isThought == true ? l10n.note : sourceLabel,
            playbackItem: item,
          );
        })
        .toList(growable: false);
  }
}

class FullTextAnchor {
  const FullTextAnchor(this.start, this.end, this.item);

  final int start;
  final int end;
  final TimelineItem item;
}

class SpeakerFullTextParagraph {
  const SpeakerFullTextParagraph({
    required this.start,
    required this.end,
    required this.item,
    required this.label,
    required this.textLayer,
    required this.canPlay,
  });

  final int start;
  final int end;
  final TimelineItem item;
  final String label;
  final TimelineTextLayer textLayer;
  final bool canPlay;
}

FullTextSearchDocument projectFullTextForSearch({
  required String sessionId,
  required List<TimelineItem> timeline,
  required FullTextRefinementSnapshot refinement,
  SpeakerDiarizationDocument? speakers,
}) {
  if (speakers != null &&
      speakers.sessionId == sessionId &&
      speakers.sampleRate == 16000) {
    // Speaker attribution needs the verified segment times. A composed full
    // text can rewrite punctuation or combine turns; never guess its timing.
    final projection = projectTimelineForDisplay(
      timeline: timeline,
      refinement:
          refinement.document?.sessionId == sessionId &&
              refinement.document?.sampleRate == 16000 &&
              refinement.document?.sourceAudioSamples ==
                  speakers.sourceAudioSamples
          ? refinement
          : const FullTextRefinementSnapshot.unavailable(),
      preference: TimelineTextPreference.refined,
    );
    final buffer = StringBuffer();
    final anchors = <FullTextAnchor>[];
    final paragraphs = <SpeakerFullTextParagraph>[];
    final segments = speakers.effectiveSegments;
    for (final display in projection.items) {
      final item = display.source;
      if (!item.isTranscript || display.displayText.trim().isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      final start = buffer.length;
      buffer.write(display.displayText.trim());
      final validRange =
          item.sampleOffset >= 0 &&
          item.endSample > item.sampleOffset &&
          item.endSample <= speakers.sourceAudioSamples;
      if (validRange) anchors.add(FullTextAnchor(start, buffer.length, item));
      paragraphs.add(
        SpeakerFullTextParagraph(
          start: start,
          end: buffer.length,
          item: item,
          label: validRange
              ? localizedSpeakerAttribution(
                      document: speakers,
                      startSample: item.sampleOffset,
                      endSample: item.endSample,
                      effectiveSegments: segments,
                    )['label']!
                    as String
              : l10n.speakerUnknown,
          textLayer: display.textLayer,
          canPlay: validRange,
        ),
      );
    }
    return FullTextSearchDocument(
      text: buffer.toString(),
      sourceLabel: projection.canSelectRefined
          ? l10n.refinedTranscriptSegments
          : l10n.liveTranscriptSegments,
      anchors: anchors,
      paragraphs: paragraphs,
    );
  }
  final document = refinement.document;
  if (refinement.status != FullTextRefinementStatus.ready ||
      document == null ||
      document.fullText.trim().isEmpty) {
    final buffer = StringBuffer();
    final anchors = <FullTextAnchor>[];
    for (final item in timeline) {
      if (!item.isTranscript || item.text.trim().isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      final start = buffer.length;
      buffer.write(item.text.trim());
      if (item.sampleOffset >= 0 && item.endSample > item.sampleOffset) {
        anchors.add(FullTextAnchor(start, buffer.length, item));
      }
    }
    return _readingDocument(
      text: buffer.toString(),
      sourceLabel: l10n.liveTranscript,
      anchors: anchors,
    );
  }

  final projection = projectTimelineForDisplay(
    timeline: timeline,
    refinement: refinement,
    preference: TimelineTextPreference.refined,
  );
  final verified =
      document.sessionId == sessionId &&
      document.sampleRate == 16000 &&
      (projection.availability == TimelineDisplayAvailability.ready ||
          projection.availability == TimelineDisplayAvailability.partial);
  return _readingDocument(
    text: document.fullText,
    sourceLabel: l10n.refinedTranscript,
    anchors: verified
        ? _exactProjectionAnchors(document, projection)
        : const [],
  );
}

FullTextSearchDocument _readingDocument({
  required String text,
  required String sourceLabel,
  required List<FullTextAnchor> anchors,
}) {
  final reading = formatReadingText(
    text,
    pauseOffsets: [
      for (var i = 1; i < anchors.length; i++)
        if (anchors[i].item.sampleOffset - anchors[i - 1].item.endSample >=
            32000)
          anchors[i].start,
    ],
  );
  return FullTextSearchDocument(
    text: reading.text,
    sourceLabel: sourceLabel,
    anchors: [
      for (final anchor in anchors)
        FullTextAnchor(
          reading.mapOffset(anchor.start),
          reading.mapOffset(anchor.end, end: true),
          anchor.item,
        ),
    ],
  );
}

List<FullTextAnchor> _exactProjectionAnchors(
  RefinedFullTextDocument document,
  TimelineDisplayProjection projection,
) {
  final sources =
      projection.items.where((item) => item.source.isTranscript).toList()
        ..sort((a, b) {
          final bySample = a.source.sampleOffset.compareTo(
            b.source.sampleOffset,
          );
          return bySample != 0
              ? bySample
              : a.source.eventId.compareTo(b.source.eventId);
        });
  final anchors = <FullTextAnchor>[];
  var cursor = 0;
  for (final display in sources) {
    final source = display.source;
    final text = display.displayText.trim();
    if (text.isEmpty) continue;
    if (source.sampleOffset < 0 ||
        source.endSample <= source.sampleOffset ||
        source.endSample > document.sourceAudioSamples) {
      return const [];
    }
    final start = document.fullText.indexOf(text, cursor);
    // Require a complete ordered alignment, allowing only formatting whitespace
    // between source segments. Ambiguity/rewrites disable playback, not search.
    if (start < 0 ||
        document.fullText.substring(cursor, start).trim().isNotEmpty) {
      return const [];
    }
    cursor = start + text.length;
    anchors.add(FullTextAnchor(start, cursor, source));
  }
  if (document.fullText.substring(cursor).trim().isNotEmpty) return const [];
  return anchors;
}
