import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/l10n/generated/app_localizations.dart';
import 'package:momentai/product/full_text_reading_document.dart';
import 'package:momentai/product/full_text_search.dart';
import 'package:momentai/product/widgets/virtual_full_text.dart';

TimelineItem event(
  String id,
  String type,
  int sample, {
  String text = '',
  String state = 'committed',
  String path = '',
}) => TimelineItem.fromMap({
  'kind': type == 'transcript' ? 'transcript' : 'captureEvent',
  'eventId': id,
  'type': type,
  'sampleOffset': sample,
  'endSample': sample + 16000,
  'text': text,
  'captureState': state,
  'assetPath': path,
});

void main() {
  final a = event('a', 'transcript', 0, text: '第一段。');
  final b = event('b', 'transcript', 32000, text: '第二段目标。');
  final base = FullTextSearchDocument(
    text: '第一段。\n\n第二段目标。',
    sourceLabel: '正文',
    anchors: [FullTextAnchor(0, 4, a), FullTextAnchor(6, 12, b)],
  );

  test(
    'events stay at paragraph boundaries, notes are searchable with exact anchors',
    () {
      final note = event('note', 'thought', 8000, text: '随想😀目标');
      final photo = event('photo', 'image', 10000);
      final mark = event('mark', 'bookmark', 12000);
      final result = composeFullTextReadingDocument(base, [
        a,
        note,
        photo,
        mark,
        b,
      ]);
      expect(result.attachments.map((a) => a.item.eventId), [
        'note',
        'photo',
        'mark',
      ]);
      expect(
        result.search.text.indexOf(note.text),
        greaterThan(result.search.text.indexOf(a.text)),
      );
      expect(
        result.search.text.indexOf(note.text),
        lessThan(result.search.text.indexOf(b.text)),
      );
      expect(result.attachments.every((a) => !a.unplaced), isTrue);
      final hits = result.search.search('目标');
      expect(hits.map((h) => h.playbackItem?.eventId), ['note', 'b']);
      for (final hit in hits) {
        expect(
          result.search.text.substring(hit.range.start, hit.range.end),
          '目标',
        );
      }
      expect(base.text, '第一段。\n\n第二段目标。');
      expect(result.search.anchors.map((a) => a.item.sampleOffset), [
        0,
        8000,
        32000,
      ]);
    },
  );

  test(
    'unverified alignment appends events and never invents transcript timing',
    () {
      final note = event('note', 'thought', 8000, text: '现场记录');
      const unaligned = FullTextSearchDocument(
        text: '重写后的全文。',
        sourceLabel: '正文',
        anchors: [],
      );
      final result = composeFullTextReadingDocument(unaligned, [note]);
      expect(result.search.text, startsWith(unaligned.text));
      expect(result.attachments.single.unplaced, isTrue);
      expect(result.search.search('重写').single.playbackItem, isNull);
      expect(result.search.search('现场').single.playbackItem, same(note));
    },
  );

  test(
    'nearby photos share one strip; failed and removed captures are excluded',
    () {
      final result = composeFullTextReadingDocument(base, [
        event('p1', 'image', 8000),
        event('p2', 'image', 10000),
        event('bad', 'thought', 11000, state: 'failed', text: '失败'),
        event('gone', 'image', 12000, state: 'tombstoned'),
      ]);
      expect(result.attachments.single.items.map((i) => i.eventId), [
        'p1',
        'p2',
      ]);
      expect(result.search.text, base.text);
    },
  );

  test('empty transcript still exposes photos notes and bookmarks', () {
    const empty = FullTextSearchDocument(
      text: '',
      sourceLabel: '正文',
      anchors: [],
    );
    final result = composeFullTextReadingDocument(empty, [
      event('p', 'image', 0),
      event('n', 'thought', 16000, text: '只有随想'),
      event('m', 'bookmark', 32000),
    ]);
    expect(result.attachments, hasLength(3));
    expect(result.search.search('随想').single.playbackItem?.eventId, 'n');
  });

  test(
    'note before first word shifts text start, note after last word keeps text end',
    () {
      final result = composeFullTextReadingDocument(base, [
        event('before', 'thought', 0, text: '开场😀'),
        event('after', 'thought', 64000, text: '结束😀'),
      ]);
      for (final anchor in result.search.anchors) {
        expect(
          result.search.text.substring(anchor.start, anchor.end),
          anchor.item.text,
        );
      }
    },
  );

  testWidgets(
    'long mixed document locates distant note and transcript with bounded layout',
    (tester) async {
      final text = StringBuffer();
      final anchors = <FullTextAnchor>[];
      final events = <TimelineItem>[];
      for (var i = 0; i < 600; i++) {
        final line = '正文$i：${'持续讨论的段落。' * (i % 8 + 1)}';
        final source = event('t$i', 'transcript', i * 160000, text: line);
        final start = text.length;
        text.write(line);
        anchors.add(FullTextAnchor(start, text.length, source));
        text.write('\n\n');
        if (i % 20 == 0) {
          events.add(event('p$i', 'image', i * 160000 + 1));
          events.add(
            event(
              'n$i',
              'thought',
              i * 160000 + 2,
              text: '随想$i：${'补充想法。' * (i % 3 + 1)}',
            ),
          );
        }
      }
      final doc = composeFullTextReadingDocument(
        FullTextSearchDocument(
          text: text.toString(),
          sourceLabel: '正文',
          anchors: anchors,
        ),
        events,
      );
      final scroll = ScrollController();
      final key = GlobalKey<VirtualFullTextState>();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: VirtualFullText(
                key: key,
                text: doc.search.text,
                attachments: doc.attachments,
                query: '',
                controller: scroll,
                header: const SizedBox(height: 200),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final query in ['随想580：', '正文12：', '正文599：']) {
        final hit = doc.search.search(query).single;
        for (
          var i = 0;
          i < 40 && key.currentState!.matchRect(hit.range) == null;
          i++
        ) {
          scroll.jumpTo(key.currentState!.estimateOffset(hit.range)!);
          await tester.pump();
        }
        final rect = key.currentState!.matchRect(hit.range);
        expect(rect, isNotNull, reason: query);
        scroll.jumpTo(
          (scroll.offset + rect!.top - 180).clamp(
            0,
            scroll.position.maxScrollExtent,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          key.currentState!.matchRect(hit.range)!.top,
          inInclusiveRange(0, 600),
        );
        expect(find.byType(RichText).evaluate().length, lessThan(50));
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'mixed reader shows notes, photos and bookmark actions at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final note = event('n', 'thought', 8000, text: '需要核对的随想目标');
        final result = composeFullTextReadingDocument(base, [
          note,
          event('p', 'image', 16000, path: '/missing-test-photo.jpg'),
          event('m', 'bookmark', 24000),
        ]);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final key = GlobalKey<VirtualFullTextState>();
        final played = <String>[];
        final opened = <String>[];
        final visited = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: VirtualFullText(
                  key: key,
                  text: result.search.text,
                  attachments: result.attachments,
                  query: '目标',
                  activeRange: result.search.search('目标').first.range,
                  controller: scroll,
                  header: const SizedBox(),
                  onPlay: (i) => played.add(i.eventId),
                  onOpenImage: (i) => opened.add(i.eventId),
                  onTimeline: (i) => visited.add(i.eventId),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          key.currentState!.matchRect(result.search.search('目标').first.range),
          isNotNull,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('fulltext-event-play-n')),
        );
        await tester.tap(find.byKey(const ValueKey('fulltext-event-play-n')));
        expect(played, ['n']);
        final photo = find.byKey(const ValueKey('fulltext-photo-p'));
        await tester.scrollUntilVisible(
          photo,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(photo);
        expect(opened, ['p']);
        final mark = find.byKey(const ValueKey('fulltext-event-timeline-m'));
        await tester.scrollUntilVisible(
          mark,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(mark);
        expect(visited, ['m']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
