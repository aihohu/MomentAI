import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
// ignore_for_file: prefer_initializing_formals
import 'package:momentai/l10n/app_localization.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_ports.dart';
import '../../core/ai/ai_request.dart';
import '../../core/ai/ai_session_engine.dart';
import '../ai_services.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import '../widgets/ai_markdown_view.dart';
import 'ai_settings_page.dart';

class SessionAiSummaryPane extends StatefulWidget {
  const SessionAiSummaryPane({
    super.key,
    required this.sessionId,
    required this.services,
    required this.store,
    this.engine,
    required this.loadSource,
    this.onBusyChanged,
    this.sourceVersion = '',
  });
  final String sessionId;
  final AiServices services;
  final AiDocumentStore store;

  /// Owned by the record page when summary and chat share a workspace.
  final AiSessionEngine? engine;
  final Future<AiSourceSnapshot> Function() loadSource;
  final ValueChanged<bool>? onBusyChanged;
  final String sourceVersion;

  @override
  State<SessionAiSummaryPane> createState() => _SessionAiSummaryPaneState();
}

class _SessionAiSummaryPaneState extends State<SessionAiSummaryPane> {
  late final AiSessionEngine _engine;
  StreamSubscription<void>? _subscription;
  AiSourceSnapshot? _source;
  _AiModelOption? _selectedModel;
  var _preparing = false;
  String? _error;
  int _sourceRefresh = 0;

