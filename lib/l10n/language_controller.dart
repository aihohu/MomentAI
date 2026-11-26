import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app_localization.dart';

enum AppLanguage { system, zh, en }

abstract interface class LanguagePreferenceStore {
  Future<String?> read();
  Future<void> write(String language);
}

class FileLanguagePreferenceStore implements LanguagePreferenceStore {
  FileLanguagePreferenceStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  Future<File> _file() async {
    final root = await _supportDirectory();
    return File('${root.path}/MomentAI/preferences/language.json');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString());
    return data is Map && data['schemaVersion'] == 1
        ? data['language'] as String?
        : null;
  }

  @override
  Future<void> write(String language) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(
      jsonEncode({'schemaVersion': 1, 'language': language}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

class LanguageController extends ChangeNotifier with WidgetsBindingObserver {
  LanguageController({
    LanguagePreferenceStore? store,
    Locale Function()? systemLocale,
    Future<void> Function(String)? nativeSync,
  }) : _store = store ?? FileLanguagePreferenceStore(),
       _systemLocale =
           systemLocale ?? (() => ui.PlatformDispatcher.instance.locale),
       _nativeSync = nativeSync ?? _syncNative;

  final LanguagePreferenceStore _store;
  final Locale Function() _systemLocale;
  final Future<void> Function(String) _nativeSync;
  AppLanguage _selection = AppLanguage.system;
  bool _saving = false;
  bool _observing = false;

  AppLanguage get selection => _selection;
  bool get saving => _saving;
  Locale get locale => resolveAppLocale(
    _selection == AppLanguage.system
        ? _systemLocale()
        : Locale(_selection.name),
  );

  Future<void> initialize() async {
    try {
      final saved = await _store.read();
      _selection = AppLanguage.values.firstWhere(
        (item) => item.name == saved,
        orElse: () => AppLanguage.system,
      );
    } catch (_) {
      _selection = AppLanguage.system;
    }
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    setApplicationLocale(locale);
    await _sync();
    notifyListeners();
  }

  Future<void> select(AppLanguage language) async {
    if (_saving || language == _selection) return;
    _saving = true;
    notifyListeners();
    try {
      await _store.write(language.name);
      _selection = language;
      setApplicationLocale(locale);
      await _sync();
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> _sync() async {
    try {
      await _nativeSync(_selection.name);
    } on MissingPluginException {
      // Widget tests and platforms without native recording support.
    } on PlatformException {
      // The persisted preference is retried on the next launch/locale change.
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (_selection != AppLanguage.system) return;
    setApplicationLocale(locale);
    unawaited(_sync());
    notifyListeners();
  }

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static Future<void> _syncNative(String language) => const MethodChannel(
    'org.hohu.momentai.localization',
  ).invokeMethod<void>('setLanguage', {'language': language});
}

class LanguageScope extends InheritedNotifier<LanguageController> {
  const LanguageScope({
    super.key,
    required LanguageController controller,
    required super.child,
  }) : super(notifier: controller);

  static LanguageController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()?.notifier;
}
