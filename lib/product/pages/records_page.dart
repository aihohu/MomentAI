import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/session/session_experience_gateway.dart';
import '../../domain/session/session_summary.dart';
import '../app_coordinator.dart';
import '../local_search.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import '../widgets/search_highlighted_text.dart';
import '../widgets/session_summary_card.dart';

class ProductRecordsPage extends StatefulWidget {
  const ProductRecordsPage({
    super.key,
    required this.coordinator,
    required this.onOpenSession,
    required this.gateway,
    required this.onOpenSearchHit,
    this.active = true,
    this.onImport,
  });

  final AppCoordinator coordinator;
  final ValueChanged<SessionSummary> onOpenSession;
  final SessionExperienceGateway gateway;
  final void Function(SessionSummary, SearchNavigationTarget) onOpenSearchHit;
  final bool active;
  final VoidCallback? onImport;

  @override
  State<ProductRecordsPage> createState() => _ProductRecordsPageState();
}

class _ProductRecordsPageState extends State<ProductRecordsPage> {
  late final RecordsSearchController _search;
  final _queryController = TextEditingController();
  Timer? _debounce;
  List<SessionSummary>? _lastSessions;
  var _query = '';
  var _waiting = false;

  AppCoordinator get coordinator => widget.coordinator;

  @override
  void initState() {
    super.initState();
    _search = RecordsSearchController(widget.gateway);
    coordinator.addListener(_sessionsChanged);
    _lastSessions = coordinator.sessions;
  }

  @override
  void didUpdateWidget(covariant ProductRecordsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _debounce?.cancel();
      _search.cancel();
    } else if (!oldWidget.active) {
      _queueSearch(_query);
    }
  }

  void _sessionsChanged() {
    if (identical(_lastSessions, coordinator.sessions)) return;
    _lastSessions = coordinator.sessions;
    if (widget.active && _query.trim().isNotEmpty) _queueSearch(_query);
  }

  void _queueSearch(String value) {
    _debounce?.cancel();
    _search.cancel();
    setState(() {
      _query = value;
      _waiting = value.trim().isNotEmpty;
    });
    if (!_waiting) {
      unawaited(_search.search('', const []));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || !widget.active) return;
      setState(() => _waiting = false);
      unawaited(_search.search(_query, coordinator.sessions));
    });
  }

  Future<void> _refresh() async {
    await coordinator.refreshSessions();
    if (mounted && widget.active) _queueSearch(_query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    coordinator.removeListener(_sessionsChanged);
    _search.dispose();
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return AnimatedBuilder(
      animation: Listenable.merge([coordinator, _search]),
      builder: (context, _) {
        return Column(
          children: [
            AppBar(
              centerTitle: true,
              title: Text(l10n.recordings),
              actions: [
                IconButton(
                  key: const Key('import-product-session'),
                  onPressed: coordinator.hasActiveCapture || coordinator.isBusy
                      ? null
                      : widget.onImport,
                  tooltip: coordinator.hasActiveCapture
                      ? l10n.importAfterRecordingEnds
                      : l10n.importRecording,
                  icon: const Icon(Icons.file_download_outlined),
                ),
              ],
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  key: const PageStorageKey('product-records'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                      sliver: SliverToBoxAdapter(
                        child: TextField(
                          key: const Key('records-search-field'),
                          controller: _queryController,
                          onChanged: _queueSearch,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            labelText: l10n.searchLocalRecordings,
                            hintText: l10n.titlesTranscriptsOrNotes,
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: l10n.clearSearch,
                                    onPressed: () {
                                      _queryController.clear();
                                      _queueSearch('');
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    if (coordinator.error != null)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        sliver: SliverToBoxAdapter(
                          child: Card(
                            color: ProductColors.amberSoft,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.sync_problem_rounded,
                                    color: ProductColors.amber,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      l10n.someLocalStatusCouldNotBeRefreshed,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _refresh,
                                    child: Text(l10n.retry),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_query.trim().isNotEmpty) ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_waiting || _search.searching) ...[
                                const LinearProgressIndicator(),
                                const SizedBox(height: 8),
                                Text(
                                  l10n.searchingLocalText(
                                    (_search.scannedCount).toString(),
                                    (coordinator.sessions.length).toString(),
                                  ),
                                ),
                              ] else
                                Text(
                                  l10n.matchingRecordingsRefinedTextFirstOtherwiseThe(
                                    (_search.results.length).toString(),
                                  ),
                                ),
                              if (_search.failedCount > 0 && !_waiting)
                                TextButton.icon(
                                  key: const Key('records-search-retry'),
                                  onPressed: () => _queueSearch(_query),
                                  icon: const Icon(Icons.warning_amber_rounded),
                                  label: Text(
                                    l10n.couldNotReadContentInRecordingsResults(
                                      (_search.failedCount).toString(),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (!_waiting &&
                          !_search.searching &&
                          _search.results.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              l10n.noMatchingContentTryAnotherKeyword,
                            ),
                          ),
                        ),
                      if (!_waiting)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                          sliver: SliverList.separated(
                            itemCount: _search.results.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final result = _search.results[index];
                              return _SearchResultCard(
                                result: result,
                                query: _query,
                                onOpen: () =>
                                    widget.onOpenSession(result.session),
                                onHit: (hit) {
                                  FocusScope.of(context).unfocus();
                                  widget.onOpenSearchHit(
                                    result.session,
                                    SearchNavigationTarget(
                                      query: _query,
                                      playbackId: hit.item.playbackId,
                                      matchStart: hit.range.start,
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                    ] else if (coordinator.sessions.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyRecords(),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                        sliver: SliverList.separated(
                          itemCount: coordinator.sessions.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) => SessionSummaryCard(
                            session: coordinator.sessions[index],
                            onTap: () => widget.onOpenSession(
                              coordinator.sessions[index],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.result,
    required this.query,
    required this.onOpen,
    required this.onHit,
  });

  final SessionSearchResult result;
  final String query;
  final VoidCallback onOpen;
  final ValueChanged<TimelineSearchHit> onHit;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Card(
      key: ValueKey('search-session-${result.session.sessionId}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: SearchHighlightedText(
                  result.session.title,
                  query: query,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
            Text(
              l10n.matches(
                (result.titleMatches.length + result.contentMatchCount)
                    .toString(),
                (result.session.hasConfirmedGaps ||
                            result.session.status ==
                                SessionStatus.completedWithGaps
                        ? l10n.recordingHasGaps
                        : '')
                    .toString(),
              ),
            ),
            for (final hit in result.previewHits)
              ListTile(
                key: ValueKey(
                  'search-hit-${result.session.sessionId}-${hit.identity}',
                ),
                contentPadding: EdgeInsets.zero,
                title: SearchHighlightedText(
                  hit.preview,
                  query: query,
                  maxLines: 3,
                ),
                subtitle: Text(
                  '${hit.sourceLabel} · ${formatDuration(hit.item.atMs)}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onHit(hit),
              ),
            if (result.contentMatchCount > result.previewHits.length)
              TextButton(
                onPressed: () => onHit(result.previewHits.first),
                child: Text(
                  l10n.viewAllContentMatchesInTheRecording(
                    (result.contentMatchCount).toString(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRecords extends StatelessWidget {
  const _EmptyRecords();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: ProductColors.forestSoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.library_music_outlined,
                size: 34,
                color: ProductColors.forest,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              l10n.noLocalRecordingsYet,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.completedRecordingsWillAppearHereByDate,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