  @override
  void didUpdateWidget(covariant SessionAiSummaryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceVersion != widget.sourceVersion) {
      unawaited(_refreshSource());
    }
  }

  Future<void> _refreshSource() async {
    final revision = ++_sourceRefresh;
    try {
      final source = await widget.loadSource();
      if (mounted && revision == _sourceRefresh) {
        setState(() => _source = source);
      }
    } catch (error) {
      if (mounted && revision == _sourceRefresh) {
        setState(() => _error = l10n.couldNotReadTheRecordingSourceTry);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _engine =
        widget.engine ??
        AiSessionEngine(
          sessionId: widget.sessionId,
          provider: widget.services.provider,
          credentialStore: widget.services.credentials,
          documentStore: widget.store,
        );
    _subscription = _engine.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    await _engine.ensureLoaded();
    try {
      final source = await widget.loadSource();
      if (!mounted) return;
      setState(() {
        _source = source;
        _selectedModel = _defaultModel(
          _engine.catalog,
          AiRunKind.summary,
          current: _selectedModel,
        );
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.couldNotReadTheRecordingTextTry,
        );
      }
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AiSettingsPage(services: widget.services),
      ),
    );
    if (!mounted) return;
    try {
      await _engine.refreshCatalog();
      setState(
        () => _selectedModel = _defaultModel(
          _engine.catalog,
          AiRunKind.summary,
          current: _selectedModel,
        ),
      );
    } catch (_) {
      setState(() => _error = l10n.couldNotReadModelServiceSettingsTry);
    }
  }

  Future<void> _generate() async {
    if (_preparing || _engine.busy || _engine.dirty) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    _reportBusy(true);
    try {
      final source = await widget.loadSource();
      final selected = _selectedModel;
      if (selected == null) throw AiFailure(l10n.configureASummaryModelFirst);
      final request = await _engine.prepare(
        source,
        AiRunKind.summary,
        serviceId: selected.serviceId,
        modelProfileId: selected.model.id,
      );
      if (!mounted) return;
      final needsConsent = _engine.requiresConsent(request);
      final approved =
          !needsConsent ||
          await showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => AiConsentSheet(request: request),
              ) ==
              true;
      if (!approved || !mounted) return;
      setState(() {
        _source = source;
        _preparing = false;
      });
      await _engine.run(request, consent: true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.aiSummaryFailedTryAgain,
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
      _reportBusy(false);
    }
  }

  void _reportBusy(bool value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted || !value) widget.onBusyChanged?.call(value);
    });
  }

  Future<void> _showSummarySource() async {
    if (_engine.busy) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.summarySourceAndModel,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.basedOnAudioImagesAndApiKeys(
                    (localizedTextLayer(_source?.textLayer) ??
                            l10n.currentRecordingText)
                        .toString(),
                  ),
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                _AiModelPicker(
                  catalog: _engine.catalog,
                  selected: _selectedModel,
                  onChanged: (value) {
                    setState(() => _selectedModel = value);
                    setSheetState(() {});
                  },
                ),
                if (_selectedModel != null)
                  _DestinationNotice(engine: _engine, model: _selectedModel!),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('ai-open-settings'),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    unawaited(_openSettings());
                  },
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(l10n.manageModelServices),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteThisRecordingSAiSummary),
        content: Text(l10n.onlyAiGeneratedContentWillBeDeleted),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('ai-confirm-clear'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete353),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await _engine.clear(AiRunKind.summary);
  }

  @override
  void dispose() {
    _reportBusy(false);
    unawaited(_subscription?.cancel());
    if (widget.engine == null) _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final summaries = _engine.document.runs
        .where((run) => run.kind == AiRunKind.summary)
        .toList()
        .reversed
        .toList();
    final latest = summaries.firstOrNull;
    final blocked =
        !_engine.loaded ||
        _engine.busy ||
        _preparing ||
        _engine.dirty ||
        _source == null;
    return Column(
      key: const Key('session-ai-summary-pane'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              size: 15,
              color: ProductColors.forest,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.aiOverview,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
            Flexible(
              flex: 2,
              child: TextButton.icon(
                key: const Key('ai-summary-model-picker'),
                onPressed: _engine.busy ? null : _showSummarySource,
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.chevron_right_rounded, size: 15),
                label: Text(
                  l10n.basedOn(
                    (localizedTextLayer(_source?.textLayer) ??
                            l10n.recordingText)
                        .toString(),
                  ),
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            if (summaries.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: l10n.summaryActions,
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
                onSelected: (value) => value == 'regenerate'
                    ? unawaited(_generate())
                    : unawaited(_clear()),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'regenerate',
                    child: Text(l10n.regenerate),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(l10n.deleteSummary),
                  ),
                ],
              ),
          ],
        ),
        if (_source?.hasGaps == true)
          Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              l10n.theRecordingHasConfirmedGapsAiCannot,
              key: Key('ai-gap-warning'),
              style: TextStyle(color: ProductColors.vermilion),
            ),
          ),
        const SizedBox(height: 12),
        if (_engine.loadError != null || _error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error ?? _engine.loadError!,
              key: const Key('ai-error'),
              style: const TextStyle(color: ProductColors.vermilion),
            ),
          ),
        if (_engine.saveError != null) ...[
          const SizedBox(height: 8),
          Text(
            _engine.saveError!,
            style: const TextStyle(color: ProductColors.vermilion),
          ),
          if (_engine.dirty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('ai-retry-save'),
                onPressed: _engine.retrySave,
                child: Text(l10n.retrySavingNoModelCall),
              ),
            ),
        ],
        const SizedBox(height: 4),
        if (latest == null && !_engine.busy)
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: ProductColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: ProductColors.line),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.notes_rounded, color: ProductColors.mutedInk),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _engine.catalog.isEmpty
                        ? l10n.noModelIsAvailableAddAService
                        : l10n.noAiSummaryYetGeneratedSummariesAre,
                    style: const TextStyle(height: 1.5),
                  ),
                ),
              ],
            ),
          )
        else if (latest != null)
          _SummaryRunView(run: latest, sourceFingerprint: _source?.fingerprint),
        if (_preparing || _engine.busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
        if (_engine.busy) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              key: const Key('ai-stop'),
              onPressed: _engine.cancel,
              child: Text(l10n.stopGenerating),
            ),
          ),
        ] else if (summaries.isEmpty ||
            latest?.status == AiRunStatus.failed ||
            latest?.status == AiRunStatus.interrupted) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const Key('ai-generate'),
              onPressed: blocked ? null : _generate,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(
                summaries.isEmpty ? l10n.generateSummary : l10n.retry,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Full-screen, record-scoped chat. Multiple local conversations share the
/// same immutable record source but never cross into other Sessions.
class SessionAiPage extends StatefulWidget {
  const SessionAiPage({
    super.key,
    required this.sessionId,
    required this.services,
    required this.store,
    this.engine,
    required this.loadSource,
    String? recordTitle,
  }) : _recordTitle = recordTitle;
  final String sessionId;
  final AiServices services;
  final AiDocumentStore store;

  /// Owned by the record page when summary and chat share a workspace.
  final AiSessionEngine? engine;
  final Future<AiSourceSnapshot> Function() loadSource;
  final String? _recordTitle;
  String get recordTitle => _recordTitle ?? l10n.currentRecording;
  @override
  State<SessionAiPage> createState() => _SessionAiPageState();
}

class _SessionAiPageState extends State<SessionAiPage>
    with WidgetsBindingObserver {
  late final AiSessionEngine _engine;
  StreamSubscription<void>? _subscription;
  final _question = TextEditingController();
  final _scroll = ScrollController();
  AiSourceSnapshot? _source;
  _AiModelOption? _selectedModel;
  String? _conversationId;
  var _preparing = false;
  var _allowExit = false;
  var _exitDialogOpen = false;
  var _follow = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engine =
        widget.engine ??
        AiSessionEngine(
          sessionId: widget.sessionId,
          provider: widget.services.provider,
          credentialStore: widget.services.credentials,
          documentStore: widget.store,
        );
    _subscription = _engine.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      if (_follow) _scrollToLatest();
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    await _engine.ensureLoaded();
    try {
      final source = await widget.loadSource();
      if (!_engine.loaded) throw AiFailure(l10n.aiHistoryIsNotReady);
      var conversations = _engine.document.conversations;
      if (conversations.isEmpty) {
        _conversationId = await _engine.createConversation();
      } else {
        conversations = [...conversations]
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        _conversationId = conversations.first.id;
      }
      if (!mounted) return;
      setState(() {
        _source = source;
        _selectedModel = _defaultModel(
          _engine.catalog,
          AiRunKind.chat,
          current: _selectedModel,
        );
        _error = null;
      });
      _scrollToLatest();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.couldNotReadAiConversationsTryAgain,
        );
      }
    }
  }

  void _scrollToLatest() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _scroll.hasClients && _follow) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  Future<void> _send({String? retryQuestion}) async {
    if (_preparing || _engine.busy || _engine.dirty) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final source = await widget.loadSource();
      final selected = _selectedModel;
      if (selected == null) throw AiFailure(l10n.configureAChatModelFirst);
      final request = await _engine.prepare(
        source,
        AiRunKind.chat,
        question: retryQuestion ?? _question.text,
        conversationId: _conversationId,
        serviceId: selected.serviceId,
        modelProfileId: selected.model.id,
      );
      if (!mounted) return;
      final needsConsent = _engine.requiresConsent(request);
      final approved =
          !needsConsent ||
          await showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => AiConsentSheet(request: request),
              ) ==
              true;
      if (!approved || !mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _source = source;
        _preparing = false;
        _follow = true;
      });
      if (retryQuestion == null) _question.clear();
      await _engine.run(request, consent: true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.aiChatFailedTryAgain,
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _newConversation() async {
    try {
      final id = await _engine.createConversation();
      if (mounted) {
        setState(() {
          _conversationId = id;
          _error = null;
          _follow = true;
        });
        if (_scroll.hasClients) _scroll.jumpTo(0);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.couldNotCreateAConversation,
        );
      }
    }
  }

  Future<void> _openHistory() async {
    if (_engine.busy || _preparing) return;
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AiConversationHistoryPage(
          engine: _engine,
          selectedId: _conversationId,
          recordTitle: widget.recordTitle,
        ),
      ),
    );
    if (!mounted) return;
    var target = selected;
    final currentStillExists = _engine.document.conversations.any(
      (value) => value.id == _conversationId,
    );
    if (target == null && !currentStillExists) {
      final remaining = [..._engine.document.conversations]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      target = remaining.isEmpty
          ? await _engine.createConversation()
          : remaining.first.id;
    }
    if (target != null && mounted) {
      setState(() {
        _conversationId = target;
        _follow = true;
      });
      _scrollToLatest();
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AiSettingsPage(services: widget.services),
      ),
    );
    if (!mounted) return;
    try {
      await _engine.refreshCatalog();
      setState(
        () => _selectedModel = _defaultModel(
          _engine.catalog,
          AiRunKind.chat,
          current: _selectedModel,
        ),
      );
    } catch (_) {
      setState(() => _error = l10n.couldNotReadModelServiceSettingsTry);
    }
  }

  Future<void> _requestExit() async {
    if (_exitDialogOpen) return;
    _exitDialogOpen = true;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.leaveAiChat),
        content: Text(
          _engine.dirty
              ? l10n.someAiContentHasNotBeenSaved
              : l10n.leavingWillStopGenerationTheProviderMay,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.stay),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.leave),
          ),
        ],
      ),
    );
    _exitDialogOpen = false;
    if (approved == true && mounted) {
      _engine.cancel();
      setState(() => _allowExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _engine.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    if (widget.engine == null) _engine.dispose();
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final runs = _engine.document.runs
        .where(
          (run) =>
              run.kind == AiRunKind.chat &&
              run.conversationId == _conversationId,
        )
        .toList();
    final blocked =
        !_engine.loaded ||
        _engine.busy ||
        _preparing ||
        _engine.dirty ||
        _source == null ||
        _conversationId == null;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: _allowExit || (!_engine.busy && !_preparing && !_engine.dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        key: const Key('session-ai-page'),
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          centerTitle: true,
          titleSpacing: 8,
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1),
          ),
          title: _AiModelMenu(
            catalog: _engine.catalog,
            selected: _selectedModel,
            enabled: !blocked,
            onChanged: (value) => setState(() => _selectedModel = value),
            onNewChat: _newConversation,
            onOpenSettings: _openSettings,
          ),
          actions: [
            IconButton(
              key: const Key('ai-chat-history'),
              tooltip: l10n.chatHistory,
              onPressed: _openHistory,
              icon: const Icon(Icons.history_rounded),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                color: ProductColors.forestSoft,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.auto_awesome_rounded,
                      size: 17,
                      color: ProductColors.forest,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.answeringBasedOn(
                          (widget.recordTitle.isEmpty
                                  ? l10n.untitledRecording
                                  : widget.recordTitle)
                              .toString(),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ProductColors.forest,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_source?.hasGaps == true)
                Padding(
                  padding: EdgeInsets.fromLTRB(18, 2, 18, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.thisRecordingHasGapsAnswersCannotCover,
                      key: Key('ai-gap-warning'),
                      style: TextStyle(color: ProductColors.vermilion),
                    ),
                  ),
                ),
              Expanded(
                child: NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (notification.direction != ScrollDirection.idle) {
                      final follow = notification.metrics.extentAfter < 60;
                      if (_follow != follow) setState(() => _follow = follow);
                    }
                    return false;
                  },
                  child: ListView(
                    controller: _scroll,
                    key: const Key('ai-content-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
                    children: [
                      if (runs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 42),
                          child: Column(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: const BoxDecoration(
                                  color: ProductColors.forestSoft,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.auto_awesome_rounded,
                                  color: ProductColors.forest,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                l10n.askAboutThisRecording,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                l10n.forExampleWhatWereTheMainPoints,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: ProductColors.mutedInk,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (runs.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            _formatChatDate(runs.first.createdAt),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: ProductColors.mutedInk,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      for (final run in runs)
                        _ChatTurn(
                          run: run,
                          onRetry: _send,
                          sourceFingerprint: _source?.fingerprint,
                        ),
                      if (_preparing || _engine.busy)
                        const LinearProgressIndicator(),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            key: const Key('ai-error'),
                            style: const TextStyle(
                              color: ProductColors.vermilion,
                            ),
                          ),
                        ),
                      if (_engine.saveError != null) ...[
                        Text(
                          _engine.saveError!,
                          style: const TextStyle(
                            color: ProductColors.vermilion,
                          ),
                        ),
                        if (_engine.dirty)
                          TextButton(
                            key: const Key('ai-retry-save'),
                            onPressed: _engine.retrySave,
                            child: Text(l10n.retrySavingNoModelCall),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!_follow)
                TextButton(
                  onPressed: () {
                    setState(() => _follow = true);
                    _scrollToLatest();
                  },
                  child: Text(l10n.jumpToLatest),
                ),
            ],
          ),
        ),
        bottomNavigationBar: AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: keyboard),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Container(
                key: const Key('ai-chat-composer'),
                constraints: const BoxConstraints(minHeight: 90),
                padding: const EdgeInsets.fromLTRB(14, 8, 7, 6),
                decoration: BoxDecoration(
                  color: ProductColors.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: ProductColors.line),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x160D241B),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('ai-question'),
                            controller: _question,
                            enabled: !blocked,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 4000,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              hintText: l10n.askAnotherQuestion,
                              counterText: '',
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (keyboard > 0) ...[
                          IconButton(
                            key: const Key('ai-dismiss-keyboard'),
                            tooltip: l10n.hideKeyboard,
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                FocusManager.instance.primaryFocus?.unfocus(),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          ),
                          const SizedBox(width: 2),
                        ],
                        if (_engine.busy)
                          IconButton.filledTonal(
                            key: const Key('ai-stop'),
                            tooltip: l10n.stopGenerating,
                            onPressed: _engine.cancel,
                            icon: const Icon(Icons.stop_rounded),
                          )
                        else
                          IconButton.filled(
                            key: const Key('ai-generate'),
                            tooltip: l10n.sendQuestion,
                            onPressed: blocked ? null : _send,
                            icon: const Icon(Icons.send_rounded, size: 19),
                          ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.contentWillBeSentToYourSelected,
                        style: TextStyle(
                          fontSize: 11,
                          color: ProductColors.mutedInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AiConversationHistoryPage extends StatefulWidget {
  const AiConversationHistoryPage({
    super.key,
    required this.engine,
    required this.selectedId,
    String? recordTitle,
  }) : _recordTitle = recordTitle;
  final AiSessionEngine engine;
  final String? selectedId;
  final String? _recordTitle;
  String get recordTitle => _recordTitle ?? l10n.currentRecording;
  @override
  State<AiConversationHistoryPage> createState() =>
      _AiConversationHistoryPageState();
}

class _AiConversationHistoryPageState extends State<AiConversationHistoryPage> {
  String? _error;
  final _search = TextEditingController();
  var _query = '';

  Future<void> _createConversation() async {
    try {
      final id = await widget.engine.createConversation();
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.couldNotCreateAConversation,
        );
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _rename(AiConversation conversation) async {
    final controller = TextEditingController(text: conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.renameConversation),
        content: TextField(
          controller: controller,
          maxLength: 80,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || !mounted) return;
    try {
      await widget.engine.renameConversation(conversation.id, title);
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is AiFailure ? error.message : l10n.couldNotRename,
        );
      }
    }
  }

  Future<void> _delete(AiConversation conversation) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.delete((conversation.title).toString())),
        content: Text(l10n.thisDeletesQuestionsAndAnswersInThis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete353),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await widget.engine.deleteConversation(conversation.id);
      setState(() {});
    }
  }

  Future<void> _showActions(AiConversation conversation) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.renameConversation),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: ProductColors.vermilion,
                ),
                title: Text(
                  l10n.deleteConversation,
                  style: TextStyle(color: ProductColors.vermilion),
                ),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      await _rename(conversation);
    } else if (action == 'delete') {
      await _delete(conversation);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final conversations = [...widget.engine.document.conversations]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final normalized = _query.trim().toLowerCase();
    final filtered = normalized.isEmpty
        ? conversations
        : conversations
              .where(
                (conversation) =>
                    conversation.title.toLowerCase().contains(normalized),
              )
              .toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(l10n.chatHistory),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
        actions: [
          IconButton(
            key: const Key('ai-history-new-chat'),
            tooltip: l10n.newConversation393,
            onPressed: _createConversation,
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
          children: [
            TextField(
              key: const Key('ai-history-search'),
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: l10n.searchQuestionsOrRecordings,
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
                filled: true,
                fillColor: Color(0xFFEFF0EC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(13)),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(13)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 22),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(color: ProductColors.vermilion),
              ),
            if (filtered.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.recent,
                      style: TextStyle(
                        fontSize: 13,
                        color: ProductColors.mutedInk,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    l10n.conversations((filtered.length).toString()),
                    style: const TextStyle(
                      fontSize: 12,
                      color: ProductColors.mutedInk,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  for (var index = 0; index < filtered.length; index++) ...[
                    ListTile(
                      key: Key('ai-conversation-${filtered[index].id}'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                      leading: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: ProductColors.forestSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 19,
                          color: ProductColors.forest,
                        ),
                      ),
                      title: Text(
                        filtered[index].title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        widget.recordTitle.isEmpty
                            ? l10n.untitledRecording
                            : widget.recordTitle,
                      ),
                      onTap: () => Navigator.pop(context, filtered[index].id),
                      onLongPress: () => _showActions(filtered[index]),
                      trailing: _ConversationMeta(
                        time: _formatConversationTime(
                          filtered[index].updatedAt,
                        ),
                        selected: filtered[index].id == widget.selectedId,
                      ),
                    ),
                    if (index != filtered.length - 1)
                      const Divider(height: 1, indent: 72),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationMeta extends StatelessWidget {
  const _ConversationMeta({required this.time, required this.selected});

  final String time;
  final bool selected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 42,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          time,
          style: const TextStyle(color: ProductColors.mutedInk, fontSize: 10),
        ),
        if (selected)
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF3F9A68),
              shape: BoxShape.circle,
            ),
          ),
      ],
    ),
  );
}

