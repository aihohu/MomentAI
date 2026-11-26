import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/full_text_search.dart';

void main() {
  test('reading breaks preserve repeated search anchors and source text', () {
    final first = '${'甲' * 105}关键词。';
    final second = '${'乙' * 105}关键词。';
    final timeline = [_item(0, first), _item(1, second)];
    final snapshot = _refined(timeline, [
      first,
      second,
    ], fullText: '$first$second');
    final output = _project(timeline, snapshot);
    expect(output.text, '$first\n\n$second');
    final hits = output.search('关键词');
    expect(hits.map((h) => h.playbackItem?.sampleOffset), [53, 16053]);
    expect(hits.last.range.start, first.length + 2 + 105);
    expect(snapshot.document!.fullText, '$first$second');
  });

  test('live full text matches displayed paragraphs and excludes thoughts', () {
    final timeline = [
      _item(0, '  开头😀末尾  '),
      _item(1, ' 下一段关键词 '),
      TimelineItem.fromMap({
        'kind': 'captureEvent',
        'type': 'thought',
        'captureState': 'committed',
        'text': '仅时间线随想',
      }),
    ];
    final document = _project(timeline);
    expect(document.text, '开头😀末尾\n\n下一段关键词');
    expect(document.search('仅时间线随想'), isEmpty);
    final crossParagraph = document.search('末尾\n\n下一段').single;
    expect(crossParagraph.playbackItem?.sampleOffset, 53);
    expect(document.search('😀').single.range.start, 2);
    expect(document.search('关键词').single.playbackItem?.sampleOffset, 16053);
    expect(timeline.first.text, '  开头😀末尾  ');
  });

  test(
    'live full text searches all segments beyond the timeline page size',
    () {
      final timeline = List.generate(65, (i) => _item(i, '第$i段'));
      final document = _project(timeline);
      expect(
        document.search('第64段').single.playbackItem?.sampleOffset,
        64 * 16000 + 53,
      );
      expect(document.anchors, hasLength(65));
    },
  );

  test('refined repeated matches retain ordered original anchors', () {
    final timeline = [_item(0, '实时甲'), _item(1, '实时乙')];
    final snapshot = _refined(timeline, ['关键词😀', '关键词尾部']);
    final document = _project(timeline, snapshot);
    expect(document.text, '关键词😀\n\n关键词尾部');
    expect(document.search('关键词').map((h) => h.playbackItem?.sampleOffset), [
      53,
      16053,
    ]);
    expect(document.search('实时'), isEmpty);
    expect(document.search('😀\n\n关键词').single.playbackItem?.sampleOffset, 53);
  });

  test(
    'speaker paragraphs use verified segment refinement even when composed text differs',
    () {
      final timeline = [_item(0, '实时甲'), _item(1, '实时乙')];
      final speakers = SpeakerDiarizationDocument(
        sessionId: 'session',
        modelId: 'synthetic',
        sourceAudioSamples: timeline.last.endSample,
        sampleRate: 16000,
        sourceChunkFingerprint: 'sha256:test',
        createdAt: '2026-09-15T00:00:00Z',
        segments: [
          for (var i = 0; i < 2; i++)
            SpeakerDiarizationSegment(
              speakerId: 'speaker_${i + 1}',
              startSample: timeline[i].sampleOffset,
              endSample: timeline[i].endSample,
            ),
        ],
        processingMs: 1,
        realTimeFactor: 0,
        peakRssBytes: 1,
        windowCount: 1,
      );
      FullTextSearchDocument project(FullTextRefinementSnapshot snapshot) =>
          projectFullTextForSearch(
            sessionId: 'session',
            timeline: timeline,
            refinement: snapshot,
            speakers: speakers,
          );
      final snapshot = _refined(timeline, ['精修甲', ''], fullText: '另一种整理文本');
      final output = project(snapshot);
      expect(output.text, '精修甲\n\n实时乙');
      expect(output.paragraphs.map((p) => p.textLayer.name), [
        'refined',
        'fallback',
      ]);
      expect(
        output.search('实时乙').single.playbackItem?.sampleOffset,
        timeline.last.sampleOffset,
      );
      expect(snapshot.document!.fullText, '另一种整理文本');
      for (final invalid in [
        _refined(timeline, ['精修甲', '精修乙'], fingerprint: 'stale'),
        _refined(timeline, ['精修甲', '精修乙'], sessionId: 'other'),
        _refined(timeline, ['精修甲', '精修乙'], audioSamples: 100),
      ]) {
        expect(project(invalid).text, '实时甲\n\n实时乙');
      }
    },
  );

  test('unverified refinement remains searchable without guessed playback', () {
    final timeline = [_item(0, '实时甲'), _item(1, '实时乙')];
    for (final snapshot in [
      _refined(timeline, ['精修甲', '精修乙'], sessionId: 'other'),
      _refined(timeline, ['精修甲', '精修乙'], fingerprint: 'stale'),
      _refined(timeline, ['精修甲', '精修乙'], composer: 0),
      _refined(timeline, ['精修甲', '精修乙'], audioSamples: 100),
      _refined(timeline, ['精修甲', '精修乙'], fullText: '整理后的精修甲与精修乙'),
    ]) {
      final document = _project(timeline, snapshot);
      expect(document.search('精修'), hasLength(2));
      expect(document.anchors, isEmpty);
      expect(
        document.search('精修').every((hit) => hit.playbackItem == null),
        isTrue,
      );
    }
  });

  test(
    'processing or failed refinement searches the complete live fallback',
    () {
      final timeline = [_item(0, '实时关键词')];
      for (final snapshot in [
        const FullTextRefinementSnapshot.processing(),
        const FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.failed,
        ),
      ]) {
        final hit = _project(timeline, snapshot).search('关键词').single;
        expect(hit.sourceLabel, '实时全文');
        expect(hit.playbackItem?.sampleOffset, 53);
      }
    },
  );

  test('refinement replacement refreshes the literal searchable document', () {
    final timeline = [_item(0, '原文')];
    final before = _project(timeline, _refined(timeline, ['旧词']));
    final after = _project(timeline, _refined(timeline, ['新词新词']));
    expect(before.search('旧词'), hasLength(1));
    expect(after.search('旧词'), isEmpty);
    expect(after.search('新词'), hasLength(2));
    expect(after.search('  '), isEmpty);
    expect(timeline.single.text, '原文');
  });
}

