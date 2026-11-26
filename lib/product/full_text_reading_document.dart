import '../domain/timeline/timeline_item.dart';
import 'full_text_search.dart';

/// Text offsets belong to this reading projection, never to persisted audio.
class FullTextAttachment {
  const FullTextAttachment({
    required this.start,
    required this.end,
    required this.items,
    required this.unplaced,
  });

  final int start;
  final int end;
  final List<TimelineItem> items;
  final bool unplaced;
  TimelineItem get item => items.first;
}

class FullTextReadingDocument {
  const FullTextReadingDocument(this.search, this.attachments);
  final FullTextSearchDocument search;
  final List<FullTextAttachment> attachments;
}

/// Inserts capture events only at paragraph boundaries backed by verified
/// transcript anchors. Without that alignment, keep them in a dated appendix.
FullTextReadingDocument composeFullTextReadingDocument(
  FullTextSearchDocument source,
  List<TimelineItem> timeline,
) {
  final events =
      timeline
          .where(
            (i) => i.isCommitted && (i.isImage || i.isThought || i.isBookmark),
          )
          .toList()
        ..sort((a, b) {
          final time = a.sampleOffset.compareTo(b.sampleOffset);
          return time != 0 ? time : a.sequence.compareTo(b.sequence);
        });
  if (events.isEmpty) return FullTextReadingDocument(source, const []);

  int insertionFor(TimelineItem event) {
    if (source.anchors.isEmpty || event.sampleOffset < 0) {
      return source.text.length;
    }
    final anchors = source.anchors;
    if (event.sampleOffset <= anchors.first.item.sampleOffset) return 0;
    var low = 0;
    var high = anchors.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (anchors[mid].item.sampleOffset <= event.sampleOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    // Do not interpolate timestamps from text length or split a sentence.
    final end = anchors[low - 1].end;
    var boundary = source.text.indexOf('\n', end);
    if (boundary < 0) return source.text.length;
    while (boundary < source.text.length &&
        (source.text[boundary] == '\n' || source.text[boundary] == '\r')) {
      boundary++;
    }
    return boundary;
  }

  final positioned = [for (final event in events) (insertionFor(event), event)];
  // Invalid/unmatched events go at the end even when their sample is negative.
  positioned.sort((a, b) {
    final offset = a.$1.compareTo(b.$1);
    if (offset != 0) return offset;
    final sample = a.$2.sampleOffset.compareTo(b.$2.sampleOffset);
    return sample != 0 ? sample : a.$2.sequence.compareTo(b.$2.sequence);
  });
  final text = StringBuffer();
  final attachments = <FullTextAttachment>[];
  final noteAnchors = <FullTextAnchor>[];
  final shifts = <(int, int)>[];
  var cursor = 0;
  for (final (offset, event) in positioned) {
    text.write(source.text.substring(cursor, offset));
    cursor = offset;
    final before = text.length;
    if (event.isThought) text.write('\n\n');
    final start = text.length;
    if (event.isThought) {
      text.write(
        event.text.isNotEmpty ? event.text : event.payload['text'] ?? '',
      );
    }
    final end = text.length;
    final unplaced = source.anchors.isEmpty || event.sampleOffset < 0;
    if (event.isImage &&
        attachments.isNotEmpty &&
        attachments.last.item.isImage &&
        attachments.last.start == start &&
        attachments.last.unplaced == unplaced) {
      final previous = attachments.removeLast();
      attachments.add(
        FullTextAttachment(
          start: start,
          end: end,
          items: List.unmodifiable([...previous.items, event]),
          unplaced: unplaced,
        ),
      );
    } else {
      attachments.add(
        FullTextAttachment(
          start: start,
          end: end,
          items: [event],
          unplaced: unplaced,
        ),
      );
    }
    if (event.isThought) {
      if (event.sampleOffset >= 0) {
        noteAnchors.add(FullTextAnchor(start, end, event));
      }
      text.write('\n\n');
      shifts.add((offset, text.length - before + (shifts.lastOrNull?.$2 ?? 0)));
    }
  }
  text.write(source.text.substring(cursor));

  int mapped(int offset, {bool end = false}) {
    var low = 0;
    var high = shifts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (shifts[mid].$1 < offset || (!end && shifts[mid].$1 == offset)) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return offset + (low == 0 ? 0 : shifts[low - 1].$2);
  }

  final anchors = [
    for (final anchor in source.anchors)
      FullTextAnchor(
        mapped(anchor.start),
        mapped(anchor.end, end: true),
        anchor.item,
      ),
    ...noteAnchors,
  ]..sort((a, b) => a.start.compareTo(b.start));
  return FullTextReadingDocument(
    FullTextSearchDocument(
      text: text.toString(),
      sourceLabel: source.sourceLabel,
      anchors: anchors,
    ),
    List.unmodifiable(attachments),
  );
}
