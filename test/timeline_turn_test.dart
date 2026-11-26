import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/product/local_search.dart';
import 'package:momentai/product/timeline_display_item.dart';
import 'package:momentai/product/timeline_turn.dart';

void main() {
  test(
    'adjacent same speaker forms one turn without losing text or anchors',
    () {
      final items = [
        item('a', 0, 16000, '甲😀'),
        item('b', 32000, 48000, '乙关键词'),
        item('c', 80000, 96000, '丙'),
      ];
      final speakers = document([segment('speaker_1', 0, 160000)]);
      final turns = groupTimelineTurns(items, speakers: speakers);
      expect(turns, hasLength(1));
      expect(turns.single.items, items);
      expect(turns.single.text, '甲😀 乙关键词丙');
      expect(turns.single.rangeFor('b', const SearchTextRange(1, 4))?.start, 5);
      expect(turns.single.first.source.sampleOffset, 0);
      expect(turns.single.items[1].source.sampleOffset, 32000);
      expect(items[0].displayText, '甲😀');
      expect(groupTimelineTurns(items), hasLength(1));
    },
  );
  test(
    'refined fragments form natural sentences without inventing speakers',
    () {
      final items = [
        item('a', 0, 16000, '我们先确认一下'),
        item('b', 16000, 32000, '这次版本要解决的问题。'),
        item('c', 32000, 48000, '最重要的是保存可靠。'),
      ];
      final turn = groupTimelineTurns(items).single;
      expect(turn.text, '我们先确认一下这次版本要解决的问题。最重要的是保存可靠。');
      expect(turn.speakerId, isNull);
      expect(turn.speakerLabel, isNull);
      expect(turn.items, items);
      final range = turn.rangeFor('b', const SearchTextRange(5, 7))!;
      expect(turn.text.substring(range.start, range.end), '解决');
      expect(turn.first.source.sampleOffset, 0);
      expect(turn.items[1].source.sampleOffset, 16000);
    },
  );
  test('live and fallback boundaries remain explicit', () {
    final items = [
      item('a', 0, 16000, '精修'),
      item('b', 16000, 32000, '原文', layer: TimelineTextLayer.fallback),
      item('c', 32000, 48000, '精修'),
    ];
    expect(groupTimelineTurns(items), hasLength(3));
    final live = [
      item('a', 0, 16000, '原文甲', layer: TimelineTextLayer.live),
      item('b', 16000, 32000, '原文乙', layer: TimelineTextLayer.live),
    ];
    expect(groupTimelineTurns(live), hasLength(2));
    expect(
      groupTimelineTurns(
        live,
        speakers: document([segment('speaker_1', 0, 32000)]),
      ).single.text,
      '原文甲 原文乙',
    );
  });
  test('English words, CJK punctuation and existing spaces stay readable', () {
    final items = [
      item('a', 0, 16000, 'Hello'),
      item('b', 16000, 32000, 'world.'),
      item('c', 32000, 48000, ' Next sentence.'),
    ];
    expect(
      groupTimelineTurns(items).single.text,
      'Hello world. Next sentence.',
    );
    expect(
      groupTimelineTurns([
        item('a', 0, 16000, '他说：“'),
        item('b', 16000, 32000, '可以'),
        item('c', 32000, 48000, '。”'),
        item('d', 48000, 64000, '继续讨论。'),
      ]).single.text,
      '他说：“可以。”继续讨论。',
    );
  });
  test('paragraphs prefer sentence ends and cap unpunctuated source runs', () {
    final items = [
      item('a', 0, 16000, '甲' * 70),
      item('b', 16000, 32000, '${'乙' * 40}。”'),
      item('c', 32000, 48000, '下一段。'),
    ];
    final turns = groupTimelineTurns(items);
    expect(turns, hasLength(2));
    expect(turns.first.items, items.take(2));
    expect(turns.last.text, '下一段。');
    final noPunctuation = List.generate(
      20,
      (i) => item('$i', i * 16000, (i + 1) * 16000, '甲' * 60),
    );
    final bounded = groupTimelineTurns(noPunctuation);
    expect(bounded, hasLength(5));
    expect(bounded.every((t) => t.items.length == 4), isTrue);
    expect(bounded.expand((t) => t.items), noPunctuation);
  });
  test(
    'sparse long speech has duration boundaries and empty text is a boundary',
    () {
      final items = List.generate(
        8,
        (i) => item('$i', i * 15 * 16000, (i + 1) * 15 * 16000, '内容。'),
      );
      expect(groupTimelineTurns(items).map((t) => t.items.length), [
        2,
        2,
        2,
        2,
      ]);
      final continuous = List.generate(
        8,
        (i) => item('$i', i * 15 * 16000, (i + 1) * 15 * 16000, '内容'),
      );
      expect(groupTimelineTurns(continuous).map((t) => t.items.length), [4, 4]);
      expect(
        groupTimelineTurns([
          item('a', 0, 16000, '甲'),
          item('b', 16000, 32000, ''),
          item('c', 32000, 48000, '乙'),
        ]),
        hasLength(3),
      );
    },
  );
  test(
    'very long source gains paragraphs with exact Unicode search offsets',
    () {
      final text = '${'第一句话包含😀。' * 25}最后目标。${'后续内容。' * 30}';
      final source = item('long', 0, 160000, text);
      final turn = groupTimelineTurns([source]).single;
      expect(turn.text, contains('\n\n'));
      expect(turn.text.replaceAll('\n\n', ''), text);
      final start = text.indexOf('目标');
      final range = turn.rangeFor('long', SearchTextRange(start, start + 2))!;
      expect(turn.text.substring(range.start, range.end), '目标');
      expect(turn.items.single.source, same(source.source));
      expect(turn.rangeFor('missing', const SearchTextRange(0, 1)), isNull);
    },
  );
  test(
    'three hours of synthetic text preserves every source and bounded groups',
    () {
      final items = List.generate(
        1080,
        (i) => item(
          '$i',
          i * 10 * 16000,
          (i + 1) * 10 * 16000,
          '第$i条。这是连续沟通中完整的一句话，保留精确的音频定位。',
        ),
      );
      final turns = groupTimelineTurns(items);
      expect(turns.length, lessThan(items.length ~/ 2));
      expect(turns.expand((t) => t.items), items);
      expect(turns.every((t) => t.items.length <= 6), isTrue);
      final late = turns.firstWhere((t) => t.contains('1000'));
      final range = late.rangeFor('1000', const SearchTextRange(0, 6))!;
      expect(late.text.substring(range.start, range.end), '第1000条');
    },
  );
  test(
    'long pauses, events and intersecting transcript ranges split turns',
    () {
      final speakers = document([segment('speaker_1', 0, 1000000)]);
      for (final middle in [
        item('event', 16000, 16000, '现场', kind: 'captureEvent'),
        item('overlap', 8000, 20000, '交叉'),
      ]) {
        expect(
          groupTimelineTurns([
            item('a', 0, 16000, '甲'),
            middle,
            item('b', 16000, 32000, '乙'),
          ], speakers: speakers),
          hasLength(3),
        );
      }
      expect(
        groupTimelineTurns([
          item('a', 0, 16000, '甲'),
          item('b', 48001, 64000, '乙'),
        ], speakers: speakers),
        hasLength(2),
      );
    },
  );
  test('different, uncertain, overlapping and unknown voices never merge', () {
    final items = [item('a', 0, 16000, '甲'), item('b', 16000, 32000, '乙')];
    for (final segments in [
      [segment('speaker_1', 0, 16000), segment('speaker_2', 16000, 32000)],
      [segment('speaker_1', 0, 8000), segment('speaker_1', 16000, 24000)],
      [segment('speaker_1', 0, 32000), segment('speaker_2', 1000, 30000)],
      <SpeakerDiarizationSegment>[],
    ]) {
      expect(
        groupTimelineTurns(items, speakers: document(segments)),
        hasLength(2),
      );
    }
  });
  test(
    'another speaker in a short text gap prevents merging across their turn',
    () {
      final speakers = document([
        segment('speaker_1', 0, 16000),
        segment('speaker_2', 16000, 24000),
        segment('speaker_1', 32000, 48000),
      ]);
      expect(
        groupTimelineTurns([
          item('a', 0, 16000, '甲'),
          item('b', 32000, 48000, '乙'),
        ], speakers: speakers),
        hasLength(2),
      );
    },
  );
  test(
    'rename, merge and undo recompute presentation without changing sources',
    () {
      final items = [item('a', 0, 16000, '甲'), item('b', 16000, 32000, '乙')];
      final original = document([
        segment('speaker_1', 0, 16000),
        segment('speaker_2', 16000, 32000),
      ]);
      final renamed = original.applyEdit(
        const SpeakerEdit.rename('speaker_1', '小林'),
      );
      expect(
        groupTimelineTurns(items, speakers: renamed).first.speakerLabel,
        '小林',
      );
      final merged = renamed.applyEdit(
        const SpeakerEdit.merge('speaker_2', 'speaker_1'),
      );
      expect(groupTimelineTurns(items, speakers: merged), hasLength(1));
      expect(
        groupTimelineTurns(
          items,
          speakers: merged.applyEdit(const SpeakerEdit.undo()),
        ),
        hasLength(2),
      );
      expect(items.map((i) => i.source.sampleOffset), [0, 16000]);
    },
  );
}

TimelineDisplayItem item(
  String id,
  int start,
  int end,
  String text, {
  String kind = 'transcript',
  TimelineTextLayer layer = TimelineTextLayer.refined,
}) => TimelineDisplayItem(
  source: TimelineItem.fromMap({
    'kind': kind,
    'segmentId': id,
    'sampleOffset': start,
    'endSample': end,
    'text': text,
    'captureState': 'committed',
    'type': kind == 'captureEvent' ? 'thought' : 'transcript',
  }),
  displayText: text,
  textLayer: layer,
);
SpeakerDiarizationSegment segment(String id, int start, int end) =>
    SpeakerDiarizationSegment(
      speakerId: id,
      startSample: start,
      endSample: end,
    );
SpeakerDiarizationDocument document(List<SpeakerDiarizationSegment> segments) =>
    SpeakerDiarizationDocument(
      sessionId: 's',
      modelId: 'synthetic',
      sourceAudioSamples: 1000000,
      sampleRate: 16000,
      sourceChunkFingerprint: 'sha256:test',
      createdAt: '2026-09-16T00:00:00Z',
      segments: segments,
      processingMs: 0,
      realTimeFactor: 0,
      peakRssBytes: 0,
      windowCount: 1,
    );