class AiConsentSheet extends StatelessWidget {
  const AiConsentSheet({super.key, required this.request});
  final AiPreparedRequest request;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final config = request.credentials.configuration;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
        height: MediaQuery.sizeOf(context).height * 0.68,
        decoration: BoxDecoration(
          color: ProductColors.surface,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [
            BoxShadow(
              color: Color(0x320D1D15),
              blurRadius: 44,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: ProductColors.forestSoft,
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Icon(
                          Icons.verified_user_outlined,
                          color: ProductColors.forest,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      l10n.useYourModelService,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      l10n.aiFeaturesSendTheCurrentRecordingS,
                      style: const TextStyle(
                        color: ProductColors.mutedInk,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 15),
                    Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: ProductColors.paper,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          _ConsentFact(
                            l10n.onlyThisRecordingSTextSpeakerLabels,
                          ),
                          SizedBox(height: 9),
                          _ConsentFact(l10n.audioImagesNotesAndApiKeysAre),
                          SizedBox(height: 9),
                          _ConsentFact(l10n.shownOnceBeforeFirstUsingAi),
                        ],
                      ),
                    ),
                    const SizedBox(height: 13),
                    Text(
                      '${config.modelName}  ·  ${config.endpoint}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ProductColors.mutedInk,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('ai-confirm-send'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.agreeAndContinue),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('ai-cancel-consent'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.notNow),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentFact extends StatelessWidget {
  const _ConsentFact(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.check_rounded, size: 16, color: ProductColors.forest),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(
            color: ProductColors.mutedInk,
            fontSize: 12,
            height: 1.45,
          ),
        ),
      ),
    ],
  );
}

