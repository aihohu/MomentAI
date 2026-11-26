import 'package:flutter/foundation.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../core/session/session_experience_gateway.dart';
import '../domain/session/session_summary.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/refined_full_text.dart';
import 'timeline_display_item.dart';

class SearchTextRange {
  const SearchTextRange(this.start, this.end);

  final int start;
  final int end;
}

List<SearchTextRange> searchTextRanges(String text, String query) {
  final value = query.trim();
  if (value.isEmpty) return const [];
  // RegExp offsets refer to the original UTF-16 string, even when Unicode
  // case folding changes a character's lowercase representation.
  return RegExp(RegExp.escape(value), caseSensitive: false, unicode: true)
      .allMatches(text)
      .map((match) => SearchTextRange(match.start, match.end))
      .toList(growable: false);
}

abstract class RecordSearchHit {
  const RecordSearchHit();

  String get text;
  SearchTextRange get range;
  TimelineItem? get playbackItem;
  String get sourceLabel;
  String get identity;

  String get preview {
    var start = (range.start - 24).clamp(0, text.length);
    var end = (range.end + 48).clamp(0, text.length);
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start -= 1;
    if (end < text.length && _isLowSurrogate(text.codeUnitAt(end))) end += 1;
    return '${start > 0 ? '…' : ''}${text.substring(start, end)}'
        '${end < text.length ? '…' : ''}';
  }
}

class TimelineSearchHit extends RecordSearchHit {
  const TimelineSearchHit({
    required this.item,
    required this.text,
    required this.range,
    required this.textLayer,
  });

  final TimelineItem item;
  @override
  final String text;
  @override
  final SearchTextRange range;
  final TimelineTextLayer textLayer;

  @override
  TimelineItem get playbackItem => item;

  @override
  String get identity => '${item.playbackId}:${range.start}';

  @override
  String get sourceLabel => item.isThought
      ? l10n.note
      : switch (textLayer) {
          TimelineTextLayer.refined => l10n.refinedText,
          TimelineTextLayer.live ||
          TimelineTextLayer.fallback => l10n.originalTranscript,
        };
}

bool _isLowSurrogate(int code) => code >= 0xdc00 && code <= 0xdfff;

Iterable<TimelineSearchHit> searchTimeline(
  TimelineDisplayProjection projection,
  String query,
) sync* {
  for (final display in projection.items) {
    final item = display.source;
    if (!item.isTranscript && !(item.isThought && item.isCommitted)) continue;
    final text = item.isThought && display.displayText.isEmpty
        ? item.payload['text']?.toString() ?? ''
        : display.displayText;
    for (final range in searchTextRanges(text, query)) {
      yield TimelineSearchHit(
        item: item,
        text: text,
        range: range,
        textLayer: display.textLayer,
      );
    }
  }
}

class SearchNavigationTarget {
  const SearchNavigationTarget({
    required this.query,
    required this.playbackId,
    required this.matchStart,
  });

  final String query;
  final String playbackId;
  final int matchStart;
}

class SessionSearchResult {
  const SessionSearchResult({
    required this.session,
    required this.titleMatches,
    required this.contentMatchCount,
    required this.previewHits,
  });

  final SessionSummary session;
  final List<SearchTextRange> titleMatches;
  final int contentMatchCount;
  final List<TimelineSearchHit> previewHits;
}

/// A cancellable, text-only snapshot scan. No persistent index, audio reads,
/// model execution, or writes to the Session fact store are needed.
class RecordsSearchController extends ChangeNotifier {
  RecordsSearchController(this.gateway);

  final SessionExperienceGateway gateway;
  List<SessionSearchResult> results = const [];
  int scannedCount = 0;
  int totalCount = 0;
  int failedCount = 0;
  bool searching = false;
  int _generation = 0;
  bool _disposed = false;

  void cancel() {
    _generation += 1;
    searching = false;
  }

  Future<void> search(String query, List<SessionSummary> sessions) async {
    final generation = ++_generation;
    results = const [];
    scannedCount = 0;
    totalCount = sessions.length;
    failedCount = 0;
    searching = query.trim().isNotEmpty;
    notifyListeners();
    if (!searching) return;
    final found = <SessionSearchResult>[];
    for (final session in List<SessionSummary>.of(sessions)) {
      if (_disposed || generation != _generation) return;
      final titleMatches = searchTextRanges(session.title, query);
      var contentMatchCount = 0;
      var readFailed = false;
      final previewHits = <TimelineSearchHit>[];
      try {
        final timeline = await gateway.timeline(session.directory);
        if (_disposed || generation != _generation) return;
        var refinement = const FullTextRefinementSnapshot.unavailable();
        try {
          refinement = await gateway.fullTextRefinement(session.directory);
        } catch (_) {
          readFailed = true;
        }
        if (_disposed || generation != _generation) return;
        final projection = projectTimelineForDisplay(
          timeline: timeline,
          refinement: refinement,
          preference: TimelineTextPreference.refined,
        );
        for (final hit in searchTimeline(projection, query)) {
          contentMatchCount += 1;
          if (previewHits.length < 3) previewHits.add(hit);
        }
      } catch (_) {
        if (_disposed || generation != _generation) return;
        readFailed = true;
      }
      if (readFailed) failedCount += 1;
      if (titleMatches.isNotEmpty || contentMatchCount > 0) {
        found.add(
          SessionSearchResult(
            session: session,
            titleMatches: titleMatches,
            contentMatchCount: contentMatchCount,
            previewHits: previewHits,
          ),
        );
      }
      scannedCount += 1;
      results = List.unmodifiable(found);
      notifyListeners();
    }
    if (_disposed || generation != _generation) return;
    searching = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
