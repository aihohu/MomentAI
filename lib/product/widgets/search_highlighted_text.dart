import 'package:flutter/material.dart';

import '../local_search.dart';
import '../product_theme.dart';

class SearchHighlightedText extends StatelessWidget {
  const SearchHighlightedText(
    this.text, {
    super.key,
    required this.query,
    this.activeRange,
    this.style,
    this.maxLines,
  });

  final String text;
  final String query;
  final SearchTextRange? activeRange;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final matches = searchTextRanges(text, query);
    if (matches.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      );
    }
    return Text.rich(
      searchHighlightedSpan(text, matches, activeRange: activeRange),
      style: style,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

TextSpan searchHighlightedSpan(
  String text,
  List<SearchTextRange> matches, {
  SearchTextRange? activeRange,
}) {
  final spans = <TextSpan>[];
  var offset = 0;
  for (final match in matches) {
    if (match.start > offset) {
      spans.add(TextSpan(text: text.substring(offset, match.start)));
    }
    spans.add(
      TextSpan(
        text: text.substring(match.start, match.end),
        style: TextStyle(
          color: ProductColors.ink,
          backgroundColor: match.start == activeRange?.start
              ? const Color(0xFFFFD580)
              : ProductColors.amberSoft,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    offset = match.end;
  }
  if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
  return TextSpan(children: spans);
}