class _AiModelMenu extends StatelessWidget {
  const _AiModelMenu({
    required this.catalog,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    required this.onNewChat,
    required this.onOpenSettings,
  });

  final AiCredentialCatalog catalog;
  final _AiModelOption? selected;
  final bool enabled;
  final ValueChanged<_AiModelOption> onChanged;
  final VoidCallback onNewChat;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final options = _modelOptions(catalog);
    if (options.isEmpty) {
      return Text(l10n.aiChat);
    }
    final value = options.firstWhere(
      (item) => item == selected,
      orElse: () => options.first,
    );
    return PopupMenuButton<Object>(
      key: const Key('ai-chat-model-menu'),
      enabled: enabled,
      tooltip: l10n.switchModel,
      onSelected: (selection) {
        if (selection is _AiModelOption) {
          onChanged(selection);
        } else if (selection == 'new') {
          onNewChat();
        } else if (selection == 'settings') {
          onOpenSettings();
        }
      },
      itemBuilder: (_) => [
        for (final option in options)
          PopupMenuItem(
            value: option,
            child: Row(
              children: [
                if (option == value) ...[
                  const Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: ProductColors.forest,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    '${option.serviceName} · ${option.model.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          key: Key('ai-new-chat'),
          value: 'new',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add_comment_outlined),
            title: Text(l10n.newConversation393),
          ),
        ),
        PopupMenuItem<Object>(
          key: Key('ai-open-settings'),
          value: 'settings',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.tune_rounded),
            title: Text(l10n.manageModelServices),
          ),
        ),
      ],
      child: Container(
        constraints: const BoxConstraints(maxWidth: 184),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: ProductColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: ProductColors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                value.model.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

Future<void> _showDestinationDetails(
  BuildContext context,
  _AiModelOption model,
) async {
  final service = model.credentials.service;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.whatWillBeSent),
      content: Text(
        l10n.serviceModelAddressOnlyRecordingTextSpeaker(
          (service.name).toString(),
          (model.model.name).toString(),
          (service.endpoint).toString(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}

class _AiModelPicker extends StatelessWidget {
  const _AiModelPicker({
    required this.catalog,
    required this.selected,
    required this.onChanged,
  });
  final AiCredentialCatalog catalog;
  final _AiModelOption? selected;
  final ValueChanged<_AiModelOption>? onChanged;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final options = _modelOptions(catalog);
    if (options.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(l10n.noModelServiceIsConfigured),
      );
    }
    final value = options.firstWhere(
      (item) => item == selected,
      orElse: () => options.first,
    );
    return DropdownButtonFormField<_AiModelOption>(
      key: ValueKey('ai-model-picker-${value.serviceId}-${value.model.id}'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.model,
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: options
          .map(
            (item) => DropdownMenuItem(
              value: item,
              child: Text(
                '${item.serviceName} · ${item.model.name}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: onChanged == null ? null : (value) => onChanged!(value!),
    );
  }
}

class _DestinationNotice extends StatelessWidget {
  const _DestinationNotice({required this.engine, required this.model});
  final AiSessionEngine engine;
  final _AiModelOption model;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final service = model.credentials.service;
    final authorized = engine.catalog.hasRemoteProcessingConsent;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('ai-destination-notice'),
        onPressed: () => _showDestinationDetails(context, model),
        icon: Icon(
          authorized
              ? Icons.verified_user_outlined
              : Icons.info_outline_rounded,
          size: 17,
        ),
        label: Text(
          l10n.sendingTo(
            (service.name).toString(),
            (model.model.name).toString(),
            (authorized
                    ? l10n.dataSharingNoticeConfirmed
                    : l10n.confirmationRequiredBeforeFirstUse)
                .toString(),
          ),
        ),
      ),
    );
  }
}

class _SummaryRunView extends StatelessWidget {
  const _SummaryRunView({required this.run, required this.sourceFingerprint});

  final AiRun run;
  final String? sourceFingerprint;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final document = _StructuredSummary.tryParse(run.text);
    if (document == null || run.status != AiRunStatus.complete) {
      return _AiRunCard(run: run, sourceFingerprint: sourceFingerprint);
    }
    final stale =
        sourceFingerprint != null && sourceFingerprint != run.sourceFingerprint;
    return Column(
      key: const Key('ai-summary-structured'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale)
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.theRecordingTextOrSpeakersHaveChanged,
              style: TextStyle(color: ProductColors.amber),
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          decoration: BoxDecoration(
            color: ProductColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: ProductColors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0C233027),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.keyTakeaway,
                style: TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 9),
              SelectableText(
                document.headline,
                style: const TextStyle(
                  color: ProductColors.ink,
                  fontSize: 20,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              if (document.overview.isNotEmpty) ...[
                const SizedBox(height: 9),
                AiMarkdownView(data: document.overview, compact: true),
              ],
              const SizedBox(height: 15),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _SummaryTag(
                    l10n.keyPoints((document.keyPointCount).toString()),
                  ),
                  _SummaryTag(
                    l10n.conclusions((document.conclusionCount).toString()),
                  ),
                  _SummaryTag(
                    run.hasGaps ? l10n.contentHasGaps : l10n.noContentGaps,
                  ),
                ],
              ),
            ],
          ),
        ),
        _SummarySection(title: l10n.keyPoints419, markdown: document.keyPoints),
        _SummarySection(
          title: l10n.conclusions420,
          markdown: document.conclusions,
        ),
        const SizedBox(height: 18),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(
              Icons.smart_toy_outlined,
              size: 14,
              color: ProductColors.mutedInk,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                run.model,
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 11,
                ),
              ),
            ),
            Flexible(
              child: Text(
                l10n.updated(
                  (_formatConversationTime(run.createdAt)).toString(),
                ),
                textAlign: TextAlign.end,
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryTag extends StatelessWidget {
  const _SummaryTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F3EF),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(color: ProductColors.mutedInk, fontSize: 10),
    ),
  );
}

