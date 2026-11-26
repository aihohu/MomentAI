import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../product_theme.dart';

/// Renders untrusted model Markdown without loading embedded resources or
/// automatically navigating to model-provided links.
class AiMarkdownView extends StatelessWidget {
  const AiMarkdownView({super.key, required this.data, this.compact = false});

  final String data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final theme = Theme.of(context);
    return MarkdownBody(
      key: const Key('ai-markdown-content'),
      data: data,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: (compact ? theme.textTheme.bodyMedium : theme.textTheme.bodyLarge)
            ?.copyWith(
              height: compact ? 1.6 : 1.65,
              color: compact ? ProductColors.mutedInk : ProductColors.ink,
            ),
        h1: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
        ),
        h2: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        h3: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        listBullet: theme.textTheme.bodyMedium?.copyWith(
          color: ProductColors.forest,
        ),
        listIndent: compact ? 20 : 24,
        listBulletPadding: const EdgeInsets.only(right: 7),
        code: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          color: ProductColors.ink,
        ),
        codeblockDecoration: BoxDecoration(
          color: ProductColors.line.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
        ),
        blockquoteDecoration: BoxDecoration(
          color: ProductColors.forestSoft,
          border: const Border(
            left: BorderSide(color: ProductColors.forest, width: 3),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      imageBuilder: (_, _, alt) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ProductColors.line.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          l10n.imageInModelOutputWasBlocked(
            (alt?.isNotEmpty == true ? '：$alt' : '').toString(),
          ),
        ),
      ),
      onTapLink: (text, href, _) {
        if (href == null) return;
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.linkProvidedByTheModel),
            content: SelectableText(href),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.close),
              ),
              FilledButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: href));
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: Text(l10n.copyLink),
              ),
            ],
          ),
        );
      },
    );
  }
}
