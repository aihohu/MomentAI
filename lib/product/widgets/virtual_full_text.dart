import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../domain/timeline/timeline_item.dart';
import '../full_text_reading_document.dart';
import '../local_search.dart';
import '../product_theme.dart';
import 'full_text_attachment_card.dart';
import 'search_highlighted_text.dart';

/// A single page scrollable: headers and lazily laid-out reading blocks share
/// the same viewport. Offscreen text does not retain RenderParagraph objects.
class VirtualFullText extends StatefulWidget {
  const VirtualFullText({
    super.key,
    required this.text,
    required this.query,
    required this.controller,
    required this.header,
    this.activeRange,
    this.storageKey,
    this.attachments = const [],
    this.onPlay,
    this.onOpenImage,
    this.onTimeline,
  });

  final String text;
  final String query;
  final ScrollController controller;
  final Widget header;
  final SearchTextRange? activeRange;
  final Key? storageKey;
  final List<FullTextAttachment> attachments;
  final ValueChanged<TimelineItem>? onPlay;
  final ValueChanged<TimelineItem>? onOpenImage;
  final ValueChanged<TimelineItem>? onTimeline;

  @override
  State<VirtualFullText> createState() => VirtualFullTextState();
}

class VirtualFullTextState extends State<VirtualFullText> {
  List<_ReadingBlock> _blocks = [];
  List<SearchTextRange> _matches = [];
  final _keys = <int, GlobalKey>{};
  final _rowKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _updateText();
  }

  @override
  void didUpdateWidget(VirtualFullText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        !identical(oldWidget.attachments, widget.attachments)) {
      _updateText();
    }
    if (oldWidget.query != widget.query) {
      _matches = searchTextRanges(widget.text, widget.query);
    }
  }

  void _updateText() {
    _blocks = _mixedBlocks(widget.text, widget.attachments);
    _matches = searchTextRanges(widget.text, widget.query);
    _keys.clear();
    _rowKeys.clear();
  }

  int _blockIndex(int offset) {
    var lo = 0;
    var hi = _blocks.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_blocks[mid].end <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo.clamp(0, _blocks.length - 1);
  }

  RenderParagraph? _renderParagraph(GlobalKey? key) {
    final root = key?.currentContext?.findRenderObject();
    if (root == null || !root.attached) return null;
    RenderParagraph? result;
    void visit(RenderObject node) {
      if (node is RenderParagraph) {
        result = node;
      } else if (result == null) {
        node.visitChildren(visit);
      }
    }

    visit(root);
    return result;
  }

  Rect? matchRect(SearchTextRange range) {
    if (_blocks.isEmpty || range.end > widget.text.length) return null;
    final index = _blockIndex(range.start);
    final render = _renderParagraph(_keys[index]);
    if (render == null || !render.attached) return null;
    final block = _blocks[index];
    final boxes = render.getBoxesForSelection(
      TextSelection(
        baseOffset: (range.start - block.start).clamp(
          0,
          (block.end - block.start),
        ),
        extentOffset: (range.end - block.start).clamp(
          0,
          (block.end - block.start),
        ),
      ),
    );
    if (boxes.isEmpty) return null;
    return boxes.first.toRect().shift(render.localToGlobal(Offset.zero));
  }

  /// Estimate from currently mounted block positions, then let the caller
  /// refine on the next frame. Works in both directions without walking every
  /// preceding paragraph or laying out the entire document to find one match.
  double? estimateOffset(SearchTextRange range) {
    if (_blocks.isEmpty || !widget.controller.hasClients) return null;
    final target = _blockIndex(range.start);
    final mounted = <(int, RenderBox)>[];
    for (final entry in _rowKeys.entries) {
      final render = entry.value.currentContext?.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        mounted.add((entry.key, render));
      }
    }
    final position = widget.controller.position;
    if (mounted.isEmpty) {
      return position.maxScrollExtent * (target + 1) / (_blocks.length + 1);
    }
    mounted.sort((a, b) => a.$1.compareTo(b.$1));
    final anchor = mounted.reduce(
      (a, b) => (a.$1 - target).abs() < (b.$1 - target).abs() ? a : b,
    );
    final viewport = RenderAbstractViewport.of(anchor.$2);
    final anchorOffset = viewport.getOffsetToReveal(anchor.$2, 0).offset;
    final average =
        mounted.fold<double>(0, (sum, p) => sum + p.$2.size.height) /
        mounted.length;
    return (anchorOffset + (target - anchor.$1) * average).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView.builder(
        key: widget.storageKey,
        controller: widget.controller,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
        itemCount: _blocks.length + 1,
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) {
          if (index == 0) return widget.header;
          final blockIndex = index - 1;
          final block = _blocks[blockIndex];
          SearchTextRange? local(SearchTextRange? range) {
            if (range == null ||
                range.end <= block.start ||
                range.start >= block.end) {
              return null;
            }
            return SearchTextRange(
              (range.start - block.start).clamp(0, (block.end - block.start)),
              (range.end - block.start).clamp(0, (block.end - block.start)),
            );
          }

          final matches = _matches
              .map(local)
              .whereType<SearchTextRange>()
              .toList();
          final text = widget.text
              .substring(block.start, block.end)
              .replaceFirst(RegExp(r'\r?\n$'), '');
          const style = TextStyle(
            height: 1.75,
            fontSize: 16,
            color: ProductColors.ink,
          );
          final key = _keys.putIfAbsent(blockIndex, GlobalKey.new);
          final attachment = block.attachment;
          if (attachment != null) {
            return KeyedSubtree(
              key: _rowKeys.putIfAbsent(blockIndex, GlobalKey.new),
              child: FullTextAttachmentCard(
                attachment: attachment,
                text: widget.text.substring(block.start, block.end),
                query: widget.query,
                activeRange: local(widget.activeRange),
                textKey: key,
                showUnplacedNotice:
                    attachment.unplaced &&
                    widget.attachments.firstWhere((a) => a.unplaced) ==
                        attachment,
                onPlay: widget.onPlay,
                onOpenImage: widget.onOpenImage,
                onTimeline: widget.onTimeline,
              ),
            );
          }
          return KeyedSubtree(
            key: _rowKeys.putIfAbsent(blockIndex, GlobalKey.new),
            child: ColoredBox(
              key: ValueKey('reading-block-$blockIndex'),
              color:
                  Theme.of(context).cardTheme.color ??
                  Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  blockIndex == 0 ? 18 : 0,
                  18,
                  blockIndex == _blocks.length - 1 ? 18 : 0,
                ),
                child: matches.isEmpty
                    ? Text(text, key: key, style: style)
                    : Text.rich(
                        searchHighlightedSpan(
                          text,
                          matches,
                          activeRange: local(widget.activeRange),
                        ),
                        key: key,
                        style: style,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ReadingBlock {
  const _ReadingBlock(this.start, this.end, [this.attachment]);
  final int start;
  final int end;
  final FullTextAttachment? attachment;
}

List<_ReadingBlock> _mixedBlocks(
  String text,
  List<FullTextAttachment> attachments,
) {
  final result = <_ReadingBlock>[];
  void appendText(int start, int end) {
    for (final block in readingBlocks(text.substring(start, end))) {
      // Attachment padding supplies spacing for inserted blank-only blocks.
      if (attachments.isNotEmpty &&
          text
              .substring(start + block.start, start + block.end)
              .trim()
              .isEmpty) {
        continue;
      }
      result.add(_ReadingBlock(start + block.start, start + block.end));
    }
  }

  var cursor = 0;
  for (final attachment in attachments) {
    appendText(cursor, attachment.start);
    result.add(_ReadingBlock(attachment.start, attachment.end, attachment));
    cursor = attachment.end;
  }
  appendText(cursor, text.length);
  return result;
}

/// Exact UTF-16 offsets; no inserted/deleted content, including newlines and
/// emoji. Existing paragraphs win; a pathological unbroken paragraph is split
/// into bounded layout blocks without changing the stored/searchable text.
List<SearchTextRange> readingBlocks(String text) {
  final blocks = <SearchTextRange>[];
  var start = 0;
  var offset = 0;
  var count = 0;
  for (final char in text.characters) {
    offset += char.length;
    count++;
    final nextIsNewline =
        offset < text.length &&
        (text.codeUnitAt(offset) == 10 || text.codeUnitAt(offset) == 13);
    if ((char.contains('\n') && !nextIsNewline) || count >= 480) {
      blocks.add(SearchTextRange(start, offset));
      start = offset;
      count = 0;
    }
  }
  if (start < text.length) blocks.add(SearchTextRange(start, text.length));
  return blocks;
}