class _SummarySection extends StatelessWidget {
  const _SummarySection({required this.title, required this.markdown});

  final String title;
  final String markdown;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 22, 2, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        AiMarkdownView(data: markdown, compact: true),
      ],
    ),
  );
}

class _StructuredSummary {
  const _StructuredSummary({
    required this.headline,
    required this.overview,
    required this.keyPoints,
    required this.conclusions,
  });

  final String headline;
  final String overview;
  final String keyPoints;
  final String conclusions;

  int get keyPointCount => _itemCount(keyPoints);
  int get conclusionCount => _itemCount(conclusions);

  static _StructuredSummary? tryParse(String markdown) {
    final sections = <String, List<String>>{};
    String? current;
    final heading = RegExp(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$');
    for (final line in markdown.split('\n')) {
      final match = heading.firstMatch(line);
      if (match != null) {
        current = match.group(1)!.trim();
        sections.putIfAbsent(current, () => <String>[]);
      } else if (current != null) {
        sections[current]!.add(line);
      }
    }
    String read(String Function(AppLocalizations) title) {
      for (final locale in AppLocalizations.supportedLocales) {
        final text = sections[title(lookupAppLocalizations(locale))]
            ?.join('\n')
            .trim();
        if (text != null && text.isNotEmpty) return text;
      }
      return '';
    }

    final headline = _plainSummaryText(read((strings) => strings.keyTakeaway));
    final overview = read((strings) => strings.overview);
    final keyPoints = read((strings) => strings.keyPoints419);
    final conclusions = read((strings) => strings.conclusions420);
    if (headline.isEmpty ||
        overview.isEmpty ||
        keyPoints.isEmpty ||
        conclusions.isEmpty) {
      return null;
    }
    return _StructuredSummary(
      headline: headline,
      overview: overview,
      keyPoints: keyPoints,
      conclusions: conclusions,
    );
  }

  static int _itemCount(String value) {
    final count = value
        .split('\n')
        .where((line) => RegExp(r'^\s*[-*+]\s+').hasMatch(line))
        .length;
    return count == 0 && value.trim().isNotEmpty ? 1 : count;
  }
}

String _plainSummaryText(String value) => value
    .replaceAll(RegExp(r'[*_`]+'), '')
    .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class _AiRunCard extends StatelessWidget {
  const _AiRunCard({required this.run, required this.sourceFingerprint});
  final AiRun run;
  final String? sourceFingerprint;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final stale =
        sourceFingerprint != null && sourceFingerprint != run.sourceFingerprint;
    return Container(
      key: Key('ai-run-${run.id}'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
      decoration: BoxDecoration(
        color: ProductColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: ProductColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stale)
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                l10n.theRecordingTextOrSpeakersHaveChanged,
                style: TextStyle(color: ProductColors.amber),
              ),
            ),
          if (run.text.isNotEmpty) ...[AiMarkdownView(data: run.text)],
          if (run.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                run.error!,
                style: const TextStyle(color: ProductColors.vermilion),
              ),
            ),
          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.smart_toy_outlined,
                size: 14,
                color: ProductColors.mutedInk,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${run.model} · ${_runStatus(run.status)}',
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    fontSize: 11,
                  ),
                ),
              ),
              if (run.totalTokens != null)
                Text(
                  '${run.totalTokens} tokens',
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatTurn extends StatelessWidget {
  const _ChatTurn({
    required this.run,
    required this.onRetry,
    this.sourceFingerprint,
  });
  final String? sourceFingerprint;
  final AiRun run;
  final Future<void> Function({String? retryQuestion}) onRetry;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 310),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: ProductColors.forestSoft,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(5),
                ),
              ),
              child: SelectableText(
                run.question,
                style: const TextStyle(color: Color(0xFF284336), height: 1.55),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (sourceFingerprint != null &&
              sourceFingerprint != run.sourceFingerprint)
            Text(
              l10n.theRecordingTextOrSpeakersHaveChanged423,
              style: TextStyle(color: ProductColors.amber),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: ProductColors.forest,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (run.status != AiRunStatus.complete)
                      Text(
                        '${run.model} · ${_runStatus(run.status)}',
                        style: const TextStyle(
                          color: ProductColors.mutedInk,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (run.text.isNotEmpty) ...[
                      if (run.status != AiRunStatus.complete)
                        const SizedBox(height: 8),
                      AiMarkdownView(data: run.text),
                    ],
                    if (run.error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        run.error!,
                        style: const TextStyle(color: ProductColors.vermilion),
                      ),
                      TextButton(
                        onPressed: () => onRetry(retryQuestion: run.question),
                        child: Text(l10n.sendAgain),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AiModelOption {
  const _AiModelOption(this.credentials, this.model);
  final AiServiceCredentials credentials;
  final AiModelProfile model;
  String get serviceId => credentials.service.id;
  String get serviceName => credentials.service.name;

  @override
  bool operator ==(Object other) =>
      other is _AiModelOption &&
      other.serviceId == serviceId &&
      other.model.id == model.id;

  @override
  int get hashCode => Object.hash(serviceId, model.id);
}

List<_AiModelOption> _modelOptions(AiCredentialCatalog catalog) => [
  for (final credentials in catalog.services)
    for (final model in credentials.service.models)
      _AiModelOption(credentials, model),
];

_AiModelOption? _defaultModel(
  AiCredentialCatalog catalog,
  AiRunKind kind, {
  _AiModelOption? current,
}) {
  final options = _modelOptions(catalog);
  if (options.isEmpty) return null;
  if (current != null && options.contains(current)) {
    return options.firstWhere((value) => value == current);
  }
  final serviceId = kind == AiRunKind.summary
      ? catalog.defaultSummaryServiceId
      : catalog.defaultChatServiceId;
  final modelId = kind == AiRunKind.summary
      ? catalog.defaultSummaryModelId
      : catalog.defaultChatModelId;
  return options.firstWhere(
    (value) => value.serviceId == serviceId && value.model.id == modelId,
    orElse: () => options.first,
  );
}

String _runStatus(AiRunStatus status) => switch (status) {
  AiRunStatus.running => l10n.generating,
  AiRunStatus.complete => l10n.completed,
  AiRunStatus.failed => l10n.failed,
  AiRunStatus.interrupted => l10n.interrupted428,
};

String _formatConversationTime(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final difference = now.difference(local);
  if (!difference.isNegative && difference.inMinutes < 1) return l10n.justNow;
  if (!difference.isNegative && difference.inMinutes < 60) {
    return l10n.minAgo((difference.inMinutes).toString());
  }
  if (_sameDay(local, now)) {
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (_sameDay(local, yesterday)) return l10n.yesterday;
  return formatSessionDate(local);
}

String _formatChatDate(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (_sameDay(local, now)) return l10n.today((time).toString());
  final yesterday = now.subtract(const Duration(days: 1));
  if (_sameDay(local, yesterday)) return l10n.yesterday434((time).toString());
  return formatSessionDate(local);
}

bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
