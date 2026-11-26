import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/session/session_summary.dart';
import '../product_formatters.dart';
import '../product_theme.dart';

class SessionSummaryCard extends StatelessWidget {
  const SessionSummaryCard({super.key, required this.session, this.onTap});

  final SessionSummary session;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Semantics(
      container: true,
      button: onTap != null,
      enabled: onTap != null,
      onTap: onTap,
      label: _semanticLabel(),
      child: ExcludeSemantics(
        child: Card(
          key: ValueKey('product-session-${session.sessionId}'),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          session.title.isEmpty
                              ? l10n.untitledRecording
                              : session.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _StatusBadge(status: session.status),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${formatSessionDate(session.startedAt)}  ·  ${formatDuration(session.durationMs)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: ProductColors.mutedInk,
                    ),
                  ),
                  if (session.anchorCount > 0 ||
                      session.transcriptCount > 0) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        if (session.transcriptCount > 0)
                          _Count(
                            icon: Icons.notes_rounded,
                            value: session.transcriptCount,
                          ),
                        if (session.imageCount > 0)
                          _Count(
                            icon: Icons.photo_camera_outlined,
                            value: session.imageCount,
                          ),
                        if (session.thoughtCount > 0)
                          _Count(
                            icon: Icons.edit_note_rounded,
                            value: session.thoughtCount,
                          ),
                        if (session.bookmarkCount > 0)
                          _Count(
                            icon: Icons.bookmark_border_rounded,
                            value: session.bookmarkCount,
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
    );
  }

  String _semanticLabel() {
    final parts = <String>[
      session.title.isEmpty ? l10n.untitledRecording : session.title,
      sessionStatusLabel(session.status),
      formatSessionDate(session.startedAt),
      l10n.duration856((formatDuration(session.durationMs)).toString()),
      if (session.transcriptCount > 0)
        l10n.transcriptEntries((session.transcriptCount).toString()),
      if (session.imageCount > 0)
        l10n.photos858((session.imageCount).toString()),
      if (session.thoughtCount > 0)
        l10n.notes((session.thoughtCount).toString()),
      if (session.bookmarkCount > 0)
        l10n.highlights((session.bookmarkCount).toString()),
    ];
    return parts.join('，');
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final warning =
        status == SessionStatus.completedWithGaps ||
        status == SessionStatus.interrupted ||
        status == SessionStatus.failed ||
        status == SessionStatus.unknown;
    final active = status.isActive && !warning;
    final background = warning
        ? ProductColors.amberSoft
        : active
        ? const Color(0xFFFBE5E0)
        : ProductColors.forestSoft;
    final foreground = warning
        ? ProductColors.amber
        : active
        ? ProductColors.vermilion
        : ProductColors.forest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        sessionStatusLabel(status),
        style: TextStyle(
          color: foreground,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.value});

  final IconData icon;
  final int value;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: ProductColors.mutedInk),
        const SizedBox(width: 4),
        Text(
          '$value',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: ProductColors.mutedInk),
        ),
      ],
    );
  }
}
