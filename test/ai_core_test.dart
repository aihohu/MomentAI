import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/ai/ai_models.dart';
import 'package:momentai/core/ai/ai_ports.dart';
import 'package:momentai/core/ai/ai_provider.dart';
import 'package:momentai/core/ai/ai_request.dart';
import 'package:momentai/core/ai/ai_session_engine.dart';
import 'package:momentai/core/ai/ai_storage.dart';
import 'package:momentai/domain/session/session_summary.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/session_ai_source.dart';

void main() {
  test(
    'shared workspace retains chat on disk after summary regeneration and clear',
    () async {
      final directory = await Directory.systemTemp.createTemp('ai-shared-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileAiDocumentStore(directory.path);
      final engine = AiSessionEngine(
        sessionId: 'session_1',
        provider: _Provider(),
        credentialStore: _CredentialStore(_catalog()),
        documentStore: store,
      );
      addTearDown(engine.dispose);
      await Future.wait([engine.ensureLoaded(), engine.ensureLoaded()]);
      final source = _source('record text');
      await engine.run(
        await engine.prepare(source, AiRunKind.summary),
        consent: true,
      );
      await engine.ensureLoaded();
      final id = await engine.createConversation();
      await engine.run(
        await engine.prepare(
          source,
          AiRunKind.chat,
          question: 'question',
          conversationId: id,
        ),
        consent: true,
      );
      await engine.ensureLoaded();
      await engine.run(
        await engine.prepare(source, AiRunKind.summary),
        consent: true,
      );
      var saved = await store.read('session_1');
      expect(saved.runs.length, 3);
      expect(saved.conversations.single.id, id);
      await engine.clear(AiRunKind.summary);
      saved = await store.read('session_1');
      expect(saved.runs.single.kind, AiRunKind.chat);
      expect(saved.conversations.single.id, id);
    },
  );

  test('AI network connection timeout allows slow TLS establishment', () {
    expect(aiConnectionTimeout, const Duration(seconds: 60));
  });

  group('AI request boundary', () {
    test(
      'accepts only bounded HTTPS configuration and normalizes endpoint',
      () {
        final configuration = AiConfiguration(
          baseUrl: ' https://api.example.test/v1/// ',
          model: 'model-1',
        );
        expect(
          configuration.endpoint.toString(),
          'https://api.example.test/v1/chat/completions',
        );
        for (final address in [
          'http://api.example.test/v1',
          'https://key@api.example.test/v1',
          'https://api.example.test/v1?key=secret',
        ]) {
          expect(
            () => AiConfiguration(baseUrl: address, model: 'model-1'),
            throwsA(isA<AiFailure>()),
          );
        }
      },
    );

    test(
      'uses complete current text and only six same-version successful turns',
      () {
        final source = _source('当前精修全文');
        final runs = <AiRun>[
          _run('stale', sourceFingerprint: _source('旧文字').fingerprint),
          _run(
            'failed',
            sourceFingerprint: source.fingerprint,
            status: AiRunStatus.failed,
          ),
          for (var index = 0; index < 8; index++)
            _run('$index', sourceFingerprint: source.fingerprint),
        ];
        final request = AiPreparedRequest.create(
          credentials: _credentials(),
          source: source,
          kind: AiRunKind.chat,
          document: AiDocument(
            'session_1',
            runs,
            conversations: [_conversation()],
          ),
          question: '现在的结论？',
          conversationId: 'conversation-1',
        );
        expect(request.historyCount, 6);
        expect(request.omittedHistoryCount, 4);
        expect(request.preview, contains('当前精修全文'));
        expect(request.preview, isNot(contains('旧文字')));
        expect(
          request.messages.any((message) => message.content == '问题 0'),
          isFalse,
        );
        expect(
          request.messages.any((message) => message.content == '问题 2'),
          isTrue,
        );
        expect(request.preview, isNot(contains(_credentials().apiKey)));
      },
    );

    test('keeps complete long input without an app context cap', () {
      final text = '${List.filled(130000, '字').join()}结束标记';
      final request = AiPreparedRequest.create(
        credentials: _credentials(),
        source: _source(text),
        kind: AiRunKind.summary,
        document: AiDocument('session_1', const []),
      );
      expect(request.characterCount, greaterThan(120000));
      expect(
        request.messages.any((message) => message.content.contains('结束标记')),
        isTrue,
      );
    });

    test('summary requests the stable editorial Markdown structure', () {
      final request = AiPreparedRequest.create(
        credentials: _credentials(),
        source: _source('待总结的记录'),
        kind: AiRunKind.summary,
        document: AiDocument('session_1', const []),
      );
      final instruction = request.messages.last.content;
      expect(instruction, contains('## 一句话结论'));
      expect(instruction, contains('## 简短概览'));
      expect(instruction, contains('## 关键要点'));
      expect(instruction, contains('## 主要结论'));
      expect(aiPromptVersion, 4);
    });
  });

  group('Chat Completions stream', () {
    test('parses split SSE text, usage and normal stop', () async {
      final transport = _Transport(
        200,
        'text/event-stream',
        _chunks([
          'data: {"choices":[{"index":0,"delta":{"content":"你"},"finish_reason":null}]}\n\n',
          'data: {"choices":[{"index":0,"delta":{"content":"好"},"finish_reason":"stop"}]}\n\n',
          'data: {"choices":[],"usage":{"total_tokens":19}}\n\ndata: [DONE]\n\n',
        ], splitBytes: true),
      );
      final provider = ChatCompletionsAiProvider(
        transportFactory: () => transport,
        idleTimeout: const Duration(seconds: 1),
      );
      final events = await provider.generate(_credentials(), const [
        AiMessage('user', 'test'),
      ], AiCancellation()).toList();
      expect(events.map((event) => event.text).join(), '你好');
      expect(
        events.where((event) => event.totalTokens != null).single.totalTokens,
        19,
      );
      expect(events.last.finished, isTrue);
      expect(transport.requestBody, isNot(contains('test-key')));
      final body = jsonDecode(transport.requestBody!) as Map<String, dynamic>;
      expect(body, isNot(contains('max_tokens')));
      expect(body, isNot(contains('max_completion_tokens')));
      expect(
        transport.headers?[HttpHeaders.authorizationHeader],
        'Bearer test-key',
      );
      expect(transport.closed, isTrue);
    });

    test(
      'rejects redirects and incomplete streams without exposing body',
      () async {
        final transport = _Transport(
          302,
          'text/plain',
          _chunks(['secret server body']),
        );
        final provider = ChatCompletionsAiProvider(
          transportFactory: () => transport,
        );
        expect(
          provider
              .generate(_credentials(), const [], AiCancellation())
              .toList(),
          throwsA(
            isA<AiFailure>().having(
              (error) => error.message,
              'message',
              allOf(contains('拒绝转发'), isNot(contains('secret'))),
            ),
          ),
        );

        final incomplete = ChatCompletionsAiProvider(
          transportFactory: () => _Transport(
            200,
            'text/event-stream',
            _chunks([
              'data: {"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}\n\n',
            ]),
          ),
        );
        expect(
          incomplete
              .generate(_credentials(), const [], AiCancellation())
              .toList(),
          throwsA(
            isA<AiFailure>().having(
              (error) => error.message,
              'message',
              contains('不完整'),
            ),
          ),
        );
      },
    );
  });

  group('Anthropic Messages stream', () {
    test('uses Anthropic auth, top-level system and named SSE events', () async {
      final transport = _Transport(
        200,
        'text/event-stream',
        _chunks([
          'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":7}}}\n\n',
          'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}\n\n',
          'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}\n\n',
          'event: message_stop\ndata: {"type":"message_stop"}\n\n',
        ], splitBytes: true),
      );
      final provider = AnthropicMessagesAiProvider(
        transportFactory: () => transport,
        idleTimeout: const Duration(seconds: 1),
      );
      final events = await provider.generate(_anthropicCredentials(), const [
        AiMessage('system', '系统规则'),
        AiMessage('user', '问题'),
      ], AiCancellation()).toList();
      expect(events.map((event) => event.text).join(), '你好');
      expect(events.last.finished, isTrue);
      expect(events.last.totalTokens, 10);
      expect(transport.headers?['x-api-key'], 'anthropic-test-key');
      expect(
        transport.headers,
        isNot(contains(HttpHeaders.authorizationHeader)),
      );
      final body = jsonDecode(transport.requestBody!) as Map<String, dynamic>;
      expect(body['system'], '系统规则');
      expect(body['max_tokens'], 2048);
      expect(
        (body['messages'] as List).any(
          (value) => (value as Map)['role'] == 'system',
        ),
        isFalse,
      );
    });
  });

  group('AI persistence and engine', () {
    test(
      'file store is additive, atomic and never recreates deleted session',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'momentai-ai-test.',
        );
        addTearDown(() async {
          if (await directory.exists()) await directory.delete(recursive: true);
        });
        final fact = File('${directory.path}/session.json');
        await fact.writeAsString('frozen fact');
        final store = FileAiDocumentStore(directory.path);
        final document = AiDocument(
          'session_1',
          [_run('saved', sourceFingerprint: _source('text').fingerprint)],
          conversations: [_conversation()],
        );
        await store.save(document);
        final read = await store.read('session_1');
        expect(read.runs.single.question, '问题 saved');
        expect(await fact.readAsString(), 'frozen fact');
        expect(
          directory.listSync().where((entry) => entry.path.endsWith('.part')),
          isEmpty,
        );
        await directory.delete(recursive: true);
        await expectLater(store.save(document), throwsA(isA<AiFailure>()));
        expect(await directory.exists(), isFalse);
      },
    );

    test(
      'persists one app-wide consent before calls and reuses it across records',
      () async {
        final provider = _Provider();
        final store = _MemoryDocumentStore();
        final credentials = _CredentialStore(_catalog());
        final engine = AiSessionEngine(
          sessionId: 'session_1',
          provider: provider,
          credentialStore: credentials,
          documentStore: store,
        );
        await engine.load();
        final request = await engine.prepare(
          _source('record text'),
          AiRunKind.summary,
        );
        await engine.run(request, consent: false);
        expect(provider.calls, 0);
        await engine.run(request, consent: true);
        expect(provider.calls, 1);
        expect(store.saved.first.runs.single.status, AiRunStatus.running);
        expect(engine.document.runs.single.status, AiRunStatus.complete);
        expect(store.saved.last.runs.single.text, '模拟结果');
        expect(credentials.value.hasRemoteProcessingConsent, isTrue);
        engine.dispose();

        final secondEngine = AiSessionEngine(
          sessionId: 'session_2',
          provider: provider,
          credentialStore: credentials,
          documentStore: _MemoryDocumentStore(),
        );
        await secondEngine.load();
        final secondRequest = await secondEngine.prepare(
          AiSourceSnapshot(
            sessionId: 'session_2',
            title: '第二条记录',
            text: 'another record',
            textLayer: '实时原文',
            hasGaps: false,
          ),
          AiRunKind.summary,
        );
        expect(secondEngine.requiresConsent(secondRequest), isFalse);
        await secondEngine.run(secondRequest, consent: false);
        expect(provider.calls, 2);
        secondEngine.dispose();
      },
    );

    test(
      'migrates an existing record consent into the app-wide grant',
      () async {
        final credentials = _CredentialStore(_catalog());
        final store = _MemoryDocumentStore(
          initial: AiDocument(
            'session_1',
            const [],
            consentGrants: [
              AiConsentGrant(
                serviceId: 'service-1',
                serviceRevision: 1,
                grantedAt: DateTime.utc(2026, 9, 1),
              ),
            ],
          ),
        );
        final engine = AiSessionEngine(
          sessionId: 'session_1',
          provider: _Provider(),
          credentialStore: credentials,
          documentStore: store,
        );
        await engine.load();
        expect(credentials.value.hasRemoteProcessingConsent, isTrue);
        expect(engine.catalog.hasRemoteProcessingConsent, isTrue);
        engine.dispose();
      },
    );

    test('storage failure before request prevents network call', () async {
      final provider = _Provider();
      final store = _MemoryDocumentStore(failSave: true);
      final engine = AiSessionEngine(
        sessionId: 'session_1',
        provider: provider,
        credentialStore: _CredentialStore(_catalog()),
        documentStore: store,
      );
      await engine.load();
      final request = await engine.prepare(
        _source('record text'),
        AiRunKind.summary,
      );
      await engine.run(request, consent: true);
      expect(provider.calls, 0);
      expect(engine.document.runs, isEmpty);
      expect(engine.saveError, contains('本次未发送'));
      engine.dispose();
    });

    test('consent storage failure prevents network call', () async {
      final provider = _Provider();
      final engine = AiSessionEngine(
        sessionId: 'session_1',
        provider: provider,
        credentialStore: _CredentialStore(_catalog(), failSave: true),
        documentStore: _MemoryDocumentStore(),
      );
      await engine.load();
      final request = await engine.prepare(
        _source('record text'),
        AiRunKind.summary,
      );
      await engine.run(request, consent: true);
      expect(provider.calls, 0);
      expect(engine.document.runs, isEmpty);
      expect(engine.saveError, contains('本次未发送'));
      engine.dispose();
    });
  });

  test('canonical source records chosen text version and gap state', () {
    final snapshot = sessionAiSource(
      session: _summary(),
      timeline: [
        TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'seg',
          'sampleOffset': 0,
          'endSample': 16000,
          'text': '实时原文',
        }),
      ],
      refinement: const FullTextRefinementSnapshot.unavailable(),
    );
    expect(snapshot.text, '实时原文');
    expect(snapshot.textLayer, '实时原文');
    expect(snapshot.hasGaps, isTrue);
    expect(snapshot.fingerprint, isNot(_source('实时原文').fingerprint));
  });
}

