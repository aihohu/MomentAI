import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/full_text_search.dart';
import 'package:momentai/product/local_search.dart';
import 'package:momentai/product/widgets/searchable_full_text.dart';

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/m2/speaker-text-v1.json').readAsStringSync(),
          )
          as Map;
  final speakers = SpeakerDiarizationDocument.fromMap(
    fixture['document'] as Map,
  );
  final timeline = (fixture['canonical']['segments'] as List)
      .map(
        (s) => TimelineItem.fromMap({
          ...s as Map,
          'kind': 'transcript',
          'sampleOffset': s['startSample'],
        }),
      )
      .toList();
  FullTextSearchDocument project({SpeakerDiarizationDocument? document}) =>
      projectFullTextForSearch(
        sessionId: speakers.sessionId,
        timeline: timeline,
        refinement: const FullTextRefinementSnapshot.unavailable(),
        speakers: document ?? speakers,
      );

  test(
    'speaker paragraphs retain all text, exact anchors and five attribution states',
    () {
      final output = project();
      expect(output.text, fixture['canonical']['fullText']);
      expect(
        output.paragraphs.map((p) => p.label),
        (fixture['expected']['segments'] as List).map((s) => s['label']),
      );
      for (final paragraph in output.paragraphs) {
        final text = output.text.substring(paragraph.start, paragraph.end);
        expect(text, paragraph.item.text);
        expect(
          output.search(text).first.playbackItem?.sampleOffset,
          paragraph.item.sampleOffset,
        );
      }
      final renamed = project(
        document: speakers.applyEdit(
          const SpeakerEdit.rename('speaker_1', '小林'),
        ),
      );
      expect(renamed.paragraphs.first.label, '小林');
      expect(renamed.text, output.text);
      final removed = projectFullTextForSearch(
        sessionId: speakers.sessionId,
        timeline: timeline,
        refinement: const FullTextRefinementSnapshot.unavailable(),
      );
      expect(removed.paragraphs, isEmpty);
      expect(removed.text, output.text);
    },
  );

  test('speaker result from another recording cannot label the text', () {
    final output = projectFullTextForSearch(
      sessionId: 'other',
      timeline: timeline,
      refinement: const FullTextRefinementSnapshot.unavailable(),
      speakers: speakers,
    );
    expect(output.paragraphs, isEmpty);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final segmented in [false, true]) {
      testWidgets(
        '$platform scrolling over text works repeatedly, including after selection; segmented=$segmented',
        (tester) async {
          final items = List.generate(
            80,
            (i) => TimelineItem.fromMap({
              'kind': 'transcript',
              'segmentId': 'long_$i',
              'sampleOffset': i * 16000,
              'endSample': (i + 1) * 16000,
              'text': '第$i段文字😀，这是用于验证从文字区域上下滑动的完整句子。' * 3,
            }),
          );
          final document = projectFullTextForSearch(
            sessionId: speakers.sessionId,
            timeline: items,
            refinement: const FullTextRefinementSnapshot.unavailable(),
            speakers: segmented ? speakers : null,
          );
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final key = GlobalKey<SearchableFullTextState>();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: ListView(
                  controller: scroll,
                  padding: const EdgeInsets.all(20),
                  children: [
                    SearchableFullText(
                      key: key,
                      text: document.text,
                      query: '完整句子',
                      paragraphs: document.paragraphs,
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          // Drag through glyphs, not the padding or scrollbar.
          for (var i = 0; i < 3; i++) {
            final before = scroll.offset;
            await tester.dragFrom(
              const Offset(160, 350),
              const Offset(0, -220),
            );
            await tester.pumpAndSettle();
            expect(scroll.offset, greaterThan(before + 100));
          }
          final before = scroll.offset;
          await tester.dragFrom(const Offset(160, 150), const Offset(0, 220));
          await tester.pumpAndSettle();
          expect(scroll.offset, lessThan(before - 100));
          final region = tester.state<SelectableRegionState>(
            find.byType(SelectableRegion),
          );
          region.selectAll(SelectionChangedCause.toolbar);
          await tester.pumpAndSettle();
          final selectedOffset = scroll.offset;
          await tester.dragFrom(const Offset(160, 350), const Offset(0, -180));
          await tester.pumpAndSettle();
          expect(scroll.offset, greaterThan(selectedOffset + 80));
          expect(
            key.currentState!.matchRect(
              searchTextRanges(document.text, '第79段').first,
            ),
            isNotNull,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'paragraphs expose speaker labels, playback and copy across speakers',
    (tester) async {
      final document = project();
      TimelineItem? played;
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SearchableFullText(
                text: document.text,
                query: '',
                paragraphs: document.paragraphs,
                onPlay: (item) => played = item,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(document.paragraphs.first.label), findsWidgets);
      await tester.tap(
        find.byKey(ValueKey('full-text-play-${timeline.first.playbackId}')),
      );
      expect(played?.sampleOffset, timeline.first.sampleOffset);
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.toolbar);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy').last);
      await tester.pumpAndSettle();
      for (final item in timeline) {
        expect(clipboard, contains(item.text));
      }
      expect(clipboard, contains(document.paragraphs.first.label));
    },
  );
}