TimelineItem _item(int index, String text) => TimelineItem.fromMap({
  'kind': 'transcript',
  'segmentId': 'seg_$index',
  'sampleOffset': index * 16000 + 53,
  'endSample': (index + 1) * 16000 + 53,
  'text': text,
});

FullTextSearchDocument _project(
  List<TimelineItem> timeline, [
  FullTextRefinementSnapshot snapshot =
      const FullTextRefinementSnapshot.unavailable(),
]) => projectFullTextForSearch(
  sessionId: 'session',
  timeline: timeline,
  refinement: snapshot,
);

FullTextRefinementSnapshot _refined(
  List<TimelineItem> timeline,
  List<String> text, {
  String sessionId = 'session',
  String? fingerprint,
  int? composer,
  int? audioSamples,
  String? fullText,
}) => FullTextRefinementSnapshot(
  status: FullTextRefinementStatus.ready,
  document: RefinedFullTextDocument(
    sessionId: sessionId,
    modelId: senseVoiceFullTextModelId,
    fullText: fullText ?? text.join('\n\n'),
    sourceAudioSamples: audioSamples ?? timeline.last.endSample,
    sampleRate: 16000,
    createdAt: DateTime.utc(2026, 8, 31),
    segments: const [],
    initializationMs: 0,
    decodeMs: 0,
    realTimeFactor: 0,
    peakRssBytes: 0,
    composerVersion: composer ?? refinedTimelineComposerVersion,
    sourceTimelineFingerprint:
        fingerprint ??
        sourceTimelineFingerprint(refinementTimelineSources(timeline)),
    timelineProjection: List.generate(
      timeline.length,
      (i) => RefinedTimelineSegment(
        segmentId: timeline[i].eventId,
        startSample: timeline[i].sampleOffset,
        endSample: timeline[i].endSample,
        refinedText: text[i],
        fallback: false,
      ),
    ),
  ),
);
