import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_ports.dart';
import '../../core/ai/ai_session_engine.dart';
import '../../core/session/session_experience_gateway.dart';
import '../../core/session/session_transfer_gateway.dart';
import '../../domain/session/session_summary.dart';
import '../../domain/speaker/speaker_diarization.dart';
import '../../domain/timeline/timeline_item.dart';
import '../../domain/transcript/refined_full_text.dart';
import '../../poc/poc_bridge.dart';
import '../ai_services.dart';
import '../app_coordinator.dart';
import '../full_text_reading_document.dart';
import '../full_text_search.dart';
import '../local_search.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import '../session_ai_source.dart';
import '../session_detail_controller.dart';
import '../speaker_localization.dart';
import '../speaker_session_text.dart';
import '../timeline_display_item.dart';
import '../timeline_turn.dart';
import '../widgets/playback_sound_sheet.dart';
import '../widgets/product_timeline_card.dart';
import '../widgets/record_content_view.dart';
import '../widgets/searchable_full_text.dart';
import '../widgets/speaker_editor_sheet.dart';
import '../widgets/timeline_search_bar.dart';
import '../widgets/virtual_full_text.dart';
import 'session_ai_page.dart';

enum _DetailOverflowAction { search, refine, export, manage }

class ProductSessionDetailPage extends StatefulWidget {
  const ProductSessionDetailPage({
    super.key,
    required this.session,
    required this.gateway,
    required this.coordinator,
    this.transcriptionMayBeFinishing = false,
    this.showSavedConfirmation = false,
    this.recoveryOutcome,
    this.recoveryTranscriptionFailed = false,
    this.initialSearchTarget,
    this.transferGateway = const NativeSessionTransferGateway(),
    this.aiServices,
    this.onOpenModels,
  });

  final SessionSummary session;
  final SessionExperienceGateway gateway;
  final AppCoordinator coordinator;
  final bool transcriptionMayBeFinishing;
  final bool showSavedConfirmation;
  final RecoveryOutcome? recoveryOutcome;
  final bool recoveryTranscriptionFailed;
  final SearchNavigationTarget? initialSearchTarget;
  final SessionTransferGateway transferGateway;
  final AiServices? aiServices;
  final Future<void> Function()? onOpenModels;

  @override
  State<ProductSessionDetailPage> createState() =>
      _ProductSessionDetailPageState();
}

class _ProductSessionDetailPageState extends State<ProductSessionDetailPage> {
  static const _pageSize = 50;

  late final SessionDetailController _controller;
  late final AiServices _aiServices;
  late final AiDocumentStore _aiDocumentStore;
  late final AiSessionEngine _aiEngine;
  StreamSubscription<void>? _aiSubscription;
  var _aiOpen = false;
  var _aiSummaryBusy = false;
  final _timelineScrollController = ScrollController();
  final _fullTextScrollController = ScrollController();
  final _aiSummaryScrollController = ScrollController();
  final _timelineListKey = GlobalKey();
  final _fullTextListKey = GlobalKey();
  final _aiSummaryListKey = GlobalKey();
  final _fullTextContentKey = GlobalKey<SearchableFullTextState>();
  final _virtualFullTextKey = GlobalKey<VirtualFullTextState>();
  ScrollController get _scrollController => switch (_selectedView) {
    RecordContentView.timeline => _timelineScrollController,
    RecordContentView.fullText => _fullTextScrollController,
    RecordContentView.aiSummary => _aiSummaryScrollController,
  };
  GlobalKey get _listKey => switch (_selectedView) {
    RecordContentView.timeline => _timelineListKey,
    RecordContentView.fullText => _fullTextListKey,
    RecordContentView.aiSummary => _aiSummaryListKey,
  };
  final Map<String, GlobalKey> _timelineItemKeys = {};
  final Map<String, GlobalKey> _timelineTextKeys = {};
  final Map<String, TimelineTurn> _turnByItem = {};
  List<TimelineTurn> _turns = [];
  Object? _turnSources;
  Object? _turnRefinement;
  Object? _turnSpeakers;
  TimelineTextPreference? _turnPreference;
  late SessionSummary _session;
  Timer? _freshSessionTimer;
  Timer? _savedConfirmationTimer;
  var _visibleCount = _pageSize;
  TranscriptionPhase get _transcriptionPhase =>
      widget.gateway.transcriptionPhase(_session.sessionId);

  bool get _hasProcessingNotice =>
      _transcriptionPhase != TranscriptionPhase.idle ||
      _controller.fullTextRefinement.status ==
          FullTextRefinementStatus.processing ||
      _controller.fullTextRefinement.status == FullTextRefinementStatus.failed;
  var _showSavedConfirmation = false;
  var _deleting = false;
  var _manualRefinementBusy = false;

  bool get _canRefine =>
      _controller.canPlay &&
      !_deleting &&
      !_manualRefinementBusy &&
      !_controller.speakerDiarizationBusy &&
      !_controller.exporting &&
      !_controller.sharing &&
      !widget.coordinator.hasActiveCapture &&
      !widget.coordinator.isBusy &&
      !widget.coordinator.isModelOperationActive &&
      _transcriptionPhase == TranscriptionPhase.idle;

  String get _refineLabel => _controller.fullTextRefinement.document == null
      ? l10n.manualRefinementStart
      : l10n.manualRefinementRebuild;
  var _selectedView = RecordContentView.timeline;
  var _timelineTextPreference = TimelineTextPreference.refined;
  var _followPlaybackPosition = true;
  String? _projectionSignature;
  String? _lastPlaybackItemId;
  var _playbackRevealGeneration = 0;
  final _searchFieldController = TextEditingController();
  final _searchFocusNode = FocusNode();
  var _searchOpen = false;
  var _searchQuery = '';
  List<RecordSearchHit> _searchHits = const [];
  final _searchSelections = <RecordContentView, RecordSearchHit?>{};
  var _activeSearchIndex = -1;
  var _initialSearchApplied = false;
  List<TimelineItem>? _lastSearchTimeline;
  Object? _lastSearchRefinement;
  Object? _lastSearchSpeakers;
  TimelineTextPreference? _lastSearchPreference;
  RecordContentView? _lastSearchView;
  FullTextSearchDocument? _fullTextDocument;
  List<FullTextAttachment> _fullTextAttachments = const [];
  List<TimelineItem>? _fullTextSources;
  Object? _fullTextRefinementSource;
  Object? _fullTextSpeakerSource;
  String? _searchNotice;

