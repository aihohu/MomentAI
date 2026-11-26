// ignore_for_file: prefer_initializing_formals
import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/timeline/timeline_item.dart';
import '../../domain/transcript/refined_full_text.dart';
import '../product_theme.dart';

enum RecordContentView { timeline, fullText, aiSummary }

class RecordContentSwitcher extends StatelessWidget {
  const RecordContentSwitcher({
    super.key,
    required this.groupName,
    required this.selected,
    required this.onChanged,
    this.showAiSummary = false,
  });

  final String groupName;
  final RecordContentView selected;
  final ValueChanged<RecordContentView> onChanged;
  final bool showAiSummary;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Semantics(
      container: true,
      label: groupName == 'capture'
          ? l10n.liveRecordingView
          : l10n.originalRecordingView,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: ProductColors.line)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final views = [
              RecordContentView.timeline,
              RecordContentView.fullText,
              if (showAiSummary) RecordContentView.aiSummary,
            ];
            final labels = [
              l10n.timeline,
              l10n.fullText,
              if (showAiSummary) l10n.aiSummary,
            ];
            final keys = [
              '$groupName-timeline-tab',
              '$groupName-fulltext-tab',
              if (showAiSummary) '$groupName-ai-summary-tab',
            ];
            final widths = labels.map((label) {
              final painter = TextPainter(
                text: TextSpan(
                  text: label,
                  style: DefaultTextStyle.of(
                    context,
                  ).style.copyWith(fontWeight: FontWeight.w800),
                ),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 1,
              )..layout();
              final width = painter.width + 24;
              painter.dispose();
              return width < 48 ? 48.0 : width;
            }).toList();
            final fits = widths.every(
              (width) => width <= constraints.maxWidth / views.length,
            );
            final segments = List.generate(
              views.length,
              (index) => _RecordSegment(
                buttonKey: Key(keys[index]),
                label: labels[index],
                selected: selected == views[index],
                onTap: () => onChanged(views[index]),
              ),
            );
            if (fits) {
              return Row(
                children: segments
                    .map((segment) => Expanded(child: segment))
                    .toList(),
              );
            }
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(
                  segments.length,
                  (index) =>
                      SizedBox(width: widths[index], child: segments[index]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RecordSegment extends StatelessWidget {
  const _RecordSegment({
    required this.buttonKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key buttonKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        key: buttonKey,
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected
                          ? ProductColors.forest
                          : ProductColors.mutedInk,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  width: selected ? 34 : 0,
                  height: 3,
                  decoration: BoxDecoration(
                    color: ProductColors.forest,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TranscriptFullText extends StatelessWidget {
  const TranscriptFullText({
    super.key,
    required this.items,
    String? emptyMessage,
    this.textBuilder,
  }) : _emptyMessage = emptyMessage;

  final List<TimelineItem> items;
  final String? _emptyMessage;
  String get emptyMessage => _emptyMessage ?? l10n.noSavedTranscriptYet;
  final Widget Function(String text)? textBuilder;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    if (items.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            emptyMessage,
            style: const TextStyle(color: ProductColors.mutedInk, height: 1.45),
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child:
            textBuilder?.call(
              items.map((item) => item.text.trim()).join('\n\n'),
            ) ??
            SelectableText(
              items.map((item) => item.text.trim()).join('\n\n'),
              key: const Key('transcript-full-text-content'),
              style: const TextStyle(
                height: 1.75,
                color: ProductColors.ink,
                fontSize: 16,
              ),
            ),
      ),
    );
  }
}

class RefinedTranscriptFullText extends StatelessWidget {
  const RefinedTranscriptFullText({
    super.key,
    required this.snapshot,
    required this.fallbackItems,
    this.isFinishing = false,
    this.textBuilder,
    this.headerOnly = false,
    this.showStatus = true,
  });

  final FullTextRefinementSnapshot snapshot;
  final List<TimelineItem> fallbackItems;
  final bool isFinishing;
  final bool headerOnly;
  final bool showStatus;
  final Widget Function(String text)? textBuilder;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final document = snapshot.document;
    if (document != null && document.fullText.trim().isNotEmpty) {
      return Card(
        key: const Key('refined-full-text-card'),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    color: ProductColors.forest,
                    size: 18,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.sensevoiceLocalRefinement,
                      style: TextStyle(
                        color: ProductColors.forest,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.lock_outline_rounded,
                    color: ProductColors.mutedInk,
                    size: 17,
                  ),
                ],
              ),
              if (!headerOnly) ...[
                const SizedBox(height: 14),
                textBuilder?.call(document.fullText) ??
                    SelectableText(
                      document.fullText,
                      key: const Key('transcript-full-text-content'),
                      style: const TextStyle(
                        height: 1.75,
                        color: ProductColors.ink,
                        fontSize: 16,
                      ),
                    ),
              ],
            ],
          ),
        ),
      );
    }

    final refining =
        snapshot.status == FullTextRefinementStatus.processing || isFinishing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showStatus && refining)
          Container(
            key: const Key('full-text-refining-banner'),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ProductColors.forestSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.addingPunctuationAndOrganizingParagraphsOnThis,
                    style: TextStyle(
                      color: ProductColors.forest,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (showStatus &&
            snapshot.status == FullTextRefinementStatus.failed)
          Container(
            key: const Key('full-text-refinement-failed'),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ProductColors.amberSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              l10n.localRefinementIsNotCompleteShowingThe,
              style: TextStyle(
                color: ProductColors.amber,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ),
        if (!headerOnly)
          TranscriptFullText(items: fallbackItems, textBuilder: textBuilder),
      ],
    );
  }
}

List<TimelineItem> committedTranscripts(Iterable<TimelineItem> items) => items
    .where((item) => item.isTranscript && item.text.trim().isNotEmpty)
    .toList(growable: false);
