// ignore_for_file: prefer_initializing_formals
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/timeline/timeline_item.dart';
import '../local_search.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import 'search_highlighted_text.dart';

class ProductTimelineRow extends StatelessWidget {
  const ProductTimelineRow({
    super.key,
    required this.item,
    required this.isFirst,
    required this.isLast,
    this.selected = false,
    this.canPlay = false,
    this.onPlay,
    this.onOpenImage,
    String? inactivePlaybackLabel = '',
    this.showImagePlaybackAction = true,
    this.displayText,
    this.searchQuery = '',
    this.activeSearchRange,
    this.speakerLabel,
    this.transcriptTextKey,
  }) : _inactivePlaybackLabel = inactivePlaybackLabel;

  final TimelineItem item;
  final bool isFirst;
  final bool isLast;
  final bool selected;
  final bool canPlay;
  final VoidCallback? onPlay;
  final VoidCallback? onOpenImage;
  final String? _inactivePlaybackLabel;
  String? get inactivePlaybackLabel => _inactivePlaybackLabel == ''
      ? l10n.playbackUnavailable
      : _inactivePlaybackLabel;
  final bool showImagePlaybackAction;
  final String? displayText;
  final String searchQuery;
  final SearchTextRange? activeSearchRange;
  final String? speakerLabel;
  final Key? transcriptTextKey;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final committedAnchor = !item.isCaptureEvent || item.isCommitted;
    final playable =
        committedAnchor &&
        (item.isTranscript || item.isThought || item.isBookmark);
    final (icon, label, color) = _visuals(item);
    final time = formatDuration(item.atMs);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: ValueKey('timeline-rail-${item.playbackId}'),
            width: 24,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TimelineRailPainter(
                      isFirst: isFirst,
                      isLast: isLast,
                      color: selected
                          ? ProductColors.forest
                          : ProductColors.line,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: selected
                          ? ProductColors.forest
                          : ProductColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? ProductColors.forest : color,
                        width: selected ? 2 : 1.5,
                      ),
                    ),
                    child: Icon(
                      selected ? Icons.graphic_eq_rounded : icon,
                      size: 13,
                      color: selected ? ProductColors.surface : color,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                key: ValueKey('product-timeline-${item.playbackId}'),
                color: selected
                    ? ProductColors.forestSoft
                    : ProductColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: selected
                        ? ProductColors.forest
                        : activeSearchRange != null
                        ? ProductColors.amber
                        : ProductColors.line,
                    width: selected || activeSearchRange != null ? 1.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: playable && canPlay ? onPlay : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Semantics(
                                label: l10n.recordingTime((time).toString()),
                                child: ExcludeSemantics(
                                  child: Text(
                                    time,
                                    key: ValueKey(
                                      'timeline-time-${item.playbackId}',
                                    ),
                                    maxLines: 1,
                                    style: const TextStyle(
                                      color: ProductColors.mutedInk,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  textAlign: TextAlign.right,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (item.isTranscript) ...[
                            if (speakerLabel != null) ...[
                              const SizedBox(height: 8),
                              _SpeakerBadge(label: speakerLabel!),
                            ],
                            const SizedBox(height: 8),
                            KeyedSubtree(
                              key: transcriptTextKey,
                              child: SearchHighlightedText(
                                (displayText ?? item.text).isEmpty
                                    ? l10n.noText
                                    : displayText ?? item.text,
                                query: searchQuery,
                                activeRange: activeSearchRange,
                                style: const TextStyle(height: 1.5),
                              ),
                            ),
                          ] else if (item.isThought) ...[
                            const SizedBox(height: 8),
                            SearchHighlightedText(
                              _thoughtText(item),
                              query: searchQuery,
                              activeRange: activeSearchRange,
                              style: const TextStyle(height: 1.5),
                            ),
                          ] else if (item.isImage) ...[
                            const SizedBox(height: 10),
                            _ImagePreview(
                              path: item.assetPath,
                              onTap: onOpenImage,
                            ),
                            if (item.wallTime.isNotEmpty ||
                                showImagePlaybackAction) ...[
                              const SizedBox(height: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (item.wallTime.isNotEmpty)
                                    Text(
                                      _wallTimeLabel(item.wallTime),
                                      style: const TextStyle(
                                        color: ProductColors.mutedInk,
                                        fontSize: 12,
                                      ),
                                    ),
                                  if (showImagePlaybackAction)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        key: ValueKey(
                                          'play-image-${item.playbackId}',
                                        ),
                                        onPressed: item.isCommitted && canPlay
                                            ? onPlay
                                            : null,
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                        ),
                                        label: Text(l10n.playFromHere),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ] else if (item.isBookmark) ...[
                            const SizedBox(height: 6),
                            Text(
                              canPlay
                                  ? l10n.tapToListenToThisHighlightedMoment
                                  : l10n.highlightSavedAtThisMoment,
                            ),
                          ] else ...[
                            const SizedBox(height: 6),
                            Text(
                              _systemEventLabel(item),
                              style: const TextStyle(
                                color: ProductColors.mutedInk,
                              ),
                            ),
                          ],
                          if (item.isCaptureEvent && !item.isCommitted) ...[
                            const SizedBox(height: 10),
                            Text(
                              l10n.thisEventWasNotSavedSuccessfullyAnd,
                              style: TextStyle(
                                color: ProductColors.vermilion,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                          if (playable &&
                              (canPlay || inactivePlaybackLabel != null)) ...[
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Icon(
                                  selected && canPlay
                                      ? Icons.graphic_eq_rounded
                                      : canPlay
                                      ? Icons.play_arrow_rounded
                                      : Icons.schedule_rounded,
                                  size: 17,
                                  color: canPlay
                                      ? ProductColors.forest
                                      : ProductColors.mutedInk,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    selected && canPlay
                                        ? l10n.playing867
                                        : canPlay
                                        ? l10n.tapToListen
                                        : inactivePlaybackLabel!,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: canPlay
                                          ? ProductColors.forest
                                          : ProductColors.mutedInk,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static (IconData, String, Color) _visuals(TimelineItem item) {
    if (item.isTranscript) {
      return (Icons.notes_rounded, l10n.transcript, ProductColors.forest);
    }
    if (item.isImage) {
      return (Icons.photo_outlined, l10n.photos869, ProductColors.forest);
    }
    if (item.isThought) {
      return (Icons.edit_note_rounded, l10n.textNote, ProductColors.forest);
    }
    if (item.isBookmark) {
      return (
        Icons.bookmark_outline_rounded,
        l10n.highlight,
        ProductColors.vermilion,
      );
    }
    if (item.type == 'user_pause_began') {
      return (Icons.pause_rounded, l10n.pauseRecording, ProductColors.forest);
    }
    if (item.type == 'user_pause_ended') {
      return (Icons.mic_rounded, l10n.resumeRecording, ProductColors.forest);
    }
    return (
      Icons.info_outline_rounded,
      l10n.recordingEvent,
      ProductColors.mutedInk,
    );
  }

  static String _thoughtText(TimelineItem item) => item.text.isNotEmpty
      ? item.text
      : item.payload['text']?.toString() ?? l10n.emptyNote;

  static String _wallTimeLabel(String raw) {
    final date = DateTime.tryParse(raw)?.toLocal();
    if (date == null) return '';
    String two(int value) => value.toString().padLeft(2, '0');
    return l10n.takenAt(
      (two(date.hour)).toString(),
      (two(date.minute)).toString(),
      (two(date.second)).toString(),
    );
  }

  static String _systemEventLabel(TimelineItem item) => switch (item.type) {
    'session_started' => l10n.recordingStarted,
    'session_stopped' => l10n.recordingSafelyFinished,
    'session_recovered' => l10n.unfinishedRecordingSafelyRecovered,
    'user_pause_began' => l10n.microphoneStoppedAudioPositionIsUnchanged,
    'user_pause_ended' => _pauseEndedLabel(item),
    'audio_interruption_began' => l10n.systemAudioInterrupted,
    'audio_interruption_ended' ||
    'audio_interruption_restarted' => l10n.systemAudioRestored,
    'stage1_s1_5_application_background' =>
      l10n.appMovedToBackgroundRecordingContinues,
    'stage1_s1_5_application_foreground' => l10n.appReturnedToForeground,
    'stage1_s1_5_protected_data_unavailable' =>
      l10n.deviceLockedRecordingContinues,
    'stage1_s1_5_protected_data_available' => l10n.deviceDataAvailableAgain,
    'audio_route_changed' => l10n.audioDeviceChanged,
    'stage0_asr_probe_stop_snapshot' => l10n.localTranscriptionIsFinishing,
    _ => l10n.systemEventRecorded,
  };

  static String _pauseEndedLabel(TimelineItem item) {
    final duration = _number(item.payload['duration_ms']);
    final reason = item.payload['end_reason']?.toString();
    final prefix = switch (reason) {
      'session_stopped' => l10n.safelyFinishedWhilePaused,
      'session_recovered' => l10n.safelyFinishedAfterRecoveringAPausedRecording,
      _ => l10n.recordingResumedFromTheSameAudioPosition889,
    };
    return duration > 0
        ? l10n.pausedFor(
            (prefix).toString(),
            (formatDuration(duration)).toString(),
          )
        : prefix;
  }
}

class _SpeakerBadge extends StatelessWidget {
  const _SpeakerBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: ProductColors.forestSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: ProductColors.forest,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

int _number(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({
    required this.isFirst,
    required this.isLast,
    required this.color,
  });

  final bool isFirst;
  final bool isLast;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const nodeCenterY = 22.0;
    final x = size.width / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(x, isFirst ? nodeCenterY : 0),
      Offset(x, isLast ? nodeCenterY : size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TimelineRailPainter oldDelegate) =>
      oldDelegate.isFirst != isFirst ||
      oldDelegate.isLast != isLast ||
      oldDelegate.color != color;
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.path, required this.onTap});

  final String path;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Semantics(
      button: path.isNotEmpty && onTap != null,
      enabled: path.isNotEmpty && onTap != null,
      label: l10n.openOriginalPhoto,
      onTap: path.isEmpty ? null : onTap,
      child: ExcludeSemantics(
        child: InkWell(
          key: ValueKey('open-image-$path'),
          onTap: path.isEmpty ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: path.isEmpty
                  ? const _MissingImage()
                  : Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      cacheWidth: 900,
                      errorBuilder: (_, _, _) => const _MissingImage(),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return const ColoredBox(
      color: ProductColors.forestSoft,
      child: Center(
        child: Icon(Icons.broken_image_outlined, color: ProductColors.mutedInk),
      ),
    );
  }
}
