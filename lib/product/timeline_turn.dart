import 'package:flutter/widgets.dart' show StringCharacters;

import '../domain/speaker/speaker_diarization.dart';
import 'local_search.dart';
import 'reading_text.dart';
import 'speaker_localization.dart';
import 'timeline_display_item.dart';

/// Read-only presentation group. Every source segment keeps its own audio and
/// search anchor; display offsets are never converted into audio timestamps.
class TimelineTurn {
  TimelineTurn(this.items, {this.speakerId, this.speakerLabel}) {
    final buffer = StringBuffer();
    TimelineDisplayItem? previous;
    for (final item in items) {
      if (previous != null) buffer.write(_separator(previous, item));
      _sourceOffsets[item.source.playbackId] = buffer.length;
      buffer.write(item.displayText);
      previous = item;
    }
    final raw = buffer.toString();
    // A single original segment can itself be very long. Give it paragraph
    // breaks without manufacturing new audio anchors inside that segment.
    _reading = items.any((i) => i.textLayer == TimelineTextLayer.refined)
        ? formatReadingText(raw)
        : ReadingText(raw, const []);
    text = _reading.text;
    for (final entry in _sourceOffsets.entries) {
      offsets[entry.key] = _reading.mapOffset(entry.value);
    }
  }

  final List<TimelineDisplayItem> items;
  final String? speakerId;
  final String? speakerLabel;
  final offsets = <String, int>{};
  final _sourceOffsets = <String, int>{};
  late final ReadingText _reading;
  late final String text;
  TimelineDisplayItem get first => items.first;
  bool contains(String? id) => offsets.containsKey(id);
  SearchTextRange? rangeFor(String? id, SearchTextRange? range) {
    final offset = _sourceOffsets[id];
    return offset == null || range == null
        ? null
        : SearchTextRange(
            _reading.mapOffset(offset + range.start),
            _reading.mapOffset(offset + range.end, end: true),
          );
  }
}

List<TimelineTurn> groupTimelineTurns(
  List<TimelineDisplayItem> items, {
  SpeakerDiarizationDocument? speakers,
  int maximumGapSamples = 2 * 16000,
}) {
  final segments =
      speakers?.effectiveSegments ?? const <SpeakerDiarizationSegment>[];
  final groups = <TimelineTurn>[];
  var pending = <TimelineDisplayItem>[];
  String? pendingId;
  String? pendingLabel;
  var pendingLength = 0;
  void flush() {
    if (pending.isEmpty) return;
    groups.add(
      TimelineTurn(
        List.unmodifiable(pending),
        speakerId: pendingId,
        speakerLabel: pendingLabel,
      ),
    );
    pending = [];
    pendingLength = 0;
  }

  for (final display in items) {
    final item = display.source;
    final attribution =
        speakers != null &&
            item.isTranscript &&
            item.sampleOffset >= 0 &&
            item.endSample > item.sampleOffset &&
            item.endSample <= speakers.sourceAudioSamples
        ? localizedSpeakerAttribution(
            document: speakers,
            startSample: item.sampleOffset,
            endSample: item.endSample,
            effectiveSegments: segments,
          )
        : null;
    final id = attribution?['attribution'] == 'single'
        ? (attribution!['speakerIds'] as List<String>).single
        : null;
    var merge = false;
    final natural = display.textLayer == TimelineTextLayer.refined;
    final sameVoice = speakers == null || (id != null && pendingId == id);
    if (pending.isNotEmpty &&
        item.isTranscript &&
        pending.last.source.isTranscript &&
        sameVoice &&
        (id != null || natural) &&
        display.textLayer == pending.last.textLayer &&
        display.displayText.trim().isNotEmpty &&
        pending.last.displayText.trim().isNotEmpty) {
      final previous = pending.last.source;
      final gap = item.sampleOffset - previous.endSample;
      final duration = previous.endSample - pending.first.source.sampleOffset;
      // Prefer a complete sentence around 100 characters / 30 seconds. At
      // 240 characters / 60 seconds fall back to an existing source boundary.
      // These are grouping limits, not invented word-level timestamps.
      final paragraphComplete =
          natural &&
          ((pendingLength >= 100 || duration >= 30 * 16000) &&
              _endsSentence(pending.last.displayText));
      final paragraphFull =
          natural && (pendingLength >= 240 || duration >= 60 * 16000);
      merge =
          !paragraphComplete &&
          !paragraphFull &&
          previous.sampleOffset >= 0 &&
          previous.endSample > previous.sampleOffset &&
          item.endSample > item.sampleOffset &&
          gap >= 0 &&
          gap <= maximumGapSamples &&
          !segments.any(
            (s) =>
                s.speakerId != id &&
                s.startSample < item.sampleOffset &&
                s.endSample > previous.endSample,
          );
    }
    if (!merge) {
      flush();
      pendingId = id;
      pendingLabel = attribution?['label'] as String?;
    }
    if (pending.isNotEmpty) {
      pendingLength += _separator(pending.last, display).length;
    }
    pending.add(display);
    pendingLength += display.displayText.characters.length;
  }
  flush();
  return groups;
}

String _separator(TimelineDisplayItem previous, TimelineDisplayItem next) {
  if (previous.textLayer != TimelineTextLayer.refined ||
      next.textLayer != TimelineTextLayer.refined) {
    return ' ';
  }
  final left = previous.displayText;
  final right = next.displayText;
  if (left.isEmpty || right.isEmpty) return '';
  final last = left.characters.last;
  final first = right.characters.first;
  if (last.trim().isEmpty || first.trim().isEmpty) return '';
  if ('，。！？、；：,.!?;:）】》」』”’'.contains(first) || '（【《「『“‘'.contains(last)) {
    return '';
  }
  if ((_cjk(last) || '，。！？、；：）】》」』”’'.contains(last)) && _cjk(first)) {
    return '';
  }
  return ' ';
}

bool _cjk(String char) {
  final rune = char.runes.first;
  return (rune >= 0x3400 && rune <= 0x9fff) ||
      (rune >= 0x20000 && rune <= 0x323af) ||
      (rune >= 0x3040 && rune <= 0x30ff);
}

bool _endsSentence(String text) {
  final value = text.trimRight().replaceFirst(RegExp('[”’」』）》】"\']+\$'), '');
  if (RegExp(r'[。！？!?]$').hasMatch(value)) return true;
  return value.endsWith('.') &&
      !RegExp(
        r'(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|vs|etc)|\b[A-Za-z]|\d)\.$',
        caseSensitive: false,
      ).hasMatch(value);
}
