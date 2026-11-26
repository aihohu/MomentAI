import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/product/reading_text.dart';

void main() {
  test('groups sentences, preserves quotes and existing paragraphs', () {
    final first = '${'甲' * 54}。${'乙' * 54}。”';
    final second = '${'丙' * 60}。';
    final source = '$first$second\n\n保留原有短段。';
    final output = formatReadingText(source);
    expect(output.text, '$first\n\n$second\n\n保留原有短段。');
    expect(formatReadingText(output.text).text, output.text);
    expect(output.mapOffset(first.length), first.length + 2);
    expect(output.mapOffset(first.length, end: true), first.length);
  });

  test('bounds unpunctuated Chinese without changing Unicode content', () {
    final source = '${'无标点的访谈内容' * 60}👨‍👩‍👧‍👦e\u0301${'继续讨论' * 80}';
    final output = formatReadingText(source).text;
    expect(output.split('\n\n').length, greaterThan(2));
    expect(output.replaceAll('\n\n', ''), source);
    expect(output, contains('👨‍👩‍👧‍👦e\u0301'));
    expect(formatReadingText(output).text, output);
  });

  test('keeps short responses together and does not split English words', () {
    expect(formatReadingText('好。是的。可以。').text, '好。是的。可以。');
    final source =
        '${'A long discussion of version 1.25 and recording quality. ' * 12}Done.';
    final output = formatReadingText(source).text;
    expect(output.split('\n\n').length, greaterThan(1));
    expect(output.replaceAll('\n\n', ''), source);
    expect(output, contains('1.25'));
    expect(output, isNot(contains('record\n\ning')));
    final url = 'https://example.com/${'abcdef' * 100}';
    expect(formatReadingText(url).text, url);
  });

  test(
    'verified pauses can separate text without adding guessed punctuation',
    () {
      final first = '甲' * 80;
      final second = '乙' * 80;
      expect(formatReadingText('$first$second').text, '$first$second');
      expect(
        formatReadingText('$first$second', pauseOffsets: [80]).text,
        '$first\n\n$second',
      );
    },
  );
}
