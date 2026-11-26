import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

// Presentation helpers and service messages use the same locale as the app.
// Kept independent of widgets/storage so worker isolates can import this safely.
// Persisted recording content and archive contracts must not use this accessor.
Locale _applicationLocale = const Locale('zh');
AppLocalizations _strings = lookupAppLocalizations(_applicationLocale);
AppLocalizations get l10n => _strings;
Locale get applicationLocale => _applicationLocale;

Locale resolveAppLocale(Locale locale) =>
    AppLocalizations.supportedLocales.firstWhere(
      (supported) => supported.languageCode == locale.languageCode,
      orElse: () => const Locale('en'),
    );

void setApplicationLanguage(String language) =>
    setApplicationLocale(Locale(language));

void setApplicationLocale(Locale locale) {
  _applicationLocale = resolveAppLocale(locale);
  _strings = lookupAppLocalizations(_applicationLocale);
}

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get strings =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ?? l10n;
}