AiCredentials _credentials() => AiCredentials(
  AiConfiguration(baseUrl: 'https://api.example.test/v1', model: 'model-1'),
  'test-key',
);

AiCredentials _anthropicCredentials() {
  final model = AiModelProfile(
    id: 'anthropic-model',
    name: 'Claude',
    modelId: 'claude-test',
    outputTokenLimit: 2048,
  );
  final service = AiServiceProfile(
    id: 'anthropic-service',
    name: 'Anthropic',
    apiKind: AiApiKind.anthropic,
    baseUrl: 'https://api.anthropic.test',
    models: [model],
  );
  return AiCredentials(
    AiConfiguration.fromProfiles(service, model),
    'anthropic-test-key',
  );
}

AiCredentialCatalog _catalog() {
  final model = AiModelProfile(
    id: 'model-profile-1',
    name: 'Model 1',
    modelId: 'model-1',
  );
  final service = AiServiceCredentials(
    AiServiceProfile(
      id: 'service-1',
      name: 'Test Service',
      apiKind: AiApiKind.openAiCompatible,
      baseUrl: 'https://api.example.test/v1',
      models: [model],
    ),
    'test-key',
  );
  return AiCredentialCatalog(
    services: [service],
    defaultSummaryServiceId: service.service.id,
    defaultSummaryModelId: model.id,
    defaultChatServiceId: service.service.id,
    defaultChatModelId: model.id,
  );
}

