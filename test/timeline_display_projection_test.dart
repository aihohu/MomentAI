import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/timeline_display_item.dart';

void main() {
  final timeline = <TimelineItem>[
    TimelineItem.fromMap({
      'kind': 'event',
      'sequence': 1,
      'type': 'session_started',
      'sampleOffset': 0,
    }),
    TimelineItem.fromMap({
      'kind': 'transcript',
      'segmentId': 'seg_1',
      'sampleOffset': 16000,
      'endSample': 32000,
      'text': '第一段实时原文',
    }),
    TimelineItem.fromMap({
      'kind': 'captureEvent',
      'eventId': 'bookmark_1',
      'type': 'bookmark',
      'captureState': 'committed',
      'sampleOffset': 32000,
    }),
    TimelineItem.fromMap({
      'kind': 'transcript',
      'segmentId': 'seg_2',
      'sampleOffset': 48000,
      'endSample': 64000,
      'text': '第二段实时原文',
    }),
  ];

  test(
    'ready projection defaults to refined text without replacing sources',
    () {
      final projection = projectTimelineForDisplay(
        timeline: timeline,
        refinement: _readySnapshot(timeline),
        preference: TimelineTextPreference.refined,
      );

      expect(projection.availability, TimelineDisplayAvailability.ready);
      expect(projection.canSelectRefined, isTrue);
      expect(projection.items[1].displayText, '第一段精修文字。');
      expect(projection.items[3].displayText, '第二段精修文字。');
      expect(projection.items[1].textLayer, TimelineTextLayer.refined);
      expect(identical(projection.items[1].source, timeline[1]), isTrue);
      expect(projection.items.map((item) => item.source.playbackId), [
        timeline[0].playbackId,
        'seg_1',
        'bookmark_1',
        'seg_2',
      ]);
    },
  );

  test('live preference changes only transcript display text', () {
    final projection = projectTimelineForDisplay(
      timeline: timeline,
      refinement: _readySnapshot(timeline),
      preference: TimelineTextPreference.live,
    );

    expect(projection.items[1].displayText, '第一段实时原文');
    expect(projection.items[3].displayText, '第二段实时原文');
    expect(projection.items[1].source.sampleOffset, 16000);
    expect(projection.items[2].source.type, 'bookmark');
    expect(
      projection.statusMessage(preference: TimelineTextPreference.live),
      '录音时实时生成的原始转写',
    );
  });

  test('partial projection falls back per segment', () {
    final snapshot = _readySnapshot(timeline, fallbackSecond: true);
    final projection = projectTimelineForDisplay(
      timeline: timeline,
      refinement: snapshot,
      preference: TimelineTextPreference.refined,
    );

    expect(projection.availability, TimelineDisplayAvailability.partial);
    expect(projection.fallbackCount, 1);
    expect(projection.items[1].displayText, '第一段精修文字。');
    expect(projection.items[3].displayText, '第二段实时原文');
    expect(projection.items[3].textLayer, TimelineTextLayer.fallback);
    expect(
      projection.statusMessage(preference: TimelineTextPreference.refined),
      'SenseVoice · 本地精修 · 1 段使用实时原文',
    );
  });

  test('stale fingerprint and composer never expose refined text', () {
    final ready = _readySnapshot(timeline).document!;
    final staleFingerprint = FullTextRefinementSnapshot(
      status: FullTextRefinementStatus.ready,
      document: _copyDocument(ready, sourceTimelineFingerprint: 'sha256:old'),
    );
    final staleComposer = FullTextRefinementSnapshot(
      status: FullTextRefinementStatus.ready,
      document: _copyDocument(
        ready,
        composerVersion: refinedTimelineComposerVersion - 1,
      ),
    );

    for (final snapshot in [staleFingerprint, staleComposer]) {
      final projection = projectTimelineForDisplay(
        timeline: timeline,
        refinement: snapshot,
        preference: TimelineTextPreference.refined,
      );
      expect(projection.availability, TimelineDisplayAvailability.stale);
      expect(projection.canSelectRefined, isFalse);
      expect(projection.items[1].displayText, '第一段实时原文');
    }
  });

  test('processing and failed snapshots safely remain live', () {
    const snapshots = [
      FullTextRefinementSnapshot.processing(),
      FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.failed,
        message: 'failed',
      ),
    ];

    final projections = snapshots
        .map(
          (snapshot) => projectTimelineForDisplay(
            timeline: timeline,
            refinement: snapshot,
            preference: TimelineTextPreference.refined,
          ),
        )
        .toList();
    expect(projections.map((projection) => projection.availability), [
      TimelineDisplayAvailability.processing,
      TimelineDisplayAvailability.failed,
    ]);
    expect(
      projections.every((projection) => !projection.canSelectRefined),
      isTrue,
    );
    expect(
      projections.every(
        (projection) => projection.items[1].displayText == '第一段实时原文',
      ),
      isTrue,
    );
    expect(
      projections[0].statusMessage(preference: TimelineTextPreference.refined),
      '正在设备内精修文字…当前显示实时原文',
    );
    expect(
      projections[1].statusMessage(preference: TimelineTextPreference.refined),
      '本地精修暂未完成，当前显示实时原文',
    );
  });
}

FullTextRefinementSnapshot _readySnapshot(
  List<TimelineItem> timeline, {
  bool fallbackSecond = false,
}) {
  final sources = refinementTimelineSources(timeline);
  return FullTextRefinementSnapshot(
    status: FullTextRefinementStatus.ready,
    document: RefinedFullTextDocument(
      sessionId: 'session_1',
      modelId: senseVoiceFullTextModelId,
      fullText: '第一段精修文字。第二段精修文字。',
      sourceAudioSamples: 64000,
      sampleRate: 16000,
      createdAt: DateTime.utc(2026, 8, 30),
      segments: const [],
      initializationMs: 1,
      decodeMs: 10,
      realTimeFactor: 0.1,
      peakRssBytes: 1,
      sourceTimelineFingerprint: sourceTimelineFingerprint(sources),
      composerVersion: refinedTimelineComposerVersion,
      timelineProjection: [
        const RefinedTimelineSegment(
          segmentId: 'seg_1',
          startSample: 16000,
          endSample: 32000,
          refinedText: '第一段精修文字。',
          fallback: false,
        ),
        RefinedTimelineSegment(
          segmentId: 'seg_2',
          startSample: 48000,
          endSample: 64000,
          refinedText: fallbackSecond ? '第二段实时原文' : '第二段精修文字。',
          fallback: fallbackSecond,
        ),
      ],
    ),
  );
}

RefinedFullTextDocument _copyDocument(
  RefinedFullTextDocument source, {
  String? sourceTimelineFingerprint,
  int? composerVersion,
}) => RefinedFullTextDocument(
  sessionId: source.sessionId,
  modelId: source.modelId,
  fullText: source.fullText,
  sourceAudioSamples: source.sourceAudioSamples,
  sampleRate: source.sampleRate,
  createdAt: source.createdAt,
  segments: source.segments,
  initializationMs: source.initializationMs,
  decodeMs: source.decodeMs,
  realTimeFactor: source.realTimeFactor,
  peakRssBytes: source.peakRssBytes,
  sourceTimelineFingerprint:
      sourceTimelineFingerprint ?? source.sourceTimelineFingerprint,
  composerVersion: composerVersion ?? source.composerVersion,
  canonicalTokens: source.canonicalTokens,
  timelineProjection: source.timelineProjection,
);