  String? _presentationLanguage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = context.strings.localeName;
    if (_presentationLanguage == language) return;
    _presentationLanguage = language;
    // Only presentation caches depend on locale. Recording data stays intact.
    _turnSources = null;
    _fullTextDocument = null;
    _lastSearchTimeline = null;
  }

  bool get _canUseAi =>
      !widget.coordinator.hasActiveCapture &&
      [
        SessionStatus.completed,
        SessionStatus.completedWithGaps,
      ].contains(_session.status);

  @override
  void initState() {
    super.initState();
    _aiServices = widget.aiServices ?? AiServices.platform();
    _aiDocumentStore = _aiServices.documentStore(widget.session.directory);
    _aiEngine = AiSessionEngine(
      sessionId: widget.session.sessionId,
      provider: _aiServices.provider,
      credentialStore: _aiServices.credentials,
      documentStore: _aiDocumentStore,
    );
    _aiSubscription = _aiEngine.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _session = widget.session;
    final searchTarget = widget.initialSearchTarget;
    if (searchTarget != null) {
      _searchOpen = true;
      _searchQuery = searchTarget.query;
      _searchFieldController.text = _searchQuery;
      _followPlaybackPosition = false;
    }
    _controller = SessionDetailController(
      session: widget.session,
      gateway: widget.gateway,
      transferGateway: widget.transferGateway,
    );
    _controller.addListener(_handleControllerChange);
    _showSavedConfirmation = widget.showSavedConfirmation;
    unawaited(_controller.initialize());
    _syncTranscriptionPolling();
    if (_showSavedConfirmation) {
      _savedConfirmationTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showSavedConfirmation = false);
      });
    }
  }

  void _syncTranscriptionPolling() {
    final processing =
        _transcriptionPhase != TranscriptionPhase.idle ||
        _controller.fullTextRefinement.status ==
            FullTextRefinementStatus.processing;
    if (processing) {
      _freshSessionTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_controller.refreshContent()),
      );
    } else {
      _freshSessionTimer?.cancel();
      _freshSessionTimer = null;
    }
  }

  @override
  void dispose() {
    _freshSessionTimer?.cancel();
    _savedConfirmationTimer?.cancel();
    _controller.removeListener(_handleControllerChange);
    _controller.dispose();
    unawaited(_aiSubscription?.cancel());
    _aiEngine.dispose();
    _timelineScrollController.dispose();
    _fullTextScrollController.dispose();
    _aiSummaryScrollController.dispose();
    _searchFieldController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<AiSourceSnapshot> _loadAiSource() async {
    if (widget.coordinator.hasActiveCapture ||
        widget.gateway.isTranscriptionFinishing(_session.sessionId)) {
      throw AiFailure(l10n.recordingOrLiveTranscriptionIsStillFinishing);
    }
    final session = await widget.coordinator.sessionRepository.getSession(
      _session.sessionId,
    );
    final timeline = await widget.gateway.timeline(session.directory);
    final refinement = await widget.gateway.fullTextRefinement(
      session.directory,
    );
    final speakers = await widget.gateway.speakerDiarization(session.directory);
    return sessionAiSource(
      session: session,
      timeline: timeline,
      refinement: refinement,
      speakers: speakers.document,
    );
  }

  Future<void> _openAi() async {
    if (_aiOpen || _deleting || _aiEngine.busy || _aiEngine.dirty) return;
    setState(() => _aiOpen = true);
    _searchFocusNode.unfocus();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SessionAiPage(
            sessionId: _session.sessionId,
            recordTitle: _session.title,
            services: _aiServices,
            store: _aiDocumentStore,
            engine: _aiEngine,
            loadSource: _loadAiSource,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _aiOpen = false);
    }
  }

  void _handleControllerChange() {
    _syncTranscriptionPolling();
    final projection = projectTimelineForDisplay(
      timeline: _controller.timeline,
      refinement: _controller.fullTextRefinement,
      preference: _timelineTextPreference,
    );
    final previous = _projectionSignature;
    _projectionSignature = projection.signature;
    if (previous != null &&
        (previous != projection.signature ||
            !identical(
              _turnSpeakers,
              _controller.speakerDiarization.document,
            ))) {
      _restoreVisibleAnchorAfterBuild(_captureVisibleAnchor());
    }

    final currentPlaybackItemId = _controller.currentPlaybackItemId;
    final previousPlaybackItemId = _lastPlaybackItemId;
    _lastPlaybackItemId = currentPlaybackItemId;
    if (currentPlaybackItemId == null) {
      if (previousPlaybackItemId != null) {
        _playbackRevealGeneration += 1;
        _followPlaybackPosition = true;
      }
    } else if (currentPlaybackItemId != previousPlaybackItemId &&
        _followPlaybackPosition) {
      _scheduleRevealPlaybackItem(currentPlaybackItemId);
    }
    _refreshSearchHits(projection);
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, widget.coordinator]),
      builder: (context, _) {
        return PopScope(
          canPop: !_deleting,
          child: Scaffold(
            appBar: AppBar(
              centerTitle: true,
              titleSpacing: 4,
              title: Text(
                _session.title.isEmpty
                    ? l10n.untitledRecording
                    : _session.title,
              ),
              titleTextStyle: const TextStyle(
                color: ProductColors.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              actions: [
                PopupMenuButton<_DetailOverflowAction>(
                  key: const Key('product-session-actions'),
                  tooltip: l10n.recordingActions,
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (action) {
                    switch (action) {
                      case _DetailOverflowAction.search:
                        _toggleSearch();
                        return;
                      case _DetailOverflowAction.refine:
                        unawaited(_startManualRefinement());
                        return;
                      case _DetailOverflowAction.export:
                        unawaited(_showExportSheet());
                        return;
                      case _DetailOverflowAction.manage:
                        unawaited(_showSessionActions());
                        return;
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: const Key('detail-search-toggle'),
                      value: _DetailOverflowAction.search,
                      enabled:
                          !_deleting &&
                          _selectedView != RecordContentView.aiSummary,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          _searchOpen
                              ? Icons.search_off_rounded
                              : Icons.search_rounded,
                        ),
                        title: Text(
                          _searchOpen
                              ? l10n.closeSearch
                              : l10n.searchRecordingContent,
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      key: const Key('detail-refine-fulltext'),
                      value: _DetailOverflowAction.refine,
                      enabled: _canRefine,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.auto_awesome_rounded),
                        title: Text(_refineLabel),
                      ),
                    ),
                    PopupMenuItem(
                      key: const Key('product-session-export'),
                      value: _DetailOverflowAction.export,
                      enabled: _session.exportAvailable && !_deleting,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.ios_share_rounded),
                        title: Text(l10n.shareAndExport),
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      key: Key('detail-manage-session'),
                      enabled:
                          !_manualRefinementBusy &&
                          _transcriptionPhase == TranscriptionPhase.idle,
                      value: _DetailOverflowAction.manage,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.edit_note_rounded),
                        title: Text(l10n.manageRecording),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
            body: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  if (_searchOpen)
                    ConstrainedBox(
                      // Size to the search content, then give all remaining space
                      // to the timeline. Two flex children would reserve half the
                      // body even when the search field is almost empty.
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.75,
                      ),
                      child: SingleChildScrollView(
                        key: const Key('detail-search-panel'),
                        primary: false,
                        child: TimelineSearchBar(
                          controller: _searchFieldController,
                          focusNode: _searchFocusNode,
                          hidePreview:
                              MediaQuery.viewInsetsOf(context).bottom > 0 ||
                              constraints.maxHeight < 400,
                          query: _searchQuery,
                          hits: _searchHits,
                          activeIndex: _activeSearchIndex,
                          onChanged: _changeSearchQuery,
                          onSubmitted: () =>
                              _navigateSearchHit(_activeSearchIndex),
                          onPrevious: () =>
                              _navigateSearchHit(_activeSearchIndex - 1),
                          onNext: () =>
                              _navigateSearchHit(_activeSearchIndex + 1),
                          onPlay:
                              _activeSearchHit?.playbackItem != null &&
                                  _controller.canPlay &&
                                  !_controller.playbackBusy
                              ? () {
                                  _searchFocusNode.unfocus();
                                  _play(_activeSearchHit!.playbackItem!);
                                }
                              : null,
                          notice: _searchNotice,
                          isFullText:
                              _selectedView == RecordContentView.fullText,
                          viewSwitcher: PopupMenuButton<RecordContentView>(
                            key: const Key('detail-search-view-menu'),
                            tooltip: l10n.switchSearchView,
                            initialValue: _selectedView,
                            onSelected: _changeSelectedView,
                            icon: const Icon(Icons.manage_search_rounded),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                key: Key('detail-search-view-timeline'),
                                value: RecordContentView.timeline,
                                child: Text(l10n.timeline),
                              ),
                              PopupMenuItem(
                                key: Key('detail-search-view-fulltext'),
                                value: RecordContentView.fullText,
                                child: Text(l10n.fullText),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        SafeArea(
                          top: false,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _handleDetailScroll,
                            child: RefreshIndicator(
                              onRefresh: _controller.refreshContent,
                              child: _body(context),
                            ),
                          ),
                        ),
                        if (_showsReturnToPlayback)
                          Positioned(
                            right: 20,
                            bottom: 16,
                            child: FilledButton.tonalIcon(
                              key: const Key('detail-return-to-playback'),
                              onPressed: _returnToPlaybackPosition,
                              icon: const Icon(Icons.my_location_rounded),
                              label: Text(l10n.backToPlaybackPosition),
                            ),
                          ),
                        if (_deleting) const _DeletingOverlay(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: _PlaybackBar(
              controller: _controller,
              showAi: _canUseAi,
              onAi:
                  _deleting ||
                      _aiOpen ||
                      _aiSummaryBusy ||
                      _aiEngine.busy ||
                      _aiEngine.dirty
                  ? null
                  : _openAi,
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (_controller.loadingTimeline && _controller.timeline.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _controller.timeline;
    final transcripts = committedTranscripts(items);
    final timelineProjection = projectTimelineForDisplay(
      timeline: items,
      refinement: _controller.fullTextRefinement,
      preference: _timelineTextPreference,
    );
    _updateTimelineTurns(timelineProjection);
    final totalCount = switch (_selectedView) {
      RecordContentView.timeline => _turns.length,
      RecordContentView.fullText => transcripts.length,
      RecordContentView.aiSummary => 0,
    };
    final count = _selectedView == RecordContentView.timeline
        ? _visibleCount.clamp(0, totalCount)
        : totalCount;
    final visibleTimelineItems = _turns.take(count).toList(growable: false);
    final virtualFullText =
        _selectedView == RecordContentView.fullText &&
        (_displayFullText.text.length > 8000 ||
            _fullTextAttachments.isNotEmpty);
    final children = <Widget>[
      _SessionHeader(
        session: _session,
        refinementReady: _controller.fullTextRefinement.document != null,
      ),
      if (_showSavedConfirmation) ...[
        const SizedBox(height: 12),
        _CaptureSavedBanner(
          hasGaps:
              _session.hasConfirmedGaps ||
              _session.status == SessionStatus.completedWithGaps,
        ),
      ],
      if (_session.hasConfirmedGaps ||
          _session.status == SessionStatus.completedWithGaps) ...[
        const SizedBox(height: 12),
        const _IntegrityWarning(),
      ],
      if (_session.importedFromSessionId.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text(l10n.thisImportedRecordingPreservesTheOriginalAudio),
          ),
        ),
      ],
      if (widget.recoveryOutcome != null) ...[
        const SizedBox(height: 12),
        _RecoveryResultBanner(
          outcome: widget.recoveryOutcome!,
          transcriptionFailed: widget.recoveryTranscriptionFailed,
        ),
      ],
      if (_hasProcessingNotice) ...[
        const SizedBox(height: 12),
        _TranscriptionBanner(
          phase: _transcriptionPhase,
          failed:
              _controller.fullTextRefinement.status ==
              FullTextRefinementStatus.failed,
        ),
      ],
      if (_controller.timelineError != null) ...[
        const SizedBox(height: 12),
        _TimelineError(onRetry: _controller.refreshTimeline),
      ],
      const SizedBox(height: 22),
      RecordContentSwitcher(
        groupName: 'detail',
        selected: _selectedView,
        onChanged: _changeSelectedView,
        showAiSummary: _canUseAi,
      ),
      if (_selectedView == RecordContentView.timeline) ...[
        const SizedBox(height: 14),
        _SpeakerDiarizationPanel(
          snapshot: _controller.speakerDiarization,
          loading: _controller.loadingSpeakerDiarization,
          busy: _controller.speakerDiarizationBusy,
          canAnalyze:
              _controller.canPlay &&
              !widget.coordinator.hasActiveCapture &&
              !widget.coordinator.isBusy &&
              !widget.coordinator.isModelOperationActive &&
              !widget.gateway.isTranscriptionFinishing(_session.sessionId),
          onAnalyze: _startSpeakerAnalysis,
          onInstall: widget.onOpenModels == null ? null : _openModelsAndRefresh,
          onRebuild: _rebuildSpeakerAnalysis,
          onDelete: _confirmDeleteSpeakerResult,
          onEdit: _editSpeaker,
          onUndo: _undoSpeakerEdit,
          editError: _controller.speakerEditError,
        ),
      ],
      const SizedBox(height: 18),
      if (_selectedView == RecordContentView.timeline)
        _TimelineTextHeader(
          projection: timelineProjection,
          preference: _timelineTextPreference,
          itemCount: totalCount,
          suppressProcessingStatus: _hasProcessingNotice,
          onChanged: _changeTimelineTextPreference,
        )
      else if (_selectedView == RecordContentView.fullText)
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.continuousTranscript,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              l10n.segments((totalCount).toString()),
              style: const TextStyle(color: ProductColors.mutedInk),
            ),
          ],
        ),
      if (_selectedView == RecordContentView.fullText)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: const Key('fulltext-refine-action'),
            onPressed: _canRefine ? _startManualRefinement : null,
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: Text(_refineLabel),
          ),
        ),
      if (_selectedView != RecordContentView.aiSummary)
        const SizedBox(height: 12),
      if (_selectedView == RecordContentView.aiSummary)
        SessionAiSummaryPane(
          key: ValueKey('ai-summary-${_session.sessionId}'),
          sessionId: _session.sessionId,
          services: _aiServices,
          store: _aiDocumentStore,
          engine: _aiEngine,
          loadSource: _loadAiSource,
          sourceVersion: _controller.speakerDiarization.document == null
              ? ''
              : speakerTextVersion(_controller.speakerDiarization.document!),
          onBusyChanged: (busy) {
            if (mounted && _aiSummaryBusy != busy) {
              setState(() => _aiSummaryBusy = busy);
            }
          },
        )
      else if (_selectedView == RecordContentView.fullText)
        RefinedTranscriptFullText(
          snapshot: _controller.fullTextRefinement,
          headerOnly: virtualFullText,
          fallbackItems: transcripts,
          showStatus: false,
          textBuilder: (text) => SearchableFullText(
            key: _fullTextContentKey,
            text: _displayFullText.text,
            query: _searchOpen ? _searchQuery : '',
            activeRange: _searchOpen ? _activeSearchHit?.range : null,
          ),
        )
      else if (timelineProjection.items.isEmpty)
        const _EmptyTimeline()
      else
        ...List<Widget>.generate(visibleTimelineItems.length, (index) {
          final turn = visibleTimelineItems[index];
          final displayItem = turn.first;
          return KeyedSubtree(
            key: _timelineItemKey(displayItem.source.playbackId),
            child: ProductTimelineRow(
              item: displayItem.source,
              isFirst: index == 0,
              isLast: index == visibleTimelineItems.length - 1,
              displayText: turn.text,
              transcriptTextKey: _timelineTextKeys.putIfAbsent(
                displayItem.source.playbackId,
                GlobalKey.new,
              ),
              searchQuery: _searchOpen ? _searchQuery : '',
              activeSearchRange: _searchOpen
                  ? turn.rangeFor(
                      _activeSearchHit?.playbackItem?.playbackId,
                      _activeSearchHit?.range,
                    )
                  : null,
              selected: turn.contains(_controller.currentPlaybackItemId),
              canPlay: _controller.canPlay && !_controller.playbackBusy,
              onPlay: () => _play(displayItem.source),
              onOpenImage:
                  displayItem.source.isImage && displayItem.source.isCommitted
                  ? () => _openImage(displayItem.source)
                  : null,
              speakerLabel: turn.speakerLabel,
            ),
          );
        }),
      if (_selectedView != RecordContentView.aiSummary && count < totalCount)
        OutlinedButton(
          key: const Key('load-more-product-timeline'),
          onPressed: () => setState(() => _visibleCount += _pageSize),
          child: Text(
            l10n.loadMoreRemaining(
              (totalCount - count).toString(),
              (_selectedView == RecordContentView.timeline
                      ? l10n.items625
                      : l10n.segments626)
                  .toString(),
            ),
          ),
        ),
    ];
    final storageKey = PageStorageKey(
      'detail-${_session.sessionId}-${_selectedView.name}',
    );
    return KeyedSubtree(
      key: const Key('product-session-detail'),
      child: SizedBox(
        key: _listKey,
        child: virtualFullText
            ? VirtualFullText(
                key: _virtualFullTextKey,
                storageKey: storageKey,
                text: _displayFullText.text,
                attachments: _fullTextAttachments,
                onOpenImage: _openImage,
                onPlay: _controller.canPlay && !_controller.playbackBusy
                    ? _play
                    : null,
                onTimeline: (item) {
                  _changeSelectedView(RecordContentView.timeline);
                  _scheduleRevealPlaybackItem(
                    item.playbackId,
                    forceAlignment: true,
                    forNavigation: true,
                  );
                },
                query: _searchOpen ? _searchQuery : '',
                activeRange: _searchOpen ? _activeSearchHit?.range : null,
                controller: _fullTextScrollController,
                header: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              )
            : ListView(
                key: storageKey,
                controller: _scrollController,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
                children: children,
              ),
      ),
    );
  }

  void _updateTimelineTurns(TimelineDisplayProjection projection) {
    if (identical(_turnSources, _controller.timeline) &&
        identical(_turnRefinement, _controller.fullTextRefinement) &&
        identical(_turnSpeakers, _controller.speakerDiarization.document) &&
        _turnPreference == _timelineTextPreference) {
      return;
    }
    _turnSources = _controller.timeline;
    _turnRefinement = _controller.fullTextRefinement;
    _turnSpeakers = _controller.speakerDiarization.document;
    _turnPreference = _timelineTextPreference;
    final speakers = _controller.speakerDiarization.document;
    _turns = groupTimelineTurns(
      projection.items,
      speakers: speakers?.sessionId == _session.sessionId ? speakers : null,
    );
    _turnByItem.clear();
    for (final turn in _turns) {
      for (final item in turn.items) {
        _turnByItem[item.source.playbackId] = turn;
      }
    }
  }

  String _turnId(String id) => _turnByItem[id]?.first.source.playbackId ?? id;
  GlobalKey _timelineItemKey(String id) =>
      _timelineItemKeys.putIfAbsent(_turnId(id), GlobalKey.new);
  GlobalKey? _mountedTimelineKey(String id) => _timelineItemKeys[_turnId(id)];

  Rect? _turnTextRect(String id, {required bool forSearch}) {
    final turn = _turnByItem[id];
    if (turn == null) return null;
    final range = forSearch
        ? turn.rangeFor(id, _activeSearchHit?.range)
        : turn.rangeFor(id, const SearchTextRange(0, 1));
    if (range == null) return null;
    final root = _timelineTextKeys[_turnId(id)]?.currentContext
        ?.findRenderObject();
    RenderParagraph? paragraph;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        paragraph = object;
      } else if (paragraph == null) {
        object.visitChildren(visit);
      }
    }

    if (root == null || !root.attached) return null;
    visit(root);
    final render = paragraph;
    if (render == null) return null;
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    return boxes.isEmpty
        ? null
        : boxes.first.toRect().shift(render.localToGlobal(Offset.zero));
  }

  Future<void> _editSpeaker(String speakerId) async {
    final document = _controller.speakerDiarization.document;
    if (document == null || _controller.speakerDiarizationBusy) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SpeakerEditorSheet(
        document: document,
        speakerId: speakerId,
        onSave: (edit) async {
          final saved = await _controller.editSpeakers(document, edit);
          return saved
              ? null
              : _controller.speakerEditError ??
                    l10n.resultsAreBeingProcessedReopenThemShortly;
        },
      ),
    );
  }

  Future<void> _undoSpeakerEdit() async {
    final document = _controller.speakerDiarization.document;
    if (document != null) {
      await _controller.editSpeakers(document, const SpeakerEdit.undo());
    }
  }

  Future<void> _confirmDeleteSpeakerResult() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteSpeakerAnalysisResults),
        content: Text(l10n.analysisLabelsNamesMergesAndUndoHistory),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('confirm-delete-speaker-result'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.deleteResults),
          ),
        ],
      ),
    );
    if (approved == true) await _controller.deleteSpeakerDiarization();
  }

  Future<void> _startManualRefinement() async {
    if (!_canRefine) return;
    final force = _controller.fullTextRefinement.document != null;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_refineLabel),
        content: SingleChildScrollView(
          child: Text(
            '${l10n.manualRefinementExplanation}${_session.durationMs > 30 * 60 * 1000 ? "\n\n${l10n.manualRefinementLongRecording}" : ""}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('confirm-fulltext-refinement'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.manualRefinementConfirm),
          ),
        ],
      ),
    );
    if (!mounted || approved != true || !_canRefine) return;
    setState(() => _manualRefinementBusy = true);
    final job = widget.gateway.refineFullText(
      sessionId: _session.sessionId,
      directory: _session.directory,
      forceRebuild: force,
    );
    _syncTranscriptionPolling();
    setState(() {});
    try {
      await job;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) {
        await _controller.refreshContent();
        if (mounted) setState(() => _manualRefinementBusy = false);
      }
    }
  }

  Future<void> _startSpeakerAnalysis() =>
      _chooseSpeakerAnalysisMode(rebuild: false);

  Future<void> _rebuildSpeakerAnalysis() =>
      _chooseSpeakerAnalysisMode(rebuild: true);

  Future<void> _chooseSpeakerAnalysisMode({required bool rebuild}) async {
    final snapshot = _controller.speakerDiarization;
    final selected = await showModalBottomSheet<_SpeakerAnalysisChoice>(
      context: context,
      backgroundColor: ProductColors.paper,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SpeakerAnalysisSheet(
        initialSpeakerCount:
            snapshot.document?.requestedSpeakerCount ??
            snapshot.requestedSpeakerCount,
        rebuilding: rebuild,
        replacesEdits:
            snapshot.document?.hasUserEdits == true ||
            snapshot.document?.canUndoEdit == true,
      ),
    );
    if (!mounted || selected == null) return;
    if (rebuild) {
      await _controller.rebuildSpeakerDiarization(
        requestedSpeakerCount: selected.requestedSpeakerCount,
      );
    } else {
      await _controller.analyzeSpeakers(
        requestedSpeakerCount: selected.requestedSpeakerCount,
      );
    }
  }

  Future<void> _openModelsAndRefresh() async {
    await widget.onOpenModels?.call();
    if (mounted) await _controller.refreshSpeakerDiarization();
  }

  RecordSearchHit? get _activeSearchHit =>
      _activeSearchIndex >= 0 && _activeSearchIndex < _searchHits.length
      ? _searchHits[_activeSearchIndex]
      : null;

  List<RecordSearchHit> _searchCurrentView(
    TimelineDisplayProjection projection,
  ) {
    if (_selectedView == RecordContentView.aiSummary) return const [];
    if (_selectedView == RecordContentView.timeline) {
      return searchTimeline(projection, _searchQuery).toList(growable: false);
    }
    return _displayFullText.search(_searchQuery);
  }

  FullTextSearchDocument get _displayFullText {
    if (_fullTextDocument == null ||
        !identical(_fullTextSources, _controller.timeline) ||
        !identical(_fullTextRefinementSource, _controller.fullTextRefinement) ||
        !identical(
          _fullTextSpeakerSource,
          _controller.speakerDiarization.document,
        )) {
      _fullTextSources = _controller.timeline;
      _fullTextRefinementSource = _controller.fullTextRefinement;
      _fullTextSpeakerSource = _controller.speakerDiarization.document;
      final reading = composeFullTextReadingDocument(
        projectFullTextForSearch(
          sessionId: _session.sessionId,
          timeline: _controller.timeline,
          refinement: _controller.fullTextRefinement,
        ),
        _controller.timeline,
      );
      _fullTextDocument = reading.search;
      _fullTextAttachments = reading.attachments;
    }
    return _fullTextDocument!;
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      _initialSearchApplied = true;
      _playbackRevealGeneration += 1;
    });
    if (!_searchOpen) {
      _searchFocusNode.unfocus();
      return;
    }
    _refreshSearchHits(
      projectTimelineForDisplay(
        timeline: _controller.timeline,
        refinement: _controller.fullTextRefinement,
        preference: _timelineTextPreference,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) _searchFocusNode.requestFocus();
    });
  }

  void _changeSearchQuery(String query) {
    setState(() {
      _initialSearchApplied = true;
      _searchQuery = query;
      _searchNotice = null;
      _searchSelections.clear();
      _searchHits = _searchCurrentView(
        projectTimelineForDisplay(
          timeline: _controller.timeline,
          refinement: _controller.fullTextRefinement,
          preference: _timelineTextPreference,
        ),
      );
      _activeSearchIndex = _searchHits.isEmpty ? -1 : 0;
      _playbackRevealGeneration += 1;
    });
    if (_activeSearchHit != null) _selectSearchHit(0);
  }

  void _refreshSearchHits(TimelineDisplayProjection projection) {
    if (!_searchOpen) return;
    final changed =
        !identical(_lastSearchTimeline, _controller.timeline) ||
        !identical(_lastSearchRefinement, _controller.fullTextRefinement) ||
        !identical(
          _lastSearchSpeakers,
          _controller.speakerDiarization.document,
        ) ||
        _lastSearchPreference != _timelineTextPreference ||
        _lastSearchView != _selectedView;
    if (changed) {
      final previous = _searchSelections[_selectedView];
      _lastSearchTimeline = _controller.timeline;
      _lastSearchRefinement = _controller.fullTextRefinement;
      _lastSearchSpeakers = _controller.speakerDiarization.document;
      _lastSearchPreference = _timelineTextPreference;
      _lastSearchView = _selectedView;
      _searchHits = _searchCurrentView(projection);
      var retained = _searchHits.indexWhere(
        (hit) => hit.identity == previous?.identity,
      );
      if (retained < 0 && previous?.playbackItem != null) {
        retained = _searchHits.indexWhere(
          (hit) =>
              hit.playbackItem?.playbackId ==
              previous!.playbackItem!.playbackId,
        );
      }
      _activeSearchIndex = retained >= 0
          ? retained
          : _searchHits.isEmpty
          ? -1
          : 0;
      _searchSelections[_selectedView] = _activeSearchHit;
    }
    final target = widget.initialSearchTarget;
    if (target != null &&
        !_initialSearchApplied &&
        !_controller.loadingTimeline &&
        !_controller.loadingFullTextRefinement) {
      _initialSearchApplied = true;
      var index = _searchHits.indexWhere(
        (hit) =>
            hit.playbackItem?.playbackId == target.playbackId &&
            hit.range.start == target.matchStart,
      );
      if (index < 0) {
        index = _searchHits.indexWhere(
          (hit) => hit.playbackItem?.playbackId == target.playbackId,
        );
      }
      if (index >= 0) {
        _selectSearchHit(index);
      } else {
        _searchNotice = l10n.textChangedOrCouldNotBeRead;
      }
    }
  }

  void _navigateSearchHit(int index) {
    _searchFocusNode.unfocus();
    _selectSearchHit(index);
  }

  void _selectSearchHit(int index) {
    if (_searchHits.isEmpty) return;
    setState(() {
      _activeSearchIndex = index % _searchHits.length;
      _searchSelections[_selectedView] = _activeSearchHit;
      _followPlaybackPosition = false;
    });
    if (_selectedView == RecordContentView.fullText) {
      _scheduleRevealFullTextMatch();
      return;
    }
    _scheduleRevealPlaybackItem(
      _activeSearchHit!.playbackItem!.playbackId,
      forceAlignment: true,
      forSearch: true,
    );
  }

  bool get _showsReturnToPlayback =>
      _selectedView == RecordContentView.timeline &&
      !_followPlaybackPosition &&
      _controller.currentPlaybackItemId != null &&
      _controller.playback.isPrepared;

  bool _handleDetailScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _initialSearchApplied = true;
      _playbackRevealGeneration += 1;
    }
    if (_selectedView != RecordContentView.timeline ||
        _controller.currentPlaybackItemId == null ||
        !_controller.playback.isPrepared) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        _followPlaybackPosition) {
      _playbackRevealGeneration += 1;
      setState(() => _followPlaybackPosition = false);
    }
    return false;
  }

  void _changeSelectedView(RecordContentView view) {
    if (view == _selectedView) return;
    if (_searchOpen) _searchSelections[_selectedView] = _activeSearchHit;
    _searchFocusNode.unfocus();
    setState(() {
      _selectedView = view;
      if (view == RecordContentView.aiSummary) {
        _searchOpen = false;
        _searchHits = const [];
        _activeSearchIndex = -1;
      }
      _initialSearchApplied = true;
      _playbackRevealGeneration += 1;
      _followPlaybackPosition = false;
      _searchNotice = null;
    });
    if (view == RecordContentView.aiSummary) return;
    _refreshSearchHits(
      projectTimelineForDisplay(
        timeline: _controller.timeline,
        refinement: _controller.fullTextRefinement,
        preference: _timelineTextPreference,
      ),
    );
  }

  void _returnToPlaybackPosition() {
    final current = _controller.currentPlaybackItemId;
    if (current == null) return;
    setState(() => _followPlaybackPosition = true);
    _scheduleRevealPlaybackItem(current, forceAlignment: true);
  }

  void _scheduleRevealFullTextMatch() {
    final range = _activeSearchHit?.range;
    if (range == null) return;
    _revealFullTextMatchAfterBuild(range, ++_playbackRevealGeneration);
  }

  void _revealFullTextMatchAfterBuild(
    SearchTextRange range,
    int generation, {
    int attempt = 0,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_searchOpen ||
          _selectedView != RecordContentView.fullText ||
          generation != _playbackRevealGeneration ||
          !_fullTextScrollController.hasClients) {
        return;
      }
      final position = _fullTextScrollController.position;
      final virtualReader = _virtualFullTextKey.currentState;
      final rect =
          virtualReader?.matchRect(range) ??
          _fullTextContentKey.currentState?.matchRect(range);
      if (rect == null) {
        if (attempt >= 40) return;
        final next =
            (virtualReader?.estimateOffset(range) ??
                    (position.pixels + position.viewportDimension * 0.8))
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        if ((next - position.pixels).abs() < 1) return;
        _fullTextScrollController.jumpTo(next.toDouble());
        _revealFullTextMatchAfterBuild(range, generation, attempt: attempt + 1);
        return;
      }
      final viewport =
          _fullTextListKey.currentContext?.findRenderObject() as RenderBox?;
      if (viewport == null || !viewport.attached) return;
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final target =
          (position.pixels +
                  rect.top -
                  viewportTop -
                  position.viewportDimension * 0.3)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      unawaited(
        _fullTextScrollController.animateTo(
          target.toDouble(),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _scheduleRevealPlaybackItem(
    String playbackId, {
    bool forceAlignment = false,
    bool forSearch = false,
    bool forNavigation = false,
  }) {
    if (_selectedView != RecordContentView.timeline) return;
    final itemIndex = _controller.timeline.indexWhere(
      (item) => item.playbackId == playbackId,
    );
    if (itemIndex < 0) return;
    final groupIndex = _turns.indexWhere((turn) => turn.contains(playbackId));
    final displayIndex = groupIndex < 0 ? itemIndex : groupIndex;
    final requiredCount =
        ((displayIndex + 1 + _pageSize - 1) ~/ _pageSize) * _pageSize;
    if (requiredCount > _visibleCount && mounted) {
      setState(() => _visibleCount = requiredCount);
    }
    final generation = ++_playbackRevealGeneration;
    _revealPlaybackItemAfterBuild(
      playbackId,
      itemIndex: itemIndex,
      generation: generation,
      forceAlignment: forceAlignment,
      forSearch: forSearch,
      forNavigation: forNavigation,
    );
  }

  void _revealPlaybackItemAfterBuild(
    String playbackId, {
    required int itemIndex,
    required int generation,
    required bool forceAlignment,
    required bool forSearch,
    required bool forNavigation,
    int attempt = 0,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _playbackRevealGeneration ||
          (!forSearch && !forNavigation && !_followPlaybackPosition) ||
          (forSearch && !_searchOpen) ||
          _selectedView != RecordContentView.timeline) {
        return;
      }
      final itemContext = _mountedTimelineKey(playbackId)?.currentContext;
      if (itemContext == null) {
        if (!_scrollController.hasClients ||
            attempt > _controller.timeline.length) {
          return;
        }
        final mountedIndexes = <int>[];
        for (var index = 0; index < _controller.timeline.length; index += 1) {
          final id = _controller.timeline[index].playbackId;
          if (_mountedTimelineKey(id)?.currentContext != null) {
            mountedIndexes.add(index);
          }
        }
        final moveForward =
            mountedIndexes.isEmpty || itemIndex > mountedIndexes.last;
        final position = _scrollController.position;
        final step = position.viewportDimension * 0.8;
        final target = (position.pixels + (moveForward ? step : -step)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((target - position.pixels).abs() < 1) return;
        unawaited(
          _scrollController
              .animateTo(
                target.toDouble(),
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
              )
              .then((_) {
                if (!mounted || generation != _playbackRevealGeneration) {
                  return;
                }
                _revealPlaybackItemAfterBuild(
                  playbackId,
                  itemIndex: itemIndex,
                  generation: generation,
                  forceAlignment: forceAlignment,
                  forSearch: forSearch,
                  forNavigation: forNavigation,
                  attempt: attempt + 1,
                );
              }),
        );
        return;
      }
      final viewport =
          _listKey.currentContext?.findRenderObject() as RenderBox?;
      final box = itemContext.findRenderObject() as RenderBox?;
      if (viewport == null ||
          box == null ||
          !viewport.attached ||
          !box.attached) {
        return;
      }
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final viewportBottom = viewportTop + viewport.size.height;
      final textRect = _turnTextRect(playbackId, forSearch: forSearch);
      final itemTop = textRect?.top ?? box.localToGlobal(Offset.zero).dy;
      final itemBottom = textRect?.bottom ?? itemTop + box.size.height;
      final fullyVisible =
          itemTop >= viewportTop + 8 && itemBottom <= viewportBottom - 8;
      if (fullyVisible && !forceAlignment) return;
      if (textRect != null) {
        final position = _scrollController.position;
        final target =
            (position.pixels +
                    itemTop -
                    viewportTop -
                    position.viewportDimension * 0.3)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        unawaited(
          _scrollController.animateTo(
            target.toDouble(),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          itemContext,
          alignment: 0.3,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  _VisibleTimelineAnchor? _captureVisibleAnchor() {
    if (_selectedView != RecordContentView.timeline ||
        !_scrollController.hasClients) {
      return null;
    }
    final viewport = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return null;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewport.size.height;
    _VisibleTimelineAnchor? fallback;
    for (final item in _controller.timeline) {
      final key = _mountedTimelineKey(item.playbackId);
      final box = key?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom > viewportTop && top < viewportBottom) {
        // Track the original fragment's text, since regrouping can remove its
        // standalone card or put earlier fragments above it in the same card.
        final textRect = _turnTextRect(item.playbackId, forSearch: false);
        final anchorTop = textRect?.top ?? top;
        final anchorBottom = textRect?.bottom ?? bottom;
        final anchor = _VisibleTimelineAnchor(
          item.playbackId,
          anchorTop - viewportTop,
        );
        fallback ??= anchor;
        if (anchorBottom > viewportTop && anchorTop < viewportBottom) {
          return anchor;
        }
      }
    }
    return fallback;
  }

  void _restoreVisibleAnchorAfterBuild(
    _VisibleTimelineAnchor? anchor, {
    int attempt = 0,
  }) {
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _selectedView != RecordContentView.timeline ||
          !_timelineScrollController.hasClients) {
        return;
      }
      final groupIndex = _turns.indexWhere(
        (turn) => turn.contains(anchor.playbackId),
      );
      if (groupIndex >= _visibleCount) {
        setState(
          () => _visibleCount = ((groupIndex ~/ _pageSize) + 1) * _pageSize,
        );
        _restoreVisibleAnchorAfterBuild(anchor);
        return;
      }
      final viewport =
          _listKey.currentContext?.findRenderObject() as RenderBox?;
      final box =
          _mountedTimelineKey(
                anchor.playbackId,
              )?.currentContext?.findRenderObject()
              as RenderBox?;
      if (viewport == null || !viewport.attached) return;
      if (box == null || !box.attached) {
        // A large regroup can move the source outside ListView's mounted
        // children. Materialize its group before restoring the text position.
        if (groupIndex < 0 || attempt > _controller.timeline.length * 2) return;
        final mountedIndexes = <int>[
          for (var i = 0; i < _turns.length; i++)
            if (_mountedTimelineKey(
                  _turns[i].first.source.playbackId,
                )?.currentContext !=
                null)
              i,
        ];
        final forward =
            mountedIndexes.isEmpty || groupIndex > mountedIndexes.last;
        final position = _scrollController.position;
        final target =
            (position.pixels +
                    (forward ? 1 : -1) * position.viewportDimension * 0.8)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        if ((target - position.pixels).abs() < 1) return;
        _scrollController.jumpTo(target.toDouble());
        _restoreVisibleAnchorAfterBuild(anchor, attempt: attempt + 1);
        return;
      }
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final textRect = _turnTextRect(anchor.playbackId, forSearch: false);
      final currentTop =
          (textRect?.top ?? box.localToGlobal(Offset.zero).dy) - viewportTop;
      final correction = currentTop - anchor.distanceFromViewportTop;
      if (correction.abs() < 0.5) return;
      final position = _scrollController.position;
      final target = (_scrollController.offset + correction).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _scrollController.jumpTo(target.toDouble());
    });
  }

  void _changeTimelineTextPreference(TimelineTextPreference preference) {
    if (preference == _timelineTextPreference) return;
    final anchor = _captureVisibleAnchor();
    setState(() => _timelineTextPreference = preference);
    _refreshSearchHits(
      projectTimelineForDisplay(
        timeline: _controller.timeline,
        refinement: _controller.fullTextRefinement,
        preference: preference,
      ),
    );
    _restoreVisibleAnchorAfterBuild(anchor);
  }

  Future<void> _play(TimelineItem item) async {
    if (!_followPlaybackPosition) {
      setState(() => _followPlaybackPosition = true);
    }
    await _controller.playFrom(item);
    if (!mounted || _controller.playbackError == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.couldNotPlayThisPositionTryAgain)),
    );
  }

  void _openImage(TimelineItem item) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _OriginalImagePage(
          item: item,
          onPlay: () async {
            Navigator.of(context).pop();
            await _play(item);
          },
        ),
      ),
    );
  }

  Future<void> _showExportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ExportSheet(controller: _controller),
    );
  }

  Future<void> _showSessionActions() async {
    final action = await showModalBottomSheet<_SessionAction>(
      context: context,
      useSafeArea: true,
      builder: (_) => _SessionActionsSheet(
        canMutate:
            _canMutateSession &&
            !_controller.exporting &&
            !widget.coordinator.isBusy,
        canExport: _session.exportAvailable,
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SessionAction.rename:
        await _rename();
        return;
      case _SessionAction.export:
        await _showExportSheet();
        return;
      case _SessionAction.delete:
        await _confirmDelete();
        return;
    }
  }

  bool get _canMutateSession =>
      !_session.status.isActive && _session.status != SessionStatus.recovering;

  Future<void> _rename() async {
    final renamed = await showModalBottomSheet<SessionSummary>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _RenameSessionSheet(
        session: _session,
        coordinator: widget.coordinator,
      ),
    );
    if (renamed != null && mounted) setState(() => _session = renamed);
  }

  Future<void> _confirmDelete() async {
    if (_controller.exporting || _controller.sharing) return;
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.permanentlyDeleteThisRecording),
        content: Text(l10n.thisDeletesTheDatabaseOriginalAudioPhotos),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _DeleteChoice.cancel),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('export-before-product-delete'),
            onPressed: _session.exportAvailable
                ? () => Navigator.pop(context, _DeleteChoice.exportFirst)
                : null,
            child: Text(l10n.exportFirst),
          ),
          FilledButton(
            key: const Key('confirm-product-delete'),
            onPressed: () => Navigator.pop(context, _DeleteChoice.delete),
            style: FilledButton.styleFrom(
              backgroundColor: ProductColors.vermilion,
            ),
            child: Text(l10n.deletePermanently),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == _DeleteChoice.cancel) return;
    if (choice == _DeleteChoice.exportFirst) {
      await _controller.generateExport();
      if (mounted) await _showExportSheet();
      return;
    }
    setState(() => _deleting = true);
    try {
      if (_controller.playback.isPrepared) {
        await _controller.stopPlayback();
        if (_controller.playbackError != null) {
          throw StateError(l10n.thePlayerHasNotStoppedSafely);
        }
      }
      await widget.coordinator.deleteSession(_session);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.couldNotDeleteOriginalContentIsPreserved)),
      );
    }
  }
}

