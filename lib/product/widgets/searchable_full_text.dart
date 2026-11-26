import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/timeline/timeline_item.dart';
import '../full_text_search.dart';
import '../local_search.dart';
import '../product_theme.dart';
import '../timeline_display_item.dart';
import 'search_highlighted_text.dart';

class SearchableFullText extends StatefulWidget {
  const SearchableFullText({
    super.key,
    required this.text,
    required this.query,
    this.activeRange,
    this.paragraphs = const [],
    this.onPlay,
  });

  final String text;
  final String query;
  final SearchTextRange? activeRange;
  final List<SpeakerFullTextParagraph> paragraphs;
  final ValueChanged<TimelineItem>? onPlay;

  @override
  State<SearchableFullText> createState() => SearchableFullTextState();
}

class SearchableFullTextState extends State<SearchableFullText> {
  final _textKey = GlobalKey();
  final _paragraphKeys = <int, GlobalKey>{};

  /// Bounds of the actual laid-out glyphs, including paragraph headings.
  Rect? matchRect(SearchTextRange range) {
    var key = _textKey;
    var start = range.start;
    var end = range.end;
    if (widget.paragraphs.isNotEmpty) {
      SpeakerFullTextParagraph? paragraph;
      for (final candidate in widget.paragraphs) {
        if (candidate.end > range.start && candidate.start < range.end) {
          paragraph = candidate;
          break;
        }
      }
      if (paragraph == null) return null;
      key = _paragraphKeys[paragraph.start] ?? _textKey;
      start = (range.start - paragraph.start).clamp(
        0,
        paragraph.end - paragraph.start,
      );
      end = (range.end - paragraph.start).clamp(
        start,
        paragraph.end - paragraph.start,
      );
    }
    final root = key.currentContext?.findRenderObject();
    if (root == null || !root.attached) return null;
    RenderParagraph? paragraph;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        paragraph = object;
      } else if (paragraph == null) {
        object.visitChildren(visit);
      }
    }

    visit(root);
    final render = paragraph;
    if (render == null || range.end > widget.text.length) return null;
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    if (boxes.isEmpty) return null;
    return boxes.first.toRect().shift(render.localToGlobal(Offset.zero));
  }

  Widget _text(int start, int end, Key key, List<SearchTextRange> matches) {
    SearchTextRange? localRange(SearchTextRange? range) {
      if (range == null || range.end <= start || range.start >= end) {
        return null;
      }
      return SearchTextRange(
        (range.start - start).clamp(0, end - start),
        (range.end - start).clamp(0, end - start),
      );
    }

    final localMatches = matches
        .map(localRange)
        .whereType<SearchTextRange>()
        .toList();
    final text = widget.text.substring(start, end);
    const style = TextStyle(
      height: 1.75,
      color: ProductColors.ink,
      fontSize: 16,
    );
    return localMatches.isEmpty
        ? Text(text, key: key, style: style)
        : Text.rich(
            searchHighlightedSpan(
              text,
              localMatches,
              activeRange: localRange(widget.activeRange),
            ),
            key: key,
            style: style,
          );
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final matches = searchTextRanges(widget.text, widget.query);
    final starts = widget.paragraphs.map((p) => p.start).toSet();
    _paragraphKeys.removeWhere((start, _) => !starts.contains(start));
    // SelectionArea preserves copying across paragraphs without the nested
    // EditableText scrollable that consumed vertical drags inside the page.
    return SelectionArea(
      child: widget.paragraphs.isEmpty
          ? KeyedSubtree(
              key: _textKey,
              child: _text(
                0,
                widget.text.length,
                const Key('transcript-full-text-content'),
                matches,
              ),
            )
          : Column(
              key: const Key('speaker-full-text-content'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.speakerEstimateNotice,
                  style: TextStyle(
                    color: ProductColors.mutedInk,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                for (final paragraph in widget.paragraphs) ...[
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          paragraph.label,
                          style: const TextStyle(
                            color: ProductColors.forest,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (paragraph.item.sampleOffset >= 0)
                        TextButton(
                          key: ValueKey(
                            'full-text-play-${paragraph.item.playbackId}',
                          ),
                          onPressed: !paragraph.canPlay || widget.onPlay == null
                              ? null
                              : () => widget.onPlay!(paragraph.item),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(_time(paragraph.item.sampleOffset)),
                        ),
                    ],
                  ),
                  if (paragraph.textLayer == TimelineTextLayer.fallback)
                    Text(
                      l10n.thisSegmentUsesTheOriginalTranscript,
                      style: TextStyle(
                        color: ProductColors.mutedInk,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 6),
                  _text(
                    paragraph.start,
                    paragraph.end,
                    _paragraphKeys.putIfAbsent(paragraph.start, GlobalKey.new),
                    matches,
                  ),
                ],
              ],
            ),
    );
  }

  String _time(int sample) {
    final seconds = sample ~/ 16000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
