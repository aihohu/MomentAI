import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/timeline/timeline_item.dart';
import '../../l10n/app_localization.dart';
import '../full_text_reading_document.dart';
import '../local_search.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import 'search_highlighted_text.dart';

class FullTextAttachmentCard extends StatelessWidget {
  const FullTextAttachmentCard({
    super.key,
    required this.attachment,
    required this.text,
    required this.query,
    this.activeRange,
    this.textKey,
    this.showUnplacedNotice = false,
    this.onPlay,
    this.onOpenImage,
    this.onTimeline,
  });

  final FullTextAttachment attachment;
  final String text;
  final String query;
  final SearchTextRange? activeRange;
  final Key? textKey;
  final bool showUnplacedNotice;
  final ValueChanged<TimelineItem>? onPlay;
  final ValueChanged<TimelineItem>? onOpenImage;
  final ValueChanged<TimelineItem>? onTimeline;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final item = attachment.item;
    final label = item.isImage
        ? strings.photos869
        : item.isThought
        ? strings.textNote
        : strings.highlight;
    final color = item.isBookmark ? ProductColors.amber : ProductColors.forest;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showUnplacedNotice)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                strings.fullTextUnplacedAttachments,
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  height: 1.5,
                ),
              ),
            ),
          Container(
            key: ValueKey('fulltext-event-${item.playbackId}'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: item.isBookmark
                  ? ProductColors.amberSoft
                  : ProductColors.forestSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      item.isImage
                          ? Icons.photo_outlined
                          : item.isThought
                          ? Icons.edit_note_rounded
                          : Icons.bookmark_outline_rounded,
                      size: 18,
                      color: color,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (item.sampleOffset >= 0)
                      Text(
                        formatDuration(item.atMs),
                        style: const TextStyle(
                          color: ProductColors.mutedInk,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                if (item.isThought) ...[
                  const SizedBox(height: 8),
                  SearchHighlightedText(
                    text,
                    key: textKey,
                    query: query,
                    activeRange: activeRange,
                    style: const TextStyle(fontSize: 16, height: 1.75),
                  ),
                ],
                if (item.isImage) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 150,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: attachment.items.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final photo = attachment.items[index];
                        return SizedBox(
                          width: 180,
                          child: Column(
                            children: [
                              Expanded(
                                child: Semantics(
                                  label: strings.openOriginalPhoto,
                                  button: true,
                                  child: InkWell(
                                    key: ValueKey(
                                      'fulltext-photo-${photo.playbackId}',
                                    ),
                                    onTap: photo.assetPath.isEmpty
                                        ? null
                                        : () => onOpenImage?.call(photo),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: SizedBox.expand(
                                        child: photo.assetPath.isEmpty
                                            ? const Icon(
                                                Icons.broken_image_outlined,
                                              )
                                            : Image.file(
                                                File(photo.assetPath),
                                                fit: BoxFit.cover,
                                                cacheWidth: 540,
                                                errorBuilder: (_, _, _) =>
                                                    const Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                    ),
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (attachment.items.length > 1)
                                Text(
                                  formatDuration(photo.atMs),
                                  style: const TextStyle(
                                    color: ProductColors.mutedInk,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    if (onTimeline != null)
                      TextButton(
                        key: ValueKey(
                          'fulltext-event-timeline-${item.playbackId}',
                        ),
                        onPressed: () => onTimeline!(item),
                        child: Text(strings.viewInTimeline),
                      ),
                    if (item.sampleOffset >= 0)
                      TextButton.icon(
                        key: ValueKey('fulltext-event-play-${item.playbackId}'),
                        onPressed: onPlay == null ? null : () => onPlay!(item),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: Text(strings.playFromHere),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
