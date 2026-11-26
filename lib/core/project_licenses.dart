import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Adds project, model, and native notices to Flutter's offline license viewer.
void registerProjectLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(loadProjectLicenses);
}

Stream<LicenseEntry> loadProjectLicenses() async* {
  final notices =
      jsonDecode(await rootBundle.loadString('assets/legal/notices.json'))
          as Map<String, dynamic>;
  for (final entry in notices.entries) {
    // Upstream notices contain tabs and Unicode indentation that Flutter's
    // paragraph parser cannot handle. Keep original files; normalize display only.
    final displayText = (entry.value as String)
        .split('\n')
        .map((line) => line.trimLeft())
        .join('\n');
    yield LicenseEntryWithLineBreaks([entry.key], displayText);
  }
}
