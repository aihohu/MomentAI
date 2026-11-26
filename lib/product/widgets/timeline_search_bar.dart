import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../local_search.dart';
import '../product_formatters.dart';
import 'search_highlighted_text.dart';

class TimelineSearchBar extends StatelessWidget {
  const TimelineSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.hits,
    required this.activeIndex,
    required this.onChanged,
    required this.onSubmitted,
    required this.onPrevious,
    required this.onNext,
    required this.onPlay,
    this.hidePreview = false,
    this.notice,
    this.isFullText = false,
    this.viewSwitcher,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final List<RecordSearchHit> hits;
  final int activeIndex;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback? onPlay;
  final bool hidePreview;
  final String? notice;
  final bool isFullText;
  final Widget? viewSwitcher;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final hit = activeIndex >= 0 && activeIndex < hits.length
        ? hits[activeIndex]
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactActions =
            hidePreview ||
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('detail-search-field'),
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: (_) => onSubmitted(),
                // Keep the touched action mounted until pointer-up; dismissing
                // on pointer-down can relayout the keyboard-sized toolbar and
                // swallow the first tap on a navigation/play button.
                onTapUpOutside: (_) => focusNode.unfocus(),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: isFullText
                      ? l10n.searchFullText
                      : l10n.searchTimelineTextAndNotes,
                  prefixIcon: viewSwitcher ?? const Icon(Icons.search_rounded),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.clearSearch,
                          onPressed: () {
                            controller.clear();
                            onChanged('');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              if (query.trim().isNotEmpty) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        hit == null
                            ? l10n.noMatches
                            : compactActions
                            ? '${activeIndex + 1}/${hits.length}'
                            : l10n.match(
                                (activeIndex + 1).toString(),
                                (hits.length).toString(),
                              ),
                        semanticsLabel: hit == null
                            ? l10n.noMatches
                            : l10n.matchOf(
                                (activeIndex + 1).toString(),
                                (hits.length).toString(),
                              ),
                        key: const Key('detail-search-count'),
                      ),
                    ),
                    IconButton(
                      key: const Key('detail-search-previous'),
                      tooltip: l10n.previousMatch,
                      onPressed: hit == null ? null : onPrevious,
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    ),
                    IconButton(
                      key: const Key('detail-search-next'),
                      tooltip: l10n.nextMatch,
                      onPressed: hit == null ? null : onNext,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                    if (compactActions)
                      IconButton(
                        key: const Key('detail-search-play'),
                        tooltip: l10n.listenHereFromSegmentStart,
                        onPressed: hit == null ? null : onPlay,
                        icon: const Icon(Icons.play_circle_outline_rounded),
                      )
                    else
                      TextButton.icon(
                        key: const Key('detail-search-play'),
                        onPressed: hit == null ? null : onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(l10n.listenHere),
                      ),
                  ],
                ),
                if (hit != null && !hidePreview) ...[
                  Text(
                    hit.playbackItem == null
                        ? hit.sourceLabel
                        : l10n.playbackStartsAtTheOriginalSegmentBoundary(
                            (hit.sourceLabel).toString(),
                            (formatDuration(hit.playbackItem!.atMs)).toString(),
                          ),
                  ),
                  SearchHighlightedText(hit.preview, query: query, maxLines: 2),
                ],
                if (hit != null && hit.playbackItem == null)
                  Text(l10n.noReliableAudioAnchorHereOnlyThe),
                if (notice != null) Text(notice!),
              ],
            ],
          ),
        );
      },
    );
  }
}
