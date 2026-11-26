import 'package:flutter/widgets.dart' show StringCharacters;

/// Reading-only paragraph breaks. Persisted text and audio anchors stay intact.
class ReadingText {
  const ReadingText(this.text, this._breaks);

  final String text;
  final List<int> _breaks;

  int mapOffset(int offset, {bool end = false}) {
    var low = 0;
    var high = _breaks.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_breaks[mid] < offset || (!end && _breaks[mid] == offset)) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return offset + low * 2;
  }
}

ReadingText formatReadingText(
  String source, {
  Iterable<int> pauseOffsets = const [],
}) {
  final chars = source.characters.toList(growable: false);
  final offsets = <int>[0];
  for (final char in chars) {
    offsets.add(offsets.last + char.length);
  }
  final nextLine = List<int>.filled(chars.length + 1, chars.length);
  for (var i = chars.length - 1; i >= 0; i--) {
    nextLine[i] = chars[i].contains('\n') || chars[i].contains('\r')
        ? i
        : nextLine[i + 1];
  }
  final pauses = pauseOffsets.toSet();
  final breaks = <int>[];
  var start = 0;
  var soft = 0;
  const closers = '”’」』）》】"\'';

  bool sentenceEnd(int index) {
    if (index < chars.length && closers.contains(chars[index])) return false;
    var last = index - 1;
    while (last >= start && closers.contains(chars[last])) {
      last--;
    }
    if (last < start) return false;
    if ('。！？!?'.contains(chars[last])) return true;
    if (chars[last] != '.') return false;
    if (index < chars.length && chars[index].trim().isNotEmpty) return false;
    final prefix = source.substring(
      (offsets[last + 1] - 8).clamp(0, source.length),
      offsets[last + 1],
    );
    return !RegExp(
      r'(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|vs|etc)|\b[A-Za-z])\.$',
      caseSensitive: false,
    ).hasMatch(prefix);
  }

  for (var i = 1; i < chars.length; i++) {
    if (nextLine[i - 1] == i - 1) {
      start = i;
      soft = i;
      continue;
    }
    // Existing paragraph/line breaks take precedence. Keep a short closing
    // sentence with its preceding paragraph instead of leaving an orphan.
    if (nextLine[i] - i < 40) continue;
    final length = i - start;
    final boundary = chars[i - 1];
    if (length >= 100 &&
        (boundary.trim().isEmpty || '，,；;：:'.contains(boundary))) {
      soft = i;
    }
    int? cut;
    if ((length >= 100 && sentenceEnd(i)) ||
        (length >= 60 && pauses.contains(offsets[i]))) {
      cut = i;
    } else if (length >= 240) {
      if (soft > start) {
        cut = soft;
      } else if (_cjk(chars[i - 1]) && _cjk(chars[i])) {
        cut = i;
      }
    }
    if (cut != null) {
      breaks.add(offsets[cut]);
      start = cut;
      soft = cut;
    }
  }
  if (breaks.isEmpty) return ReadingText(source, const []);
  final result = StringBuffer();
  var cursor = 0;
  for (final offset in breaks) {
    result.write(source.substring(cursor, offset));
    result.write('\n\n');
    cursor = offset;
  }
  result.write(source.substring(cursor));
  return ReadingText(result.toString(), breaks);
}

bool _cjk(String char) {
  final rune = char.runes.first;
  return (rune >= 0x3400 && rune <= 0x9fff) ||
      (rune >= 0x20000 && rune <= 0x323af);
}
