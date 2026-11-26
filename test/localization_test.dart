import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/models/local_model_manifest.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/l10n/app_localization.dart';
import 'package:momentai/l10n/language_controller.dart';
import 'package:momentai/l10n/language_picker.dart';
import 'package:momentai/product/product_formatters.dart';
import 'package:momentai/product/speaker_localization.dart';
import 'package:momentai/product/speaker_session_text.dart';

class _Store implements LanguagePreferenceStore {
  String? value;
  bool failRead = false;
  bool failWrite = false;
  @override
  Future<String?> read() async {
    if (failRead) throw const FormatException('invalid preference');
    return value;
  }

  @override
  Future<void> write(String language) async {
    if (failWrite) throw const FileSystemException('read only');
    value = language;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => setApplicationLanguage('zh'));

  test(
    'system matching, persistence, and unsupported locale fallback',
    () async {
      var system = const Locale('zh', 'TW');
      final store = _Store();
      final native = <String>[];
      LanguageController create() => LanguageController(
        store: store,
        systemLocale: () => system,
        nativeSync: (value) async => native.add(value),
      );
      final controller = create();
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.locale, const Locale('zh'));
      system = const Locale('fr', 'FR');
      controller.didChangeLocales([system]);
      expect(controller.locale, const Locale('en'));
      expect(l10n.settings, 'Settings');
      await controller.select(AppLanguage.zh);
      system = const Locale('en', 'GB');
      controller.didChangeLocales([system]);
      expect(l10n.settings, '设置');
      final relaunched = create();
      addTearDown(relaunched.dispose);
      await relaunched.initialize();
      expect(relaunched.selection, AppLanguage.zh);
      await relaunched.select(AppLanguage.system);
      expect(relaunched.locale, const Locale('en'));
      expect(native, ['system', 'system', 'zh', 'zh', 'system']);
    },
  );

  test(
    'invalid preferences fall back; failed writes preserve selection',
    () async {
      final store = _Store()..failRead = true;
      final controller = LanguageController(
        store: store,
        systemLocale: () => const Locale('zh'),
        nativeSync: (_) async {},
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      store.failWrite = true;
      await expectLater(
        controller.select(AppLanguage.en),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.selection, AppLanguage.system);
      expect(controller.saving, isFalse);
      expect(l10n.settings, '设置');
    },
  );

  test('language preference survives reopening the on-disk store', () async {
    final root = await Directory.systemTemp.createTemp('momentai-language-');
    addTearDown(() => root.delete(recursive: true));
    FileLanguagePreferenceStore store() =>
        FileLanguagePreferenceStore(supportDirectory: () async => root);
    expect(await store().read(), isNull);
    await store().write('en');
    expect(await store().read(), 'en');
    await store().write('system');
    expect(await store().read(), 'system');
    final file = File('${root.path}/MomentAI/preferences/language.json');
    await file.writeAsString('{corrupt');
    final controller = LanguageController(
      store: store(),
      systemLocale: () => const Locale('zh'),
      nativeSync: (_) async {},
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.selection, AppLanguage.system);
    expect(l10n.settings, '设置');
  });

  test('translated model metadata never changes installation identity', () {
    final model = OfficialLocalModelCatalog.models.firstWhere(
      (m) => m.id == lightweightRealtimeModelId,
    );
    final identity = model.installationName;
    final hash = model.archiveSha256;
    setApplicationLanguage('en');
    expect(model.name, 'Mandarin · Lightweight');
    expect(model.languages, ['Mandarin']);
    expect(model.installationName, identity);
    expect(model.archiveSha256, hash);
    expect(formatSessionDate(DateTime(2026, 9, 20, 14, 5)), 'Sep 20, 14:05');
    setApplicationLanguage('zh');
    expect(formatSessionDate(DateTime(2026, 9, 20, 14, 5)), '9月20日 14:05');
  });

  test(
    'speaker presentation changes while canonical attribution stays identical',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/m2/speaker-text-v1.json',
                ).readAsStringSync(),
              )
              as Map;
      final document = SpeakerDiarizationDocument.fromMap(
        fixture['document'] as Map,
      );
      final before = speakerTextAttribution(
        document: document,
        startSample: 0,
        endSample: 32000,
      );
      final version = speakerTextVersion(document);
      setApplicationLanguage('en');
      expect(localizedSpeakerDefault('speaker_2'), 'Speaker 2');
      expect(
        speakerTextAttribution(
          document: document,
          startSample: 0,
          endSample: 32000,
        ),
        before,
      );
      expect(speakerTextVersion(document), version);
      for (final id in document.speakerIds) {
        final custom = document.labels.names[document.labels.resolve(id)];
        if (custom != null) expect(localizedSpeakerName(document, id), custom);
      }
    },
  );

  test('all supported ARBs have complete matching resources', () {
    final zh =
        jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync()) as Map;
    final en =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
    Set<String> keys(Map data) =>
        data.keys.cast<String>().where((key) => !key.startsWith('@')).toSet();
    expect(keys(en), keys(zh));
    for (final key in keys(zh)) {
      expect((en[key] as String).trim(), isNotEmpty, reason: key);
      final placeholders = RegExp(r'\{(\w+)\}');
      Set<String> arguments(String value) =>
          placeholders.allMatches(value).map((m) => m[1]!).toSet();
      expect(arguments(en[key]), arguments(zh[key]), reason: key);
    }
  });

  testWidgets('language picker preserves route state and supports large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = LanguageController(
      store: _Store(),
      systemLocale: () => const Locale('zh'),
      nativeSync: (_) async {},
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    final field = TextEditingController();
    addTearDown(field.dispose);
    final home = Scaffold(
      body: ListView(
        children: [
          const LanguagePicker(),
          TextField(controller: field),
        ],
      ),
    );
    await tester.pumpWidget(
      LanguageScope(
        controller: controller,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MaterialApp(
            locale: controller.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: home,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留输入 / Keep this');
    final original = tester.state(find.byType(TextField));
    await tester.tap(find.byKey(const Key('app-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
    expect(find.text('App language'), findsOneWidget);
    expect(field.text, '保留输入 / Keep this');
    expect(tester.state(find.byType(TextField)), same(original));
    expect(tester.takeException(), isNull);
  });
}