AiSourceSnapshot _source(String text) => AiSourceSnapshot(
  sessionId: 'session_1',
  title: '访谈',
  text: text,
  textLayer: '精修文字',
  hasGaps: false,
);

AiRun _run(
  String id, {
  required String sourceFingerprint,
  AiRunStatus status = AiRunStatus.complete,
}) => AiRun(
  id: id,
  kind: AiRunKind.chat,
  status: status,
  question: '问题 $id',
  text: '回答 $id',
  sourceFingerprint: sourceFingerprint,
  textLayer: '精修文字',
  hasGaps: false,
  model: 'model-1',
  endpoint: 'https://api.example.test/v1/chat/completions',
  conversationId: 'conversation-1',
  createdAt: DateTime.utc(2026, 9, 1),
);

AiConversation _conversation() => AiConversation(
  id: 'conversation-1',
  title: '测试对话',
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
);

SessionSummary _summary() => SessionSummary(
  sessionId: 'session_1',
  directory: '/unused',
  title: '访谈',
  status: SessionStatus.completedWithGaps,
  startedAt: DateTime.utc(2026, 9, 1),
  durationSamples: 16000,
  durationMs: 1000,
  chunkCount: 1,
  transcriptCount: 1,
  imageCount: 0,
  thoughtCount: 0,
  bookmarkCount: 0,
  recoveryCount: 0,
  hasConfirmedGaps: true,
  exportAvailable: true,
);

