import 'dart:async';

import 'package:momentai/l10n/app_localization.dart';

import 'ai_models.dart';
import 'ai_ports.dart';
import 'ai_provider.dart';
import 'ai_request.dart';

/// Platform-neutral state machine; no recording gateway or widget dependency.
class AiSessionEngine {
  AiSessionEngine({
    required this.sessionId,
    required this.provider,
    required this.credentialStore,
    required this.documentStore,
  }) : document = AiDocument(sessionId, const []);

  final String sessionId;
  final AiProvider provider;
  final AiCredentialStore credentialStore;
  final AiDocumentStore documentStore;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  AiDocument document;
  AiCredentialCatalog catalog = AiCredentialCatalog.empty();
  bool loaded = false;
  bool busy = false;
  bool dirty = false;
  String? loadError;
  String? saveError;
  AiCancellation? _cancellation;
  bool _disposed = false;
  Future<void>? _initialLoad;

  /// Both views join the first read; mounting a view must not replace live state.
  Future<void> ensureLoaded() {
    if (loaded) return Future<void>.value();
    return _initialLoad ??= load().whenComplete(() => _initialLoad = null);
  }

  void _notify() {
    if (!_disposed) _changes.add(null);
  }

  Future<void> load() async {
    if (busy || _disposed) return;
    busy = true;
    loaded = false;
    loadError = null;
    _notify();
    try {
      final values = await Future.wait<Object>([
        documentStore.read(sessionId),
        credentialStore.read(),
      ]);
      final value = values[0] as AiDocument;
      catalog = values[1] as AiCredentialCatalog;
      document = AiDocument(
        sessionId,
        value.runs.map(
          (run) => run.status == AiRunStatus.running
              ? run.withResult(
                  status: AiRunStatus.interrupted,
                  text: run.text,
                  error: l10n.thePreviousGenerationDidNotFinishIt,
                  totalTokens: run.totalTokens,
                )
              : run,
        ),
        conversations: value.conversations,
        consentGrants: value.consentGrants,
      );
      if (!catalog.hasRemoteProcessingConsent &&
          document.consentGrants.any((grant) => grant.scopeVersion == 1)) {
        final migrated = catalog.withRemoteProcessingConsent(granted: true);
        try {
          await credentialStore.save(migrated);
          catalog = migrated;
        } catch (_) {
          // Safe fallback: show the one-time sheet again rather than assuming consent.
        }
      }
      loaded = true;
    } catch (_) {
      loadError = l10n.couldNotReadAiHistoryOrService;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refreshCatalog() async {
    catalog = await credentialStore.read();
    _notify();
  }

  Future<AiPreparedRequest> prepare(
    AiSourceSnapshot source,
    AiRunKind kind, {
    String question = '',
    String? conversationId,
    String? serviceId,
    String? modelProfileId,
  }) async {
    if (!loaded ||
        busy ||
        dirty ||
        _disposed ||
        source.sessionId != sessionId) {
      throw AiFailure(l10n.aiIsProcessingOrDataIsNot);
    }
    catalog = await credentialStore.read();
    final credentials = catalog.resolve(
      kind,
      serviceId: serviceId,
      modelProfileId: modelProfileId,
    );
    return AiPreparedRequest.create(
      credentials: credentials,
      source: source,
      kind: kind,
      document: document,
      question: question,
      conversationId: conversationId,
    );
  }

  bool requiresConsent(AiPreparedRequest _) {
    return !catalog.hasRemoteProcessingConsent;
  }

  /// App-wide consent and the running intent are persisted before contacting the service.
  Future<void> run(AiPreparedRequest request, {required bool consent}) async {
    final needsConsent = requiresConsent(request);
    if ((needsConsent && !consent) ||
        !loaded ||
        busy ||
        dirty ||
        _disposed ||
        request.source.sessionId != sessionId) {
      return;
    }
    if (document.runs.length >= 200) {
      throw AiFailure(l10n.aiHistoryHasReachedItsLimitDelete);
    }
    busy = true;
    saveError = null;
    final cancel = AiCancellation();
    _cancellation = cancel;
    final config = request.credentials.configuration;
    if (needsConsent) {
      try {
        final granted = catalog.withRemoteProcessingConsent(granted: true);
        await credentialStore.save(granted);
        catalog = granted;
      } catch (_) {
        saveError = l10n.couldNotSaveConsentToSendData;
        busy = false;
        _cancellation = null;
        _notify();
        return;
      }
    }
    final run = AiRun(
      id: newAiId(),
      kind: request.kind,
      status: AiRunStatus.running,
      question: request.question,
      text: '',
      sourceFingerprint: request.source.fingerprint,
      textLayer: request.source.textLayer,
      hasGaps: request.source.hasGaps,
      model: config.modelName,
      endpoint: config.endpoint.toString(),
      serviceId: config.serviceId,
      modelProfileId: config.modelProfileId,
      conversationId: request.conversationId,
      createdAt: DateTime.now(),
    );
    final previous = document;
    final now = DateTime.now();
    final conversations = document.conversations.map((conversation) {
      if (conversation.id != request.conversationId) return conversation;
      final title =
          conversation.title == l10n.newConversation &&
              request.question.isNotEmpty
          ? _conversationTitle(request.question)
          : conversation.title;
      return conversation.copyWith(title: title, updatedAt: now);
    }).toList();
    document = AiDocument(
      sessionId,
      [...document.runs, run],
      conversations: conversations,
      consentGrants: document.consentGrants,
    );
    _notify();
    var text = '';
    int? totalTokens;
    var finished = false;
    try {
      await documentStore.save(document);
    } catch (_) {
      document = previous;
      saveError = l10n.couldNotSaveGenerationStatusNothingWas;
      busy = false;
      _cancellation = null;
      _notify();
      return;
    }
    try {
      cancel.check();
      await for (final event in provider.generate(
        request.credentials,
        request.messages,
        cancel,
      )) {
        cancel.check();
        if (text.length + event.text.length > aiMaximumOutputCharacters) {
          throw AiFailure(l10n.theOutputExceedsTheSafetyLimitAnd);
        }
        if (finished) {
          throw AiFailure(l10n.theServiceContinuedSendingDataAfterCompletion);
        }
        text += event.text;
        totalTokens = event.totalTokens ?? totalTokens;
        finished = finished || event.finished;
        _replace(
          run.withResult(
            status: AiRunStatus.running,
            text: text,
            totalTokens: totalTokens,
          ),
        );
      }
      cancel.check();
      if (!finished || text.trim().isEmpty) {
        throw AiFailure(l10n.theResponseDidNotFinishTryAgain);
      }
      _replace(
        run.withResult(
          status: AiRunStatus.complete,
          text: text,
          totalTokens: totalTokens,
        ),
      );
    } catch (error) {
      _replace(
        run.withResult(
          status: cancel.isCancelled
              ? AiRunStatus.interrupted
              : AiRunStatus.failed,
          text: text,
          totalTokens: totalTokens,
          error: error is AiFailure
              ? error.message
              : l10n.generationFailedCheckTheNetworkOrService,
        ),
      );
    } finally {
      dirty = true;
      await _save();
      busy = false;
      _cancellation = null;
      _notify();
    }
  }

  String _conversationTitle(String question) {
    final normalized = question.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 24
        ? normalized
        : '${normalized.substring(0, 24)}…';
  }

  Future<String> createConversation() async {
    if (!loaded || busy || dirty || _disposed) {
      throw AiFailure(l10n.aiIsProcessingWaitBeforeStartingA);
    }
    if (document.conversations.length >= aiMaximumConversations) {
      throw AiFailure(l10n.theConversationLimitHasBeenReachedDelete);
    }
    final now = DateTime.now();
    final conversation = AiConversation(
      id: newAiId(),
      title: l10n.newConversation,
      createdAt: now,
      updatedAt: now,
    );
    final next = AiDocument(
      sessionId,
      document.runs,
      conversations: [...document.conversations, conversation],
      consentGrants: document.consentGrants,
    );
    await _commitEdit(next);
    return conversation.id;
  }

  Future<void> renameConversation(String id, String title) async {
    if (!loaded || busy || dirty || _disposed) {
      throw AiFailure(l10n.aiIsProcessingWaitBeforeStartingA);
    }
    title = title.trim();
    if (title.isEmpty || title.length > 80) {
      throw AiFailure(l10n.conversationTitlesMustContainCharacters);
    }
    final next = AiDocument(
      sessionId,
      document.runs,
      conversations: document.conversations.map(
        (value) => value.id == id
            ? value.copyWith(title: title, updatedAt: DateTime.now())
            : value,
      ),
      consentGrants: document.consentGrants,
    );
    await _commitEdit(next);
  }

  Future<void> deleteConversation(String id) async {
    if (!loaded || busy || dirty || _disposed) return;
    final next = AiDocument(
      sessionId,
      document.runs.where((run) => run.conversationId != id),
      conversations: document.conversations.where((value) => value.id != id),
      consentGrants: document.consentGrants,
    );
    await _commitEdit(next);
  }

  Future<void> _commitEdit(AiDocument next) async {
    busy = true;
    _notify();
    try {
      await documentStore.save(next);
      document = next;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _replace(AiRun value) {
    document = AiDocument(
      sessionId,
      document.runs.map((run) => run.id == value.id ? value : run),
      conversations: document.conversations,
      consentGrants: document.consentGrants,
    );
    _notify();
  }

  void cancel() => _cancellation?.cancel();

  Future<void> _save() async {
    try {
      await documentStore.save(document);
      dirty = false;
      saveError = null;
    } catch (_) {
      saveError = l10n.theResultHasNotBeenSavedCopy;
    }
  }

  Future<void> retrySave() async {
    if (busy || !dirty || _disposed) return;
    busy = true;
    _notify();
    await _save();
    busy = false;
    _notify();
  }

  Future<void> clear(AiRunKind kind) async {
    if (!loaded || busy || dirty || _disposed) return;
    busy = true;
    _notify();
    final next = AiDocument(
      sessionId,
      document.runs.where((run) => run.kind != kind),
      conversations: kind == AiRunKind.chat ? const [] : document.conversations,
      consentGrants: document.consentGrants,
    );
    try {
      await documentStore.save(next);
      document = next;
      dirty = false;
      saveError = null;
    } catch (_) {
      saveError = l10n.couldNotDeleteAiContentExistingContent;
    } finally {
      busy = false;
      _notify();
    }
  }

  void dispose() {
    cancel();
    _disposed = true;
    unawaited(_changes.close());
  }
}