class _VisibleTimelineAnchor {
  const _VisibleTimelineAnchor(this.playbackId, this.distanceFromViewportTop);

  final String playbackId;
  final double distanceFromViewportTop;
}

class _SpeakerDiarizationPanel extends StatelessWidget {
  const _SpeakerDiarizationPanel({
    required this.snapshot,
    required this.loading,
    required this.busy,
    required this.canAnalyze,
    required this.onAnalyze,
    required this.onRebuild,
    required this.onDelete,
    required this.onEdit,
    required this.onUndo,
    this.editError,
    this.onInstall,
  });

  final SpeakerDiarizationSnapshot snapshot;
  final bool loading;
  final bool busy;
  final bool canAnalyze;
  final Future<void> Function() onAnalyze;
  final Future<void> Function() onRebuild;
  final Future<void> Function() onDelete;
  final Future<void> Function(String speakerId) onEdit;
  final Future<void> Function() onUndo;
  final String? editError;
  final Future<void> Function()? onInstall;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final document = snapshot.document;
    final processing =
        busy || snapshot.status == SpeakerDiarizationStatus.processing;
    final modelMissing =
        snapshot.status == SpeakerDiarizationStatus.unavailable &&
        snapshot.message?.contains(l10n.notInstalled) == true;
    if (document == null &&
        !loading &&
        !processing &&
        snapshot.message == null) {
      return Card(
        key: const Key('speaker-diarization-panel'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final summary = Row(
                children: [
                  const Icon(
                    Icons.record_voice_over_rounded,
                    color: ProductColors.forest,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.speakerAnalysis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.distinguishSpeakersInTheRecording,
                          style: const TextStyle(
                            color: ProductColors.mutedInk,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              final action = OutlinedButton(
                key: const Key('analyze-speakers'),
                onPressed: canAnalyze ? () => unawaited(onAnalyze()) : null,
                child: Text(l10n.analyze),
              );
              if (constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(12) > 16) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    summary,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 8),
                  action,
                ],
              );
            },
          ),
        ),
      );
    }
    return Card(
      key: const Key('speaker-diarization-panel'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: ProductColors.forestSoft,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(
                    Icons.record_voice_over_rounded,
                    color: ProductColors.forest,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        document == null
                            ? l10n.speakerAnalysis
                            : l10n.speakerAnalysisSpeakers(
                                (document.speakerCount).toString(),
                              ),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        document?.hasUserEdits == true
                            ? l10n.manuallyAdjustedAppliesOnlyToThisRecording
                            : document?.requestedSpeakerCount == null
                            ? l10n.localAnalysisAutomaticCountNoIdentityRecognition
                            : l10n.localAnalysisSpeakersSpecified(
                                (document!.requestedSpeakerCount).toString(),
                              ),
                        style: const TextStyle(
                          color: ProductColors.mutedInk,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (document != null && !processing)
                  PopupMenuButton<String>(
                    key: const Key('speaker-result-actions'),
                    tooltip: l10n.speakerAnalysisActions,
                    onSelected: (value) {
                      if (value == 'rebuild') unawaited(onRebuild());
                      if (value == 'delete') unawaited(onDelete());
                      if (value == 'undo') unawaited(onUndo());
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rebuild',
                        enabled: canAnalyze,
                        child: Text(l10n.analyzeAgain),
                      ),
                      PopupMenuItem(
                        key: const Key('undo-speaker-edit'),
                        value: 'undo',
                        enabled: document.canUndoEdit,
                        child: Text(l10n.undoLastChange),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: canAnalyze,
                        child: Text(l10n.deleteResults),
                      ),
                    ],
                  ),
              ],
            ),
            if (loading || processing) ...[
              const SizedBox(height: 13),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                loading
                    ? l10n.loadingLocalResults
                    : snapshot.status != SpeakerDiarizationStatus.processing
                    ? l10n.savingSpeakerResults
                    : snapshot.message != null
                    ? '${snapshot.message}\n${l10n.speakerAnalysisLifecycleHint}'
                    : snapshot.requestedSpeakerCount == null
                    ? l10n.analyzingProcessingContinuesIfYouLeaveThis
                    : l10n.analyzingWithSpeakersProcessingContinuesIfYou(
                        (snapshot.requestedSpeakerCount).toString(),
                      ),
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 12,
                ),
              ),
            ] else if (document != null) ...[
              if (editError != null) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.changesWereNotSaved((editError).toString()),
                  key: const Key('speaker-edit-error'),
                  style: const TextStyle(color: ProductColors.vermilion),
                ),
              ],
              if (snapshot.message != null) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.theSpeakerOperationDidNotFinishPrevious(
                    (snapshot.message).toString(),
                  ),
                  key: const Key('speaker-rebuild-error'),
                  style: const TextStyle(color: ProductColors.vermilion),
                ),
              ],
              if (document.requestedSpeakerCount != null &&
                  document.detectedSpeakerCount !=
                      document.requestedSpeakerCount) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.theNumberOfDistinguishableSpeakersDiffersFrom,
                  style: TextStyle(color: ProductColors.mutedInk),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final speakerId in document.speakerIds)
                    ActionChip(
                      key: Key('edit-$speakerId'),
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.edit_outlined, size: 15),
                      label: Text(localizedSpeakerName(document, speakerId)),
                      onPressed: () => unawaited(onEdit(speakerId)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                key: const Key('correct-speaker-count'),
                onPressed: canAnalyze ? () => unawaited(onRebuild()) : null,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(l10n.wrongCountAnalyzeAgainWithTheActual),
              ),
            ] else ...[
              const SizedBox(height: 11),
              Text(
                snapshot.message ??
                    l10n.distinguishSpeakersAndSeeTheirContributionsOn,
                style: TextStyle(
                  color: snapshot.status == SpeakerDiarizationStatus.failed
                      ? ProductColors.vermilion
                      : ProductColors.mutedInk,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 11),
              OutlinedButton.icon(
                key: Key(
                  modelMissing
                      ? 'install-speaker-diarization-model'
                      : 'analyze-speakers',
                ),
                onPressed: !canAnalyze
                    ? null
                    : modelMissing && onInstall != null
                    ? () => unawaited(onInstall!())
                    : () => unawaited(onAnalyze()),
                icon: Icon(
                  modelMissing
                      ? Icons.download_rounded
                      : Icons.graphic_eq_rounded,
                ),
                label: Text(modelMissing ? l10n.openModelCenter : l10n.analyze),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SpeakerAnalysisChoice {
  const _SpeakerAnalysisChoice(this.requestedSpeakerCount);

  final int? requestedSpeakerCount;
}

class _SpeakerAnalysisSheet extends StatefulWidget {
  const _SpeakerAnalysisSheet({
    required this.initialSpeakerCount,
    required this.rebuilding,
    this.replacesEdits = false,
  });

  final int? initialSpeakerCount;
  final bool rebuilding;
  final bool replacesEdits;

  @override
  State<_SpeakerAnalysisSheet> createState() => _SpeakerAnalysisSheetState();
}

class _SpeakerAnalysisSheetState extends State<_SpeakerAnalysisSheet> {
  int? _speakerCount;
  bool _choosingCount = false;

  @override
  void initState() {
    super.initState();
    _speakerCount = widget.initialSpeakerCount;
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.rebuilding
                          ? l10n.analyzeSpeakersAgain
                          : l10n.speakerAnalysis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.distinguishDifferentSpeakersInTheRecording,
                      style: TextStyle(
                        color: ProductColors.mutedInk,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _countSelector(context),
                    const SizedBox(height: 14),
                    Text(
                      widget.replacesEdits
                          ? l10n.successfulAnalysisWillReplaceCurrentNamesMerges
                          : l10n.analysisDoesNotChangeAudioOrText,
                      key: widget.replacesEdits
                          ? const Key('speaker-rebuild-replaces-edits')
                          : null,
                      style: TextStyle(
                        color: widget.replacesEdits
                            ? ProductColors.vermilion
                            : ProductColors.mutedInk,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: FilledButton.icon(
                key: const Key('confirm-speaker-analysis'),
                onPressed: () => Navigator.pop(
                  context,
                  _SpeakerAnalysisChoice(_speakerCount),
                ),
                icon: const Icon(Icons.graphic_eq_rounded),
                label: Text(
                  widget.rebuilding
                      ? l10n.replaceAnalysisResults
                      : l10n.analyze,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _countSelector(BuildContext context) {
    return Material(
      color: ProductColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: ProductColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: _choosingCount,
            child: InkWell(
              key: const Key('speaker-count-selector'),
              onTap: () => setState(() => _choosingCount = !_choosingCount),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.people_outline_rounded,
                      color: ProductColors.forest,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.speakerCount,
                            style: TextStyle(
                              color: ProductColors.mutedInk,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _speakerCount == null
                                ? l10n.automatic
                                : l10n.speakers((_speakerCount).toString()),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _choosingCount
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: ProductColors.mutedInk,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_choosingCount)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  _countOption(null, l10n.automaticChooseWhenUnsure),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns =
                          (constraints.maxWidth /
                                  (64 *
                                      MediaQuery.textScalerOf(
                                        context,
                                      ).scale(1)))
                              .floor()
                              .clamp(2, 4);
                      final width =
                          (constraints.maxWidth - (columns - 1) * 8) / columns;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (
                            var count = 1;
                            count <= maximumRequestedSpeakerCount;
                            count++
                          )
                            SizedBox(
                              width: width,
                              child: _countOption(
                                count,
                                l10n.speakers((count).toString()),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _countOption(int? count, String label) {
    final selected = _speakerCount == count;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? ProductColors.forestSoft : ProductColors.paper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? ProductColors.forest : ProductColors.line,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key(
            count == null ? 'speaker-count-auto' : 'speaker-count-$count',
          ),
          onTap: () => setState(() {
            _speakerCount = count;
            _choosingCount = false;
          }),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? ProductColors.forest : ProductColors.ink,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineTextHeader extends StatelessWidget {
  const _TimelineTextHeader({
    required this.projection,
    required this.preference,
    required this.itemCount,
    required this.suppressProcessingStatus,
    required this.onChanged,
  });

  final TimelineDisplayProjection projection;
  final TimelineTextPreference preference;
  final int itemCount;
  final bool suppressProcessingStatus;
  final ValueChanged<TimelineTextPreference> onChanged;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final status = suppressProcessingStatus
        ? null
        : projection.statusMessage(preference: preference);
    final count = Text(
      l10n.items((itemCount).toString()),
      style: const TextStyle(color: ProductColors.mutedInk),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.timeline,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (projection.canSelectRefined)
              _TimelineTextLayerMenu(
                preference: preference,
                onChanged: onChanged,
              )
            else if (status == null)
              count,
          ],
        ),
        if (status != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  liveRegion:
                      projection.availability ==
                      TimelineDisplayAvailability.processing,
                  child: Text(
                    status,
                    key: const Key('timeline-text-layer-status'),
                    style: const TextStyle(
                      color: ProductColors.mutedInk,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              count,
            ],
          ),
        ],
      ],
    );
  }
}

class _TimelineTextLayerMenu extends StatelessWidget {
  const _TimelineTextLayerMenu({
    required this.preference,
    required this.onChanged,
  });

  final TimelineTextPreference preference;
  final ValueChanged<TimelineTextPreference> onChanged;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final label = preference == TimelineTextPreference.refined
        ? l10n.refinedText
        : l10n.originalTranscript;
    return Semantics(
      button: true,
      label: l10n.timelineTextLayer,
      value: label,
      child: PopupMenuButton<TimelineTextPreference>(
        key: const Key('timeline-text-layer-menu'),
        initialValue: preference,
        tooltip: l10n.switchTimelineTextLayerCurrently((label).toString()),
        onSelected: onChanged,
        itemBuilder: (context) => [
          _menuItem(
            value: TimelineTextPreference.refined,
            label: l10n.refinedText,
            selected: preference == TimelineTextPreference.refined,
            key: const Key('timeline-text-layer-refined'),
          ),
          _menuItem(
            value: TimelineTextPreference.live,
            label: l10n.originalTranscript,
            selected: preference == TimelineTextPreference.live,
            key: const Key('timeline-text-layer-live'),
          ),
        ],
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: ProductColors.forestSoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: ProductColors.forest,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down_rounded,
                color: ProductColors.forest,
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<TimelineTextPreference> _menuItem({
    required TimelineTextPreference value,
    required String label,
    required bool selected,
    required Key key,
  }) => PopupMenuItem<TimelineTextPreference>(
    key: key,
    value: value,
    child: Row(
      children: [
        SizedBox(
          width: 24,
          child: selected
              ? const Icon(
                  Icons.check_rounded,
                  size: 19,
                  color: ProductColors.forest,
                )
              : null,
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    ),
  );
}

enum _SessionAction { rename, export, delete }

enum _DeleteChoice { cancel, exportFirst, delete }

class _SessionActionsSheet extends StatelessWidget {
  const _SessionActionsSheet({
    required this.canMutate,
    required this.canExport,
  });

  final bool canMutate;
  final bool canExport;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('rename-product-session'),
            enabled: canMutate,
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.rename),
            onTap: () => Navigator.pop(context, _SessionAction.rename),
          ),
          ListTile(
            key: const Key('export-product-session-action'),
            enabled: canExport,
            leading: const Icon(Icons.ios_share_rounded),
            title: Text(l10n.exportMomentAI),
            onTap: () => Navigator.pop(context, _SessionAction.export),
          ),
          ListTile(
            key: const Key('delete-product-session'),
            enabled: canMutate,
            iconColor: ProductColors.vermilion,
            textColor: ProductColors.vermilion,
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(l10n.deletePermanently),
            subtitle: Text(l10n.alsoDeletesOriginalsAndOnDeviceExports),
            onTap: () => Navigator.pop(context, _SessionAction.delete),
          ),
        ],
      ),
    );
  }
}

class _RenameSessionSheet extends StatefulWidget {
  const _RenameSessionSheet({required this.session, required this.coordinator});

  final SessionSummary session;
  final AppCoordinator coordinator;

  @override
  State<_RenameSessionSheet> createState() => _RenameSessionSheetState();
}

class _RenameSessionSheetState extends State<_RenameSessionSheet> {
  late final TextEditingController _textController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.session.title);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final title = _textController.text.trim();
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.renameRecording,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(l10n.onlyTheDisplayNameChangesOriginalAudio),
          const SizedBox(height: 18),
          TextField(
            key: const Key('rename-product-session-input'),
            controller: _textController,
            autofocus: true,
            maxLength: 120,
            enabled: !_saving,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: l10n.recordingName,
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('save-product-session-name'),
              onPressed: !_saving && title.isNotEmpty ? _save : null,
              child: Text(_saving ? l10n.saving : l10n.saveName),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final title = _textController.text.trim();
    if (_saving || title.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final renamed = await widget.coordinator.renameSession(
        widget.session,
        title,
      );
      if (mounted) Navigator.pop(context, renamed);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = l10n.theNameWasNotChangedYourInput;
      });
    }
  }
}

class _DeletingOverlay extends StatelessWidget {
  const _DeletingOverlay();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Positioned.fill(
      child: ColoredBox(
        color: Color(0xAAFFFFFF),
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text(l10n.permanentlyDeleting),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecoveryResultBanner extends StatelessWidget {
  const _RecoveryResultBanner({
    required this.outcome,
    required this.transcriptionFailed,
  });

  final RecoveryOutcome outcome;
  final bool transcriptionFailed;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final hasGaps = outcome.hasConfirmedGaps;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: hasGaps ? ProductColors.amberSoft : ProductColors.forestSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hasGaps
                ? Icons.warning_amber_rounded
                : Icons.verified_user_outlined,
            color: hasGaps ? ProductColors.amber : ProductColors.forest,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.preserved(
                (hasGaps
                        ? (outcome.rpoIsUpperBound
                              ? l10n.recoveryCompleteRecordingEndedUnexpectedly
                              : l10n.recoveryCompleteGapsConfirmed)
                        : l10n.recoveryCompleteOriginalContentIsContinuous)
                    .toString(),
                (formatDuration(outcome.committedMs)).toString(),
                (!outcome.rpoKnown
                        ? l10n.theLengthOfTheUnsavedEndingIs
                        : outcome.rpoIsUpperBound
                        ? l10n.theUnsavedEndingIsAtMostAbout(
                            (outcome.rpoMs).toString(),
                          )
                        : l10n.finalGapMs((outcome.rpoMs).toString()))
                    .toString(),
                (transcriptionFailed
                        ? l10n.localTranscriptionIsNotComplete
                        : '')
                    .toString(),
              ),
              style: TextStyle(
                color: hasGaps ? ProductColors.amber : ProductColors.forest,
                height: 1.45,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({required this.session, required this.refinementReady});

  final SessionSummary session;
  final bool refinementReady;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final hasGaps =
        session.hasConfirmedGaps ||
        session.status == SessionStatus.completedWithGaps;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
      child: Row(
        children: [
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hasGaps
                  ? ProductColors.amberSoft
                  : ProductColors.forestSoft,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              hasGaps ? l10n.hasGaps : l10n.completed,
              style: TextStyle(
                color: hasGaps ? ProductColors.amber : ProductColors.forest,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _HeaderMeta(
                    icon: Icons.schedule_rounded,
                    label: formatSessionDate(session.startedAt),
                  ),
                  _HeaderMeta(
                    label: formatDuration(session.durationMs),
                    tabular: true,
                  ),
                  if (refinementReady)
                    _HeaderMeta(
                      icon: Icons.check_circle_outline_rounded,
                      label: l10n.refined,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderMeta extends StatelessWidget {
  const _HeaderMeta({this.icon, required this.label, this.tabular = false});

  final IconData? icon;
  final String label;
  final bool tabular;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    const color = ProductColors.mutedInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              fontFeatures: tabular
                  ? const [FontFeature.tabularFigures()]
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _CaptureSavedBanner extends StatelessWidget {
  const _CaptureSavedBanner({required this.hasGaps});

  final bool hasGaps;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Container(
      key: const Key('capture-saved-confirmation'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ProductColors.forestSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            color: ProductColors.forest,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hasGaps
                  ? l10n.continuousContentIsSafelySaved
                  : l10n.recordingSafelySaved,
              style: const TextStyle(
                color: ProductColors.forest,
                height: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IntegrityWarning extends StatelessWidget {
  const _IntegrityWarning();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ProductColors.amberSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: ProductColors.amber),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.thisRecordingHasConfirmedGapsTheTimeline,
              style: TextStyle(color: ProductColors.amber, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptionBanner extends StatelessWidget {
  const _TranscriptionBanner({required this.phase, required this.failed});

  final TranscriptionPhase phase;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final showFailure = phase == TranscriptionPhase.idle && failed;
    final message = showFailure
        ? strings.transcriptProcessingFailed
        : switch (phase) {
            TranscriptionPhase.transcribing =>
              strings.transcriptProcessingTranscribing,
            TranscriptionPhase.waitingForRefinement =>
              strings.transcriptProcessingWaiting,
            _ => strings.transcriptProcessingRefining,
          };
    final color = showFailure ? ProductColors.amber : ProductColors.forest;
    // Reserve the largest localized label's height so phase changes do not
    // move the document. This also respects the current text scale.
    final labels = [
      strings.transcriptProcessingTranscribing,
      strings.transcriptProcessingWaiting,
      strings.transcriptProcessingRefining,
      strings.transcriptProcessingFailed,
    ];
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('transcript-processing-banner'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: showFailure
              ? ProductColors.amberSoft
              : ProductColors.forestSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: showFailure
                  ? Icon(Icons.info_outline_rounded, size: 18, color: color)
                  : const CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final style = DefaultTextStyle.of(
                    context,
                  ).style.copyWith(color: color);
                  var height = 0.0;
                  for (final label in labels) {
                    final painter = TextPainter(
                      text: TextSpan(text: label, style: style),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                      locale: Localizations.maybeLocaleOf(context),
                    )..layout(maxWidth: constraints.maxWidth);
                    if (painter.height > height) height = painter.height;
                    painter.dispose();
                  }
                  return SizedBox(
                    height: height,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(message, style: style),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineError extends StatelessWidget {
  const _TimelineError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Card(
      color: ProductColors.amberSoft,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Text(l10n.couldNotRefreshTheTimelineCurrentContent),
            ),
            TextButton(
              onPressed: () => unawaited(onRetry()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Text(l10n.noTimelineItemsAreAvailableForThis),
      ),
    );
  }
}

class _OriginalImagePage extends StatelessWidget {
  const _OriginalImagePage({required this.item, required this.onPlay});

  final TimelineItem item;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(formatDuration(item.atMs)),
        actions: [
          TextButton.icon(
            key: const Key('play-from-original-image'),
            onPressed: onPlay,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(l10n.playFromHere),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: item.assetPath.isEmpty
              ? const _OriginalImageMissing()
              : Image.file(
                  File(item.assetPath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const _OriginalImageMissing(),
                ),
        ),
      ),
    );
  }
}

class _OriginalImageMissing extends StatelessWidget {
  const _OriginalImageMissing();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return const Center(
      child: Icon(
        Icons.broken_image_outlined,
        color: ProductColors.mutedInk,
        size: 48,
      ),
    );
  }
}

class _PlaybackBar extends StatefulWidget {
  const _PlaybackBar({
    required this.controller,
    required this.showAi,
    required this.onAi,
  });

  final SessionDetailController controller;
  final bool showAi;
  final VoidCallback? onAi;

  @override
  State<_PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<_PlaybackBar> {
  double? _dragPositionMs;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final controller = widget.controller;
    final playback = controller.playback;
    final prepared = playback.isPrepared;
    final durationMs = prepared
        ? playback.durationMs
        : controller.session.durationMs;
    final positionMs = prepared ? playback.positionMs.clamp(0, durationMs) : 0;
    final sliderMax = durationMs <= 0 ? 1.0 : durationMs.toDouble();
    final displayedPositionMs = (_dragPositionMs ?? positionMs.toDouble())
        .clamp(0.0, sliderMax);
    final canToggle =
        controller.canPlay &&
        durationMs > 0 &&
        !controller.playbackBusy &&
        (playback.isIdle ||
            playback.isPlaying ||
            playback.isPaused ||
            playback.isCompleted);
    return ColoredBox(
      color: ProductColors.paper,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(
            color: ProductColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: ProductColors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x180D241B),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 9, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.playbackError != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.playbackFailedOriginalContentIsUnchanged,
                        style: TextStyle(color: ProductColors.vermilion),
                      ),
                    ),
                    IconButton(
                      onPressed: controller.clearPlaybackError,
                      tooltip: l10n.dismissPlaybackError,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final progress = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(
                            formatDuration(displayedPositionMs.round()),
                            key: const Key('product-playback-position'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            '${playback.isPlaying
                                ? l10n.playing
                                : prepared
                                ? l10n.paused
                                : l10n.originalAudio} · ${formatDuration(durationMs)}',
                            key: const Key('product-playback-status'),
                            style: const TextStyle(
                              color: ProductColors.mutedInk,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 4,
                          ),
                        ),
                        child: Slider(
                          key: const Key('product-playback-slider'),
                          value: displayedPositionMs,
                          max: sliderMax,
                          semanticFormatterCallback: (value) =>
                              l10n.playbackPositionOfDuration(
                                formatDuration(value.round()),
                                formatDuration(durationMs),
                              ),
                          onChanged: prepared && !controller.playbackBusy
                              ? (value) =>
                                    setState(() => _dragPositionMs = value)
                              : null,
                          onChangeEnd: prepared && !controller.playbackBusy
                              ? (value) {
                                  setState(() => _dragPositionMs = null);
                                  unawaited(controller.seekToMs(value.round()));
                                }
                              : null,
                        ),
                      ),
                    ],
                  );
                  final play = IconButton.filled(
                    key: const Key('product-playback-toggle'),
                    tooltip: playback.isPlaying
                        ? l10n.pausePlayback
                        : playback.isIdle
                        ? l10n.playRecordingFromStart
                        : l10n.resumePlayback,
                    onPressed: canToggle ? controller.togglePlayback : null,
                    icon: controller.playbackBusy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            playback.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                  );
                  final actions = <Widget>[
                    IconButton(
                      key: const Key('product-playback-sound'),
                      tooltip: l10n.playbackVolume,
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (_) =>
                            PlaybackSoundSheet(controller: controller),
                      ),
                      icon: Icon(
                        controller.playbackSound.volume == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                      ),
                    ),
                    if (prepared)
                      IconButton(
                        key: const Key('product-playback-stop'),
                        onPressed: controller.playbackBusy
                            ? null
                            : controller.stopPlayback,
                        tooltip: l10n.stopPlayback,
                        icon: const Icon(Icons.stop_rounded),
                      ),
                    if (widget.showAi)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Tooltip(
                          message: l10n.aiChat,
                          child: Semantics(
                            button: true,
                            enabled: widget.onAi != null,
                            label: l10n.aiChat,
                            child: InkWell(
                              key: const Key('product-session-ai'),
                              onTap: widget.onAi,
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: widget.onAi == null
                                      ? ProductColors.mutedInk
                                      : const Color(0xFF163D2D),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const ExcludeSemantics(
                                  child: Text(
                                    'AI',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ];
                  final stacked =
                      constraints.maxWidth < 360 ||
                      MediaQuery.textScalerOf(context).scale(12) > 16;
                  return stacked
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            progress,
                            Row(children: [play, const Spacer(), ...actions]),
                          ],
                        )
                      : Row(
                          children: [
                            play,
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: progress,
                              ),
                            ),
                            ...actions,
                          ],
                        );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExportSheet extends StatelessWidget {
  const _ExportSheet({required this.controller});

  final SessionDetailController controller;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final result = controller.exportResult;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.shareAndExport,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(l10n.textSharingUsesValidRefinedTextWhen),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in {
                    SessionShareFormat.text: l10n.plainTextTxt,
                    SessionShareFormat.markdown: 'Markdown',
                    SessionShareFormat.audio: l10n.continuousWav,
                  }.entries)
                    OutlinedButton(
                      key: Key('share-session-${entry.key.name}'),
                      onPressed: controller.sharing || controller.exporting
                          ? null
                          : () => controller.shareStandalone(entry.key),
                      child: Text(entry.value),
                    ),
                  OutlinedButton.icon(
                    key: const Key('copy-session-text'),
                    onPressed: controller.sharing || controller.exporting
                        ? null
                        : controller.copyFullText,
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(l10n.copyFullText),
                  ),
                ],
              ),
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  l10n.plainTextIsSharedAsATxt,
                  style: TextStyle(color: ProductColors.mutedInk, height: 1.45),
                ),
              ),
              if (controller.exportNotice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    controller.exportNotice!,
                    key: const Key('session-copy-notice'),
                    semanticsLabel: controller.exportNotice,
                  ),
                ),
              if (controller.session.hasConfirmedGaps)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    l10n.thisRecordingHasGapsTextExportsInclude,
                    style: TextStyle(color: ProductColors.vermilion),
                  ),
                ),
              if (controller.sharing) const LinearProgressIndicator(),
              const Divider(height: 32),
              Text(
                l10n.completeRecording,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.momentaiIncludesRefinedAndOriginalTranscriptsSpeaker,
                style: TextStyle(color: ProductColors.mutedInk, height: 1.45),
              ),
              const SizedBox(height: 20),
              if (controller.exporting)
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text(l10n.creatingAndVerifyingExport),
                      ],
                    ),
                  ),
                )
              else if (result != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _ExportRow(
                          label: l10n.exportSize,
                          value: formatBytes(result.archiveByteCount),
                        ),
                        const Divider(height: 22),
                        _ExportRow(
                          label: l10n.timeline,
                          value: l10n.items(
                            (result.timelineItemCount).toString(),
                          ),
                        ),
                        const Divider(height: 22),
                        _ExportRow(
                          label: l10n.transcript,
                          value: l10n.entries(
                            (result.transcriptCount).toString(),
                          ),
                        ),
                        const Divider(height: 22),
                        _ExportRow(
                          label: l10n.text,
                          value: _exportTextLabel(result),
                        ),
                        const Divider(height: 22),
                        _ExportRow(
                          label: l10n.images,
                          value: l10n.photos((result.imageCount).toString()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'SHA-256 ${_shortHash(result.archiveSha256)}',
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('share-product-export'),
                    onPressed: controller.sharing
                        ? null
                        : controller.shareExport,
                    icon: controller.sharing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share_rounded),
                    label: Text(
                      controller.sharing
                          ? l10n.openingShareSheet
                          : l10n.shareMomentAI,
                    ),
                  ),
                ),
              ] else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('generate-product-export'),
                    onPressed: controller.sharing
                        ? null
                        : controller.generateExport,
                    icon: const Icon(Icons.archive_outlined),
                    label: Text(l10n.createExport),
                  ),
                ),
              if (controller.exportError != null) ...[
                const SizedBox(height: 12),
                Text(
                  sessionTransferError(controller.exportError!),
                  style: const TextStyle(color: ProductColors.vermilion),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _shortHash(String value) => value.length <= 16
      ? value
      : '${value.substring(0, 8)}…${value.substring(value.length - 8)}';

  static String _exportTextLabel(SessionExportResult result) {
    if (result.canonicalTextLayer == 'refined') {
      final fallback = result.fallbackTranscriptCount;
      return fallback == 0
          ? l10n.refinedSegments((result.refinedTranscriptCount).toString())
          : l10n.refinedOriginal(
              (result.refinedTranscriptCount).toString(),
              (fallback).toString(),
            );
    }
    return l10n.originalTranscript;
  }
}

class _ExportRow extends StatelessWidget {
  const _ExportRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    );
  }
}