Stream<List<int>> _chunks(
  List<String> values, {
  bool splitBytes = false,
}) async* {
  for (final value in values) {
    final bytes = utf8.encode(value);
    if (splitBytes && bytes.length > 3) {
      yield bytes.sublist(0, 3);
      yield bytes.sublist(3);
    } else {
      yield bytes;
    }
  }
}

class _Transport implements AiHttpTransport {
  _Transport(this.status, this.contentType, this.stream);
  final int status;
  final String contentType;
  final Stream<List<int>> stream;
  String? requestBody;
  Map<String, String>? headers;
  bool closed = false;
  @override
  Future<AiHttpResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    this.headers = headers;
    requestBody = body;
    return AiHttpResponse(status, contentType, stream);
  }

  @override
  void close() => closed = true;
}

class _CredentialStore implements AiCredentialStore {
  _CredentialStore(this.value, {this.failSave = false});
  AiCredentialCatalog value;
  final bool failSave;
  @override
  Future<AiCredentialCatalog> read() async => value;
  @override
  Future<void> save(AiCredentialCatalog catalog) async {
    if (failSave) throw const AiFailure('secure storage');
    value = catalog;
  }

  @override
  Future<void> delete() async => value = AiCredentialCatalog.empty();
}

class _MemoryDocumentStore implements AiDocumentStore {
  _MemoryDocumentStore({this.failSave = false, this.initial});
  final bool failSave;
  final AiDocument? initial;
  final saved = <AiDocument>[];
  @override
  Future<AiDocument> read(String sessionId) async =>
      initial ?? AiDocument(sessionId, const []);
  @override
  Future<void> save(AiDocument document) async {
    if (failSave) throw const AiFailure('disk');
    saved.add(
      AiDocument(
        document.sessionId,
        document.runs,
        conversations: document.conversations,
        consentGrants: document.consentGrants,
      ),
    );
  }
}

class _Provider implements AiProvider {
  int calls = 0;
  @override
  Stream<AiStreamEvent> generate(
    AiCredentials credentials,
    List<AiMessage> messages,
    AiCancellation cancellation,
  ) async* {
    calls++;
    cancellation.check();
    yield const AiStreamEvent(text: '模拟结果');
    yield const AiStreamEvent(finished: true, totalTokens: 12);
  }
}
