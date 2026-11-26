import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'language_controller.dart';

class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = LanguageScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();
    final strings = context.strings;
    String label(AppLanguage value) => switch (value) {
      AppLanguage.system => strings.languageSystem,
      AppLanguage.zh => strings.languageChinese,
      AppLanguage.en => strings.languageEnglish,
    };
    return Card(
      child: ListTile(
        key: const Key('app-language'),
        leading: const Icon(Icons.language),
        title: Text(strings.appLanguage),
        subtitle: Text(label(controller.selection)),
        trailing: const Icon(Icons.chevron_right),
        enabled: !controller.saving,
        onTap: () async {
          final selected = await showDialog<AppLanguage>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text(strings.appLanguage),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Text(strings.languageDescription),
                ),
                for (final language in AppLanguage.values)
                  SimpleDialogOption(
                    key: ValueKey('language-${language.name}'),
                    onPressed: () => Navigator.pop(context, language),
                    child: Row(
                      children: [
                        Expanded(child: Text(label(language))),
                        if (language == controller.selection)
                          const Icon(Icons.check),
                      ],
                    ),
                  ),
              ],
            ),
          );
          if (selected == null || !context.mounted) return;
          try {
            await controller.select(selected);
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.strings.languageSaveFailed)),
              );
            }
          }
        },
      ),
    );
  }
}
