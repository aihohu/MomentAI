import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/product/local_search.dart';
import 'package:momentai/product/widgets/virtual_full_text.dart';

void main() {
  test('layout blocks preserve offsets, newlines and grapheme clusters', () {
    final source = '${'👨‍👩‍👧‍👦á中' * 600}\r\n\r\nEnglish paragraph.\n末尾';
    final blocks = readingBlocks(source);
    expect(blocks.map((b) => source.substring(b.start, b.end)).join(), source);
    for (final block in blocks) {
      expect(
        source.substring(block.start, block.end).characters.length,
        lessThanOrEqualTo(480),
      );
    }
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets(
      'long reader builds bounded blocks and finds distant matches at scale $scale',
      (tester) async {
        final text = List.generate(
          1500,
          (i) => '段落 $i ${'这是长录音的自然段落。' * (i % 8 + 1)}',
        ).join('\n\n');
        final controller = ScrollController();
        final key = GlobalKey<VirtualFullTextState>();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: VirtualFullText(
                  key: key,
                  text: text,
                  query: '段落',
                  controller: controller,
                  header: const SizedBox(height: 260, child: Text('Header')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Finder blocks() => find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('reading-block-'),
        );
        expect(blocks().evaluate().length, lessThan(25));
        for (final phrase in ['段落 1490 ', '段落 12 ', '段落 800 ']) {
          final start = text.indexOf(phrase);
          final range = SearchTextRange(start, start + phrase.length);
          for (
            var i = 0;
            i < 40 && key.currentState!.matchRect(range) == null;
            i++
          ) {
            controller.jumpTo(key.currentState!.estimateOffset(range)!);
            await tester.pump();
          }
          final rect = key.currentState!.matchRect(range);
          expect(rect, isNotNull, reason: phrase);
          controller.jumpTo(
            (controller.offset + rect!.top - 180).clamp(
              0,
              controller.position.maxScrollExtent,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            key.currentState!.matchRect(range)!.top,
            inInclusiveRange(0, 600),
          );
          expect(blocks().evaluate().length, lessThan(25));
        }
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
