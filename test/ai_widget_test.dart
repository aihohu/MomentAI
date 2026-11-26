import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/ai/ai_models.dart';
import 'package:momentai/core/ai/ai_ports.dart';
import 'package:momentai/core/ai/ai_provider.dart';
import 'package:momentai/core/ai/ai_request.dart';
import 'package:momentai/core/ai/ai_session_engine.dart';
import 'package:momentai/l10n/app_localization.dart';
import 'package:momentai/product/ai_services.dart';
import 'package:momentai/product/pages/ai_settings_page.dart';
import 'package:momentai/product/pages/session_ai_page.dart';

void main() {
  testWidgets(
    'summary and chat retain history across navigation and clearing',
    (tester) async {
      final store = _DocumentStore();
      final services = AiServices(
        credentials: _CredentialStore(
          _catalog().withRemoteProcessingConsent(granted: true),
        ),
        provider: _Provider(),
        documentStore: (_) => store,
      );
      final engine = AiSessionEngine(
        sessionId: 'session_1',
        provider: services.provider,
        credentialStore: services.credentials,
        documentStore: store,
      );
      addTearDown(engine.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: ListView(
              children: [
                SessionAiSummaryPane(
                  sessionId: 'session_1',
                  services: services,
                  store: store,
                  engine: engine,
                  loadSource: _source,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('ai-generate')));
      await tester.tap(find.byKey(const Key('ai-generate')));
      await tester.pumpAndSettle();
      expect(engine.document.runs.length, 1);
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => SessionAiPage(
              sessionId: 'session_1',
              services: services,
              store: store,
              engine: engine,
              loadSource: _source,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ai-question')), '保留这段对话');
      await tester.tap(find.byKey(const Key('ai-generate')));
      await tester.pumpAndSettle();
      final chatId = engine.document.conversations.single.id;
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.summaryActions));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.regenerate));
      await tester.pumpAndSettle();
      var saved = await store.read('session_1');
      expect(saved.runs.where((r) => r.kind == AiRunKind.summary).length, 2);
      expect(
        saved.runs.where((r) => r.kind == AiRunKind.chat).single.question,
        '保留这段对话',
      );
      expect(saved.conversations.single.id, chatId);
      await tester.tap(find.byTooltip(l10n.summaryActions));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.deleteSummary));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ai-confirm-clear')));
      await tester.pumpAndSettle();
      saved = await store.read('session_1');
      expect(saved.runs.single.kind, AiRunKind.chat);
      expect(saved.conversations.single.id, chatId);
      await tester.pumpWidget(const SizedBox());
      // Unmounting either view leaves the record-owned workspace available.
      await engine.renameConversation(chatId, '仍可编辑');
      expect(
        (await store.read('session_1')).conversations.single.title,
        '仍可编辑',
      );
    },
  );

  testWidgets(
    'English summary UI reads saved Chinese sections without rewriting content',
    (tester) async {
      setApplicationLanguage('en');
      addTearDown(() => setApplicationLanguage('zh'));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final source = await _source();
      final store = _DocumentStore();
      const saved =
          '## 一句话结论\n保留历史中文内容\n## 简短概览\n原始概览\n## 关键要点\n- 原始要点\n## 主要结论\n- 原始结论';
      store.document = AiDocument('session_1', [
        AiRun(
          id: 'saved',
          kind: AiRunKind.summary,
          status: AiRunStatus.complete,
          question: '',
          text: saved,
          sourceFingerprint: source.fingerprint,
          textLayer: source.textLayer,
          hasGaps: source.hasGaps,
          model: 'model-1',
          endpoint: 'https://api.example.test/v1',
          createdAt: DateTime.utc(2026, 9, 20),
        ),
      ]);
      final provider = _Provider();
      final services = AiServices(
        credentials: _CredentialStore(_catalog()),
        provider: provider,
        documentStore: (_) => store,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ListView(
              children: [
                SessionAiSummaryPane(
                  sessionId: 'session_1',
                  services: services,
                  store: store,
                  loadSource: _source,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-summary-structured')), findsOneWidget);
      expect(find.text('保留历史中文内容'), findsOneWidget);
      expect(store.document.runs.single.text, saved);
      expect(provider.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'speaker source update marks an existing summary stale without a network call',
    (tester) async {
      final store = _DocumentStore();
      final provider = _Provider();
      final old = await _source();
      var current = old;
      store.document = AiDocument('session_1', [
        AiRun(
          id: 'summary-old',
          kind: AiRunKind.summary,
          status: AiRunStatus.complete,
          question: '',
          text: '已保存总结',
          sourceFingerprint: old.fingerprint,
          textLayer: old.textLayer,
          hasGaps: old.hasGaps,
          model: 'model-1',
          endpoint: 'https://api.example.test/v1',
          createdAt: DateTime.utc(2026, 9, 10),
        ),
      ]);
      final services = AiServices(
        credentials: _CredentialStore(_catalog()),
        provider: provider,
        documentStore: (_) => store,
      );
      Widget page(String revision) => MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SessionAiSummaryPane(
                sessionId: 'session_1',
                services: services,
                store: store,
                loadSource: () async => current,
                sourceVersion: revision,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page('before'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这是旧版本总结'), findsNothing);
      current = AiSourceSnapshot(
        sessionId: old.sessionId,
        title: old.title,
        text: old.text,
        textLayer: old.textLayer,
        hasGaps: old.hasGaps,
        speakerText: const {'speakerVersion': 'after-rename'},
      );
      await tester.pumpWidget(page('after'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这是旧版本总结'), findsOneWidget);
      expect(provider.calls, 0);
      expect(store.document.runs.single.text, '已保存总结');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'record chat asks once per app, renders Markdown and keeps history',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final credentials = _CredentialStore(_catalog());
      final provider = _Provider();
      final store = _DocumentStore();
      final services = AiServices(
        credentials: credentials,
        provider: provider,
        documentStore: (_) => store,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SessionAiPage(
            sessionId: 'session_1',
            services: services,
            store: store,
            loadSource: _source,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ai-gap-warning')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ai-question')), '主要结论是什么？');
      await tester.tap(find.byKey(const Key('ai-generate')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('api.example.test/v1/chat/completions'),
        findsOneWidget,
      );
      expect(find.textContaining('不发送音频、图片、随想或 API Key'), findsOneWidget);
      expect(provider.calls, 0);
      await tester.ensureVisible(find.byKey(const Key('ai-cancel-consent')));
      await tester.tap(find.byKey(const Key('ai-cancel-consent')));
      await tester.pumpAndSettle();
      expect(provider.calls, 0);

      await tester.tap(find.byKey(const Key('ai-generate')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(find.byKey(const Key('ai-confirm-send')));
      await tester.tap(find.byKey(const Key('ai-confirm-send')));
      await tester.pumpAndSettle();
      expect(provider.calls, 1);
      expect(find.text('模拟 AI 结果'), findsOneWidget);
      expect(find.text('- 要点'), findsNothing);
      expect(store.document.runs.single.status, AiRunStatus.complete);
      expect(store.document.conversations.single.title, '主要结论是什么？');

      await tester.enterText(find.byKey(const Key('ai-question')), '第二个问题');
      await tester.tap(find.byKey(const Key('ai-generate')));
      await tester.pumpAndSettle();
      expect(provider.calls, 2);
      expect(find.byKey(const Key('ai-confirm-send')), findsNothing);
      expect(store.document.runs.length, 2);

      await tester.tap(find.byKey(const Key('ai-chat-model-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ai-new-chat')));
      await tester.pumpAndSettle();
      expect(store.document.conversations.length, 2);
      await tester.tap(find.byKey(const Key('ai-chat-history')));
      await tester.pumpAndSettle();
      expect(find.text('对话历史'), findsOneWidget);
      expect(find.text('主要结论是什么？'), findsOneWidget);
      expect(find.byTooltip('对话操作'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chat composer avoids keyboard and offers explicit dismissal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final store = _DocumentStore();
    await tester.pumpWidget(
      MaterialApp(
        home: SessionAiPage(
          sessionId: 'session_1',
          services: AiServices(
            credentials: _CredentialStore(_catalog()),
            provider: _Provider(),
            documentStore: (_) => store,
          ),
          store: store,
          loadSource: _source,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final question = find.byKey(const Key('ai-question'));
    await tester.tap(question);
    await tester.enterText(question, '键盘避让测试');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final composer = tester.getRect(find.byKey(const Key('ai-chat-composer')));
    expect(composer.bottom, lessThanOrEqualTo(844 - 300));
    expect(find.byKey(const Key('ai-dismiss-keyboard')), findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: question, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const Key('ai-dismiss-keyboard')));
    await tester.pump();
    expect(editable.focusNode.hasFocus, isFalse);
  });

  testWidgets('summary pane is independent and reuses app-wide consent', (
    tester,
  ) async {
    final credentials = _CredentialStore(_catalog());
    final provider = _Provider();
    final store = _DocumentStore();
    final services = AiServices(
      credentials: credentials,
      provider: provider,
      documentStore: (_) => store,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SessionAiSummaryPane(
                sessionId: 'session_1',
                services: services,
                store: store,
                loadSource: _source,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-generate')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.byKey(const Key('ai-confirm-send')));
    await tester.tap(find.byKey(const Key('ai-confirm-send')));
    await tester.pumpAndSettle();
    expect(provider.calls, 1);
    expect(find.byKey(const Key('ai-markdown-content')), findsOneWidget);
  });

  testWidgets('structured summary follows the approved editorial hierarchy', (
    tester,
  ) async {
    final credentials = _CredentialStore(_catalog());
    final provider = _Provider(
      response:
          '## 一句话结论\n先完成 AI 验收。\n\n'
          '## 简短概览\n这是一段简短概览。\n\n'
          '## 关键要点\n- 要点一\n- 要点二\n\n'
          '## 主要结论\n- 结论一',
    );
    final store = _DocumentStore();
    final services = AiServices(
      credentials: credentials,
      provider: provider,
      documentStore: (_) => store,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SessionAiSummaryPane(
                sessionId: 'session_1',
                services: services,
                store: store,
                loadSource: _source,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-generate')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.byKey(const Key('ai-confirm-send')));
    await tester.tap(find.byKey(const Key('ai-confirm-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-summary-structured')), findsOneWidget);
    expect(find.text('先完成 AI 验收。'), findsOneWidget);
    expect(find.text('2 项要点'), findsOneWidget);
    expect(find.text('1 项结论'), findsOneWidget);
  });

  testWidgets(
    'multi-service settings keep key hidden and editor avoids cover',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = _CredentialStore(_catalog());
      final services = AiServices(
        credentials: store,
        provider: _Provider(),
        documentStore: (_) => _DocumentStore(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AiSettingsPage(services: services)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2 个模型'), findsOneWidget);
      expect(find.byTooltip('服务操作'), findsNothing);

      await tester.tap(find.text('Test Service'));
      await tester.pumpAndSettle();
      final keyField = tester.widget<TextField>(
        find.byKey(const Key('ai-api-key')),
      );
      expect(keyField.controller?.text, isEmpty);
      expect(find.textContaining('已保存，留空保留'), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ai-base-url')),
        'https://other.example.test/v1',
      );
      await tester.tap(find.byKey(const Key('ai-save-settings')));
      await tester.pumpAndSettle();
      expect(find.textContaining('服务地址或协议已改变，请重新输入 API Key'), findsOneWidget);
      expect(
        store.value.services.single.service.baseUrl,
        'https://api.example.test/v1',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('model compatibility fields remain usable at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      MaterialApp(
        home: AiModelEditorPage(
          apiKind: AiApiKind.openAiCompatible,
          existing: AiModelProfile(
            id: 'model-1',
            name: 'DeepSeek V4 Flash',
            modelId: 'deepseek-v4-flash',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('兼容设置'));
    await tester.pumpAndSettle();

    expect(find.text('完整输入字符上限'), findsNothing);
    expect(find.text('单次回答 Token 预算'), findsOneWidget);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('ai-include-usage')),
      180,
      scrollable: scrollable,
    );
    await tester.drag(
      find.byKey(const Key('ai-model-editor-scroll')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('ai-include-usage')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('ai-output-limit')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('ai-save-model')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<AiSourceSnapshot> _source() async => AiSourceSnapshot(
  sessionId: 'session_1',
  title: '缺口访谈',
  text: '这是待总结的完整原文。',
  textLayer: '精修文字',
  hasGaps: true,
);

AiCredentialCatalog _catalog() {
  final models = [
    AiModelProfile(id: 'model-1', name: '模型一', modelId: 'model-1'),
    AiModelProfile(id: 'model-2', name: '模型二', modelId: 'model-2'),
  ];
  final credentials = AiServiceCredentials(
    AiServiceProfile(
      id: 'service-1',
      name: 'Test Service',
      apiKind: AiApiKind.openAiCompatible,
      baseUrl: 'https://api.example.test/v1',
      models: models,
    ),
    'test-key',
  );
  return AiCredentialCatalog(
    services: [credentials],
    defaultSummaryServiceId: credentials.service.id,
    defaultSummaryModelId: models.first.id,
    defaultChatServiceId: credentials.service.id,
    defaultChatModelId: models.first.id,
  );
}

class _CredentialStore implements AiCredentialStore {
  _CredentialStore(this.value);
  AiCredentialCatalog value;
  @override
  Future<AiCredentialCatalog> read() async => value;
  @override
  Future<void> save(AiCredentialCatalog catalog) async => value = catalog;
  @override
  Future<void> delete() async => value = AiCredentialCatalog.empty();
}

class _DocumentStore implements AiDocumentStore {
  AiDocument document = AiDocument('session_1', const []);
  @override
  Future<AiDocument> read(String sessionId) async => document;
  @override
  Future<void> save(AiDocument value) async => document = value;
}

class _Provider implements AiProvider {
  _Provider({this.response = '# 模拟 AI 结果\n\n- 要点'});

  final String response;
  int calls = 0;
  @override
  Stream<AiStreamEvent> generate(
    AiCredentials credentials,
    List<AiMessage> messages,
    AiCancellation cancellation,
  ) async* {
    calls++;
    cancellation.check();
    yield AiStreamEvent(text: response);
    yield const AiStreamEvent(finished: true, totalTokens: 9);
  }
}
