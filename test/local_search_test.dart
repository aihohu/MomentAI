import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/core/session/session_experience_gateway.dart';
import 'package:momentai/domain/session/session_summary.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/local_search.dart';
import 'package:momentai/product/timeline_display_item.dart';

void main() {
  test(
    'literal Chinese Unicode and case-insensitive matches retain offsets',
    () {
      const text = '😀本地搜索 APP app a+b 本地搜索';
      expect(searchTextRanges(text, ' 本地搜索 ').map((r) => r.start), [2, 19]);
      expect(searchTextRanges(text, 'APP').map((r) => r.start), [7, 11]);
      expect(searchTextRanges(text, 'a+b'), hasLength(1));
      expect(searchTextRanges(text, '.*'), isEmpty);
      expect(searchTextRanges(text, '  '), isEmpty);
      expect(searchTextRanges('😀😀', '😀').map((r) => r.start), [0, 2]);
    },
  );

  test(
    'search uses refined projection and per-segment fallback without writes',
    () {
      final timeline = _timeline();
      final projection = _projection(timeline, _refined(timeline));
      final hits = searchTimeline(projection, '关键词').toList();
      expect(hits.map((h) => h.item.playbackId), ['seg_a', 'seg_b', 'thought']);
      expect(hits.map((h) => h.textLayer), [
        TimelineTextLayer.refined,
        TimelineTextLayer.fallback,
        TimelineTextLayer.live,
      ]);
      expect(hits.map((h) => h.item.sampleOffset), [16053, 32000, 40001]);
      expect(timeline.first.text, '实时旧词');
      expect(searchTimeline(projection, '实时旧词'), isEmpty);
      expect(searchTimeline(projection, '失败随想'), isEmpty);
      expect(searchTimeline(projection, '内部事件'), isEmpty);
    },
  );

  test('stale failed and processing refinement fall back to original text', () {
    final timeline = _timeline();
    for (final snapshot in [
      _refined(timeline, fingerprint: 'sha256:stale'),
      const FullTextRefinementSnapshot.processing(),
      const FullTextRefinementSnapshot(status: FullTextRefinementStatus.failed),
    ]) {
      final hits = searchTimeline(_projection(timeline, snapshot), '实时旧词');
      expect(hits.single.item.sampleOffset, 16053);
    }
    final live = _projection(timeline, _refined(timeline), live: true);
    expect(searchTimeline(live, '实时旧词'), hasLength(1));
  });

  test(
    'all occurrences are counted with bounded list previews and fresh scans',
    () async {
      final gateway = _Gateway();
      final controller = RecordsSearchController(gateway);
      addTearDown(controller.dispose);
      gateway.items = [
        TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'many',
          'sampleOffset': 17,
          'endSample': 32000,
          'text': '关键词关键词关键词关键词关键词',
        }),
      ];
      await controller.search('关键词', [_session('a', title: '关键词访谈')]);
      expect(controller.results.single.titleMatches, hasLength(1));
      expect(controller.results.single.contentMatchCount, 5);
      expect(controller.results.single.previewHits, hasLength(3));
      expect(controller.scannedCount, 1);
      gateway.items = [];
      await controller.search('关键词', [_session('a')]);
      expect(controller.results, isEmpty);
      await controller.search('', [_session('a')]);
      expect(controller.searching, isFalse);
    },
  );

  test('obsolete async searches cannot replace the latest query', () async {
    final oldRead = Completer<List<TimelineItem>>();
    var reads = 0;
    final gateway = _Gateway()
      ..readTimeline = (_) async {
        if (reads++ == 0) return oldRead.future;
        return _timeline();
      };
    final controller = RecordsSearchController(gateway);
    addTearDown(controller.dispose);
    final oldSearch = controller.search('旧查询', [_session('a')]);
    await controller.search('实时旧词', [_session('a')]);
    oldRead.complete([]);
    await oldSearch;
    expect(controller.results.single.previewHits.single.text, '实时旧词');
    expect(controller.scannedCount, 1);
    expect(controller.searching, isFalse);
  });

  test(
    'read failures retain title matches and expose incomplete results',
    () async {
      final gateway = _Gateway()
        ..readTimeline = (_) => Future.error(StateError('read'));
      final controller = RecordsSearchController(gateway);
      addTearDown(controller.dispose);
      await controller.search('标题', [_session('a', title: '标题')]);
      expect(controller.results.single.titleMatches, hasLength(1));
      expect(controller.failedCount, 1);
      expect(controller.searching, isFalse);
    },
  );

  test('refinement read failure still searches live text', () async {
    final gateway = _Gateway()..failRefinement = true;
    final controller = RecordsSearchController(gateway);
    addTearDown(controller.dispose);
    await controller.search('实时旧词', [_session('a')]);
    expect(controller.results.single.contentMatchCount, 1);
    expect(controller.failedCount, 1);
  });

  test('disposal cancels in-flight reads without notifications', () async {
    final gate = Completer<List<TimelineItem>>();
    final gateway = _Gateway()..readTimeline = (_) => gate.future;
    final controller = RecordsSearchController(gateway);
    final pending = controller.search('词', [_session('a')]);
    controller.dispose();
    gate.complete(_timeline());
    await pending;
  });
}

List<TimelineItem> _timeline() => [
  TimelineItem.fromMap({
    'kind': 'transcript',
    'segmentId': 'seg_a',
    'sampleOffset': 16053,
    'endSample': 32000,
    'text': '实时旧词',
  }),
  TimelineItem.fromMap({
    'kind': 'transcript',
    'segmentId': 'seg_b',
    'sampleOffset': 32000,
    'endSample': 40000,
    'text': '回退关键词',
  }),
  TimelineItem.fromMap({
    'kind': 'captureEvent',
    'eventId': 'thought',
    'type': 'thought',
    'sampleOffset': 40001,
    'captureState': 'committed',
    'payload': {'text': '随想关键词'},
  }),
  TimelineItem.fromMap({
    'kind': 'captureEvent',
    'eventId': 'failed',
    'type': 'thought',
    'sampleOffset': 40002,
    'captureState': 'failed',
    'text': '失败随想关键词',
  }),
  TimelineItem.fromMap({
    'kind': 'event',
    'sampleOffset': 40003,
    'text': '内部事件关键词',
  }),
];

TimelineDisplayProjection _projection(
  List<TimelineItem> timeline,
  FullTextRefinementSnapshot refinement, {
  bool live = false,
}) => projectTimelineForDisplay(
  timeline: timeline,
  refinement: refinement,
  preference: live
      ? TimelineTextPreference.live
      : TimelineTextPreference.refined,
);

FullTextRefinementSnapshot _refined(
  List<TimelineItem> timeline, {
  String? fingerprint,
}) => FullTextRefinementSnapshot(
  status: FullTextRefinementStatus.ready,
  document: RefinedFullTextDocument(
    sessionId: 'a',
    modelId: senseVoiceFullTextModelId,
    fullText: '精修关键词回退关键词',
    sourceAudioSamples: 40000,
    sampleRate: 16000,
    createdAt: DateTime.utc(2026, 8, 30),
    segments: const [],
    initializationMs: 0,
    decodeMs: 0,
    realTimeFactor: 0,
    peakRssBytes: 0,
    sourceTimelineFingerprint:
        fingerprint ??
        sourceTimelineFingerprint(refinementTimelineSources(timeline)),
    timelineProjection: const [
      RefinedTimelineSegment(
        segmentId: 'seg_a',
        startSample: 16053,
        endSample: 32000,
        refinedText: '精修关键词',
        fallback: false,
      ),
      RefinedTimelineSegment(
        segmentId: 'seg_b',
        startSample: 32000,
        endSample: 40000,
        refinedText: '回退关键词',
        fallback: true,
      ),
    ],
  ),
);

SessionSummary _session(String id, {String title = '记录'}) =>
    SessionSummary.fromMap({
      'sessionId': id,
      'directory': '/tmp/$id',
      'title': title,
      'state': 'completed',
      'startedAtWall': '2026-08-30T14:00:00Z',
    });

class _Gateway implements SessionExperienceGateway {
  List<TimelineItem> items = _timeline();
  Future<List<TimelineItem>> Function(String)? readTimeline;
  bool failRefinement = false;

  @override
  Future<List<TimelineItem>> timeline(String directory) async =>
      readTimeline == null ? items : readTimeline!(directory);

  @override
  Future<FullTextRefinementSnapshot> fullTextRefinement(
    String directory,
  ) async {
    if (failRefinement) throw StateError('refinement read');
    return const FullTextRefinementSnapshot.unavailable();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected non-search operation');
}
