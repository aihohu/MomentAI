import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:momentai/l10n/app_localization.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../domain/audio/committed_audio_chunk.dart';
import '../../domain/timeline/timeline_item.dart';
import '../../domain/transcript/refined_full_text.dart';
import '../models/local_model_manifest.dart';
import '../models/local_model_runtime.dart';

const senseVoiceFullTextModelId = senseVoiceRefinementModelId;
const _senseVoiceAssetDirectory = 'assets/$senseVoiceFullTextModelId';
const _refinementFileName = 'full_text_refinement.json';
const _modelFileName = 'model.int8.onnx';
const _tokensFileName = 'tokens.txt';
const _maximumSegmentSamples = 30 * 16000;
const _mergeGapSamples = 1200 * 16;
const _edgePaddingSamples = 800 * 16;
const _minimumProjectionTextCoveragePercent = 45;

class RefinementTimelineSource {
  const RefinementTimelineSource({
    required this.segmentId,
    required this.startSample,
    required this.endSample,
    required this.text,
  });

  factory RefinementTimelineSource.fromMap(Map<Object?, Object?> map) =>
      RefinementTimelineSource(
        segmentId: map['segmentId']?.toString() ?? '',
        startSample: _messageInteger(map['startSample']),
        endSample: _messageInteger(map['endSample']),
        text: map['text']?.toString() ?? '',
      );

  final String segmentId;
  final int startSample;
  final int endSample;
  final String text;

  Map<String, Object?> toMap() => <String, Object?>{
    'segmentId': segmentId,
    'startSample': startSample,
    'endSample': endSample,
    'text': text,
  };
}

List<RefinementTimelineSource> refinementTimelineSources(
  Iterable<TimelineItem> timeline,
) {
  final sources = timeline
      .where(
        (item) =>
            item.isTranscript &&
            item.eventId.isNotEmpty &&
            item.endSample > item.sampleOffset &&
            item.text.trim().isNotEmpty,
      )
      .map(
        (item) => RefinementTimelineSource(
          segmentId: item.eventId,
          startSample: item.sampleOffset,
          endSample: item.endSample,
          text: item.text,
        ),
      )
      .toList(growable: false);
  sources.sort((left, right) {
    final byStart = left.startSample.compareTo(right.startSample);
    if (byStart != 0) return byStart;
    final byEnd = left.endSample.compareTo(right.endSample);
    if (byEnd != 0) return byEnd;
    return left.segmentId.compareTo(right.segmentId);
  });
  return sources;
}

String sourceTimelineFingerprint(Iterable<RefinementTimelineSource> sources) {
  final ordered = sources.toList(growable: false);
  ordered.sort((left, right) {
    final byStart = left.startSample.compareTo(right.startSample);
    if (byStart != 0) return byStart;
    final byEnd = left.endSample.compareTo(right.endSample);
    if (byEnd != 0) return byEnd;
    return left.segmentId.compareTo(right.segmentId);
  });
  final canonical = ordered
      .map(
        (source) => <String, Object?>{
          'segmentId': source.segmentId,
          'startSample': source.startSample,
          'endSample': source.endSample,
          'text': source.text,
        },
      )
      .toList(growable: false);
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode(canonical)))}';
}

class FullTextRefinementRequest {
  const FullTextRefinementRequest({
    required this.sessionId,
    required this.directory,
    required this.chunks,
    required this.timeline,
    this.forceRebuild = false,
  });

  final String sessionId;
  final String directory;
  final List<CommittedAudioChunk> chunks;
  final List<TimelineItem> timeline;
  final bool forceRebuild;
}

abstract interface class FullTextRefinementService {
  bool isRefining(String directory);

  Future<FullTextRefinementSnapshot> snapshot(String directory);

  Future<RefinedFullTextDocument> refine(FullTextRefinementRequest request);
}

class SenseVoiceFullTextRefinementService implements FullTextRefinementService {
  SenseVoiceFullTextRefinementService({this.modelResolver});

  final LocalModelRuntimeResolver? modelResolver;
  final Map<String, Future<RefinedFullTextDocument>> _jobs = {};

  final _failures = <String, Object>{};

  bool get hasActiveJobs => _jobs.isNotEmpty;

  @override
  bool isRefining(String directory) => _jobs.containsKey(directory);

  @override
  Future<FullTextRefinementSnapshot> snapshot(String directory) async {
    if (isRefining(directory)) {
      return const FullTextRefinementSnapshot.processing();
    }
    final saved = await _readPersistedSnapshot(directory);
    final failure = _failures[directory];
    return failure == null
        ? saved
        : FullTextRefinementSnapshot(
            status: FullTextRefinementStatus.failed,
            document: saved.document,
            message: "$failure",
          );
  }

  Future<FullTextRefinementSnapshot> _readPersistedSnapshot(
    String directory,
  ) async {
    final file = File('$directory/$_refinementFileName');
    if (!await file.exists()) {
      return const FullTextRefinementSnapshot.unavailable();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Refinement payload is not an object.');
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['status'] == 'ready') {
        final schemaVersion = map['schemaVersion'] is num
            ? (map['schemaVersion'] as num).round()
            : int.tryParse('${map['schemaVersion']}') ?? 0;
        var document = RefinedFullTextDocument.fromMap(map);
        var shouldRewrite = schemaVersion < refinedFullTextSchemaVersion;
        if (schemaVersion == refinedFullTextSchemaVersion &&
            document.composerVersion == 3 &&
            document.canonicalTokens.isNotEmpty &&
            document.timelineProjection.isNotEmpty) {
          final persistedSources = document.timelineProjection
              .map(
                (segment) => RefinementTimelineSource(
                  segmentId: segment.segmentId,
                  startSample: segment.startSample,
                  endSample: segment.endSample,
                  text: segment.refinedText,
                ),
              )
              .toList(growable: false);
          final recomposed = composeProjectedRefinedFullText(
            projection: document.timelineProjection,
            canonicalTokens: document.canonicalTokens,
            sources: persistedSources,
          );
          if (recomposed.isNotEmpty) {
            document = _copyWithFullText(
              document,
              recomposed,
              composerVersion: refinedTimelineComposerVersion,
            );
            shouldRewrite = true;
          }
        }
        if (schemaVersion < refinedFullTextSchemaVersion ||
            document.canonicalTokens.isEmpty) {
          final recomposed = composeRefinedFullText(document.segments);
          if (recomposed.isNotEmpty && recomposed != document.fullText) {
            document = _copyWithFullText(document, recomposed);
          }
        }
        if (shouldRewrite) {
          await _writeAtomically(file, document.toMap());
        }
        return FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.ready,
          document: document,
        );
      }
      if (map['status'] == 'failed') {
        return FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.failed,
          message: map['message']?.toString() ?? l10n.refinementFailed,
        );
      }
    } catch (error) {
      return FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.failed,
        message: l10n.couldNotReadTheRefinedTranscript((error).toString()),
      );
    }
    return const FullTextRefinementSnapshot.unavailable();
  }

  @override
  Future<RefinedFullTextDocument> refine(FullTextRefinementRequest request) {
    final existing = _jobs[request.directory];
    if (existing != null) return existing;
    late final Future<RefinedFullTextDocument> job;
    _failures.remove(request.directory);
    job = _refineOnce(request)
        .catchError((Object error, StackTrace stack) {
          _failures[request.directory] = error;
          Error.throwWithStackTrace(error, stack);
        })
        .whenComplete(() {
          if (identical(_jobs[request.directory], job)) {
            _jobs.remove(request.directory);
          }
        });
    _jobs[request.directory] = job;
    return job;
  }

  Future<RefinedFullTextDocument> _refineOnce(
    FullTextRefinementRequest request,
  ) async {
    if (request.sessionId.isEmpty || request.directory.isEmpty) {
      throw ArgumentError('Session id and directory are required.');
    }
    if (request.chunks.isEmpty) {
      throw StateError(l10n.noSavedAudioIsAvailableForRefinement);
    }
    final chunks = request.chunks.toList(growable: false)
      ..sort((left, right) => left.index.compareTo(right.index));
    final sourceAudioSamples = chunks.last.endSample;
    final timelineSources = refinementTimelineSources(request.timeline);
    final timelineFingerprint = sourceTimelineFingerprint(timelineSources);
    final existing = await _readPersistedSnapshot(request.directory);
    final existingDocument = existing.document;
    if (!request.forceRebuild &&
        existingDocument != null &&
        existingDocument.modelId == senseVoiceFullTextModelId &&
        existingDocument.sourceAudioSamples == sourceAudioSamples &&
        existingDocument.sourceTimelineFingerprint == timelineFingerprint &&
        existingDocument.composerVersion == refinedTimelineComposerVersion &&
        _projectionMatchesSources(
          existingDocument.timelineProjection,
          timelineSources,
        )) {
      return existingDocument;
    }

    final runtimeFiles = await modelResolver?.refinementModelFiles();
    final modelFiles = runtimeFiles == null
        ? modelResolver == null
              ? _resolveBundledModelFiles()
              : throw StateError(
                  l10n.sensevoiceIsNotInstalledYourLiveTranscript,
                )
        : _BundledModelFiles(
            modelId: runtimeFiles.modelId,
            modelPath: runtimeFiles.modelPath,
            tokensPath: runtimeFiles.tokensPath,
          );
    final ranges = planFullTextRefinementRanges(
      timeline: request.timeline,
      sourceAudioSamples: sourceAudioSamples,
    );
    final message = <String, Object?>{
      'sessionId': request.sessionId,
      'directory': request.directory,
      'modelPath': modelFiles.modelPath,
      'tokensPath': modelFiles.tokensPath,
      'modelId': modelFiles.modelId,
      'sourceAudioSamples': sourceAudioSamples,
      'sampleRate': chunks.first.sampleRate,
      'chunks': chunks.map((chunk) => chunk.toMessage()).toList(),
      'ranges': ranges.map((range) => range.toMap()).toList(),
      'sourceTimelineFingerprint': timelineFingerprint,
      'timelineSources': timelineSources
          .map((source) => source.toMap())
          .toList(),
    };

    try {
      final language = applicationLocale.languageCode;
      final resultMap = await Isolate.run(() {
        setApplicationLanguage(language);
        return _runSenseVoiceWorker(message);
      });
      final document = RefinedFullTextDocument.fromMap(resultMap);
      await _writeAtomically(
        File('${request.directory}/$_refinementFileName'),
        document.toMap(),
      );
      return document;
    } catch (error) {
      // A failed retry must not overwrite the last usable refinement.
      if (existingDocument == null) {
        await _writeAtomically(
          File('${request.directory}/$_refinementFileName'),
          <String, Object?>{
            'schemaVersion': refinedFullTextSchemaVersion,
            'status': 'failed',
            'sessionId': request.sessionId,
            'modelId': senseVoiceFullTextModelId,
            'sourceAudioSamples': sourceAudioSamples,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'message': '$error',
          },
        );
      }
      rethrow;
    }
  }
}

bool _projectionMatchesSources(
  Iterable<RefinedTimelineSegment> projection,
  Iterable<RefinementTimelineSource> sources,
) {
  final projectedIds = projection.map((item) => item.segmentId).toList();
  final sourceIds = sources.map((item) => item.segmentId).toList();
  if (projectedIds.length != sourceIds.length) return false;
  for (var index = 0; index < sourceIds.length; index += 1) {
    if (projectedIds[index] != sourceIds[index]) return false;
  }
  return true;
}

class FullTextRefinementRange {
  const FullTextRefinementRange({
    required this.startSample,
    required this.endSample,
  });

  final int startSample;
  final int endSample;

  Map<String, Object?> toMap() => <String, Object?>{
    'startSample': startSample,
    'endSample': endSample,
  };
}

List<FullTextRefinementRange> planFullTextRefinementRanges({
  required Iterable<TimelineItem> timeline,
  required int sourceAudioSamples,
}) {
  if (sourceAudioSamples <= 0) return const [];
  final transcriptRanges =
      timeline
          .where(
            (item) =>
                item.isTranscript &&
                item.endSample > item.sampleOffset &&
                item.sampleOffset < sourceAudioSamples,
          )
          .map(
            (item) => FullTextRefinementRange(
              startSample: (item.sampleOffset - _edgePaddingSamples)
                  .clamp(0, sourceAudioSamples)
                  .toInt(),
              endSample: (item.endSample + _edgePaddingSamples)
                  .clamp(0, sourceAudioSamples)
                  .toInt(),
            ),
          )
          .toList()
        ..sort((left, right) => left.startSample.compareTo(right.startSample));

  if (transcriptRanges.isEmpty) {
    return _fixedRanges(0, sourceAudioSamples);
  }

  final merged = <FullTextRefinementRange>[];
  for (final candidate in transcriptRanges) {
    if (merged.isEmpty) {
      merged.add(candidate);
      continue;
    }
    final previous = merged.last;
    final combinedEnd = candidate.endSample > previous.endSample
        ? candidate.endSample
        : previous.endSample;
    final closeEnough =
        candidate.startSample - previous.endSample <= _mergeGapSamples;
    final fitsModel =
        combinedEnd - previous.startSample <= _maximumSegmentSamples;
    if (closeEnough && fitsModel) {
      merged[merged.length - 1] = FullTextRefinementRange(
        startSample: previous.startSample,
        endSample: combinedEnd,
      );
    } else {
      merged.add(candidate);
    }
  }

  return merged
      .expand((range) => _fixedRanges(range.startSample, range.endSample))
      .toList(growable: false);
}

List<FullTextRefinementRange> _fixedRanges(int startSample, int endSample) {
  final ranges = <FullTextRefinementRange>[];
  var cursor = startSample;
  while (cursor < endSample) {
    final next = (cursor + _maximumSegmentSamples)
        .clamp(cursor, endSample)
        .toInt();
    ranges.add(FullTextRefinementRange(startSample: cursor, endSample: next));
    cursor = next;
  }
  return ranges;
}

/// Selects exactly one trusted owner for every model-window overlap.
///
/// Refinement windows have symmetric padding around the immutable live
/// transcript boundary. Splitting an overlap at its sample midpoint keeps the
/// token from the window where it has more context, without changing any
/// timeline anchor or guessing from recognition text.
List<RefinedFullTextToken> canonicalizeRefinementTokens({
  required Iterable<RefinedFullTextToken> candidates,
  required List<FullTextRefinementRange> windows,
}) {
  if (windows.isEmpty) return const [];
  final trustedStarts = <int>[];
  final trustedEnds = <int>[];
  for (var index = 0; index < windows.length; index += 1) {
    final window = windows[index];
    var trustedStart = window.startSample;
    var trustedEnd = window.endSample;
    if (index > 0) {
      final previous = windows[index - 1];
      if (previous.endSample > window.startSample) {
        trustedStart = (previous.endSample + window.startSample) ~/ 2;
      }
    }
    if (index + 1 < windows.length) {
      final next = windows[index + 1];
      if (window.endSample > next.startSample) {
        trustedEnd = (window.endSample + next.startSample) ~/ 2;
      }
    }
    trustedStarts.add(trustedStart.clamp(window.startSample, window.endSample));
    trustedEnds.add(trustedEnd.clamp(window.startSample, window.endSample));
  }

  final canonical = candidates
      .where((token) {
        final windowIndex = token.sourceWindowIndex;
        if (windowIndex < 0 || windowIndex >= windows.length) return false;
        final window = windows[windowIndex];
        if (token.text.isEmpty ||
            token.atSample < window.startSample ||
            token.atSample >= window.endSample) {
          return false;
        }
        return token.atSample >= trustedStarts[windowIndex] &&
            token.atSample < trustedEnds[windowIndex];
      })
      .toList(growable: false);
  canonical.sort((left, right) {
    final bySample = left.atSample.compareTo(right.atSample);
    if (bySample != 0) return bySample;
    final byWindow = left.sourceWindowIndex.compareTo(right.sourceWindowIndex);
    if (byWindow != 0) return byWindow;
    return left.sourceTokenIndex.compareTo(right.sourceTokenIndex);
  });
  return canonical;
}

String composeCanonicalRefinedFullText({
  required Iterable<RefinedFullTextToken> canonicalTokens,
  required List<FullTextRefinementRange> windows,
}) {
  final tokens = canonicalTokens.toList(growable: false);
  if (tokens.isEmpty || windows.isEmpty) return '';
  final paragraphs = <StringBuffer>[StringBuffer()];
  RefinedFullTextToken? previous;
  for (final token in tokens) {
    if (token.sourceWindowIndex < 0 ||
        token.sourceWindowIndex >= windows.length) {
      continue;
    }
    final previousToken = previous;
    if (previousToken != null &&
        previousToken.sourceWindowIndex != token.sourceWindowIndex &&
        previousToken.sourceWindowIndex >= 0 &&
        previousToken.sourceWindowIndex < windows.length &&
        windows[token.sourceWindowIndex].startSample >=
            windows[previousToken.sourceWindowIndex].endSample) {
      paragraphs.add(StringBuffer());
    }
    paragraphs.last.write(token.text);
    previous = token;
  }
  return paragraphs
      .map(
        (paragraph) => _normalizeRefinedTextSpacing(
          _cleanRecognizedText(
            paragraph.toString().replaceAll('▁', ' ').replaceAll('@@', ''),
          ),
        ),
      )
      .where((paragraph) => paragraph.isNotEmpty)
      .join('\n\n');
}

List<RefinedTimelineSegment> projectRefinedTimeline({
  required Iterable<RefinedFullTextToken> canonicalTokens,
  required Iterable<RefinementTimelineSource> sources,
  int edgeToleranceSamples = _edgePaddingSamples,
}) {
  final orderedSources = sources.toList(growable: false);
  orderedSources.sort((left, right) {
    final byStart = left.startSample.compareTo(right.startSample);
    if (byStart != 0) return byStart;
    return left.segmentId.compareTo(right.segmentId);
  });
  final buckets = <String, List<RefinedFullTextToken>>{
    for (final source in orderedSources) source.segmentId: [],
  };
  for (final token in canonicalTokens) {
    final source = _sourceForToken(token, orderedSources, edgeToleranceSamples);
    if (source != null) buckets[source.segmentId]!.add(token);
  }

  return orderedSources
      .map((source) {
        final tokens = buckets[source.segmentId]!;
        final hasLexicalContent = tokens.any(
          (token) => _hasLexicalContent(token.text),
        );
        if (!hasLexicalContent) {
          return RefinedTimelineSegment(
            segmentId: source.segmentId,
            startSample: source.startSample,
            endSample: source.endSample,
            refinedText: source.text,
            fallback: true,
          );
        }
        final refinedText = _cleanRecognizedText(
          tokens.map((token) => token.text).join(),
        );
        final insufficientCoverage = _hasInsufficientTextCoverage(
          sourceText: source.text,
          refinedText: refinedText,
        );
        return RefinedTimelineSegment(
          segmentId: source.segmentId,
          startSample: source.startSample,
          endSample: source.endSample,
          refinedText: refinedText.isEmpty || insufficientCoverage
              ? source.text
              : _normalizeRefinedTextSpacing(refinedText),
          fallback: refinedText.isEmpty || insufficientCoverage,
        );
      })
      .toList(growable: false);
}

String composeProjectedRefinedFullText({
  required Iterable<RefinedTimelineSegment> projection,
  required Iterable<RefinedFullTextToken> canonicalTokens,
  required Iterable<RefinementTimelineSource> sources,
  int edgeToleranceSamples = _edgePaddingSamples,
}) {
  final orderedSources = sources.toList(growable: false);
  orderedSources.sort((left, right) {
    final byStart = left.startSample.compareTo(right.startSample);
    if (byStart != 0) return byStart;
    return left.segmentId.compareTo(right.segmentId);
  });
  final projectionById = <String, RefinedTimelineSegment>{
    for (final segment in projection) segment.segmentId: segment,
  };
  final buckets = <String, List<RefinedFullTextToken>>{
    for (final source in orderedSources) source.segmentId: [],
  };
  for (final token in canonicalTokens) {
    final source = _sourceForToken(token, orderedSources, edgeToleranceSamples);
    if (source != null) buckets[source.segmentId]!.add(token);
  }

  final buffer = StringBuffer();
  for (final source in orderedSources) {
    final segment = projectionById[source.segmentId];
    if (segment == null) continue;
    final tokenText = buckets[source.segmentId]!
        .map((token) => token.text)
        .join();
    final text = segment.fallback
        ? source.text.trim()
        : tokenText.isEmpty
        ? segment.refinedText
        : tokenText;
    if (text.isEmpty) continue;
    if (segment.fallback &&
        _isShortFallbackSuffixDuplicate(buffer.toString(), text)) {
      continue;
    }
    if (buffer.isNotEmpty &&
        !RegExp(r'^\s').hasMatch(text) &&
        _needsCrossScriptSpace(
          buffer.toString().runes.last,
          text.runes.first,
        )) {
      buffer.write(' ');
    }
    buffer.write(text);
  }
  return _normalizeRefinedTextSpacing(_cleanRecognizedText(buffer.toString()));
}

RefinementTimelineSource? _sourceForToken(
  RefinedFullTextToken token,
  List<RefinementTimelineSource> sources,
  int tolerance,
) {
  RefinementTimelineSource? previous;
  RefinementTimelineSource? next;
  for (final source in sources) {
    if (token.atSample >= source.startSample &&
        token.atSample < source.endSample) {
      return source;
    }
    if (source.endSample <= token.atSample) previous = source;
    if (source.startSample > token.atSample) {
      next = source;
      break;
    }
  }
  final previousDistance = previous == null
      ? tolerance + 1
      : token.atSample - previous.endSample;
  final nextDistance = next == null
      ? tolerance + 1
      : next.startSample - token.atSample;
  if (previousDistance > tolerance && nextDistance > tolerance) return null;
  if (!_hasLexicalContent(token.text) && previousDistance <= tolerance) {
    return previous;
  }
  return previousDistance < nextDistance ? previous : next;
}

bool _hasLexicalContent(String text) => text
    .replaceAll(RegExp(r'''[\s，。！？；：、,.!?;:…“”‘’"'（）()\[\]【】—-]'''), '')
    .isNotEmpty;

bool _hasInsufficientTextCoverage({
  required String sourceText,
  required String refinedText,
}) {
  final sourceLength = _lexicalRuneCount(sourceText);
  if (sourceLength < 12) return false;
  final refinedLength = _lexicalRuneCount(refinedText);
  return refinedLength * 100 <
      sourceLength * _minimumProjectionTextCoveragePercent;
}

int _lexicalRuneCount(String text) => text
    .replaceAll(RegExp(r'''[\s，。！？；：、,.!?;:…“”‘’"'（）()\[\]【】—-]'''), '')
    .runes
    .length;

bool _isShortFallbackSuffixDuplicate(String existing, String fallback) {
  final fallbackLexical = fallback.replaceAll(
    RegExp(r'''[\s，。！？；：、,.!?;:…“”‘’"'（）()\[\]【】—-]'''),
    '',
  );
  if (fallbackLexical.isEmpty || fallbackLexical.runes.length > 8) {
    return false;
  }
  final existingLexical = existing.replaceAll(
    RegExp(r'''[\s，。！？；：、,.!?;:…“”‘’"'（）()\[\]【】—-]'''),
    '',
  );
  return existingLexical.endsWith(fallbackLexical);
}

String _normalizeRefinedTextSpacing(String value) => value
    .replaceAllMapped(
      RegExp(r'([\u3400-\u9fff])([A-Za-z0-9])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    )
    .replaceAllMapped(
      RegExp(r'([A-Za-z0-9])([\u3400-\u9fff])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    )
    .replaceAllMapped(
      RegExp(r'([。！？.!?])(?=[A-Za-z])'),
      (match) => '${match.group(1)} ',
    )
    .replaceAllMapped(
      RegExp(r'([.!?])(?=[\u3400-\u9fff])'),
      (match) => '${match.group(1)} ',
    );

bool _needsCrossScriptSpace(int left, int right) =>
    (_isCjkRune(left) && _isAsciiWordRune(right)) ||
    (_isAsciiWordRune(left) && _isCjkRune(right));

bool _isCjkRune(int rune) => rune >= 0x3400 && rune <= 0x9fff;

bool _isAsciiWordRune(int rune) =>
    (rune >= 0x30 && rune <= 0x39) ||
    (rune >= 0x41 && rune <= 0x5a) ||
    (rune >= 0x61 && rune <= 0x7a);

_BundledModelFiles _resolveBundledModelFiles() {
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  final flutterAssets = Directory(
    '${executableDirectory.path}/Frameworks/App.framework/flutter_assets',
  );
  final modelPath =
      '${flutterAssets.path}/$_senseVoiceAssetDirectory/$_modelFileName';
  final tokensPath =
      '${flutterAssets.path}/$_senseVoiceAssetDirectory/$_tokensFileName';
  if (!File(modelPath).existsSync() || !File(tokensPath).existsSync()) {
    throw StateError(l10n.theBundledSensevoiceFilesAreMissingReinstall);
  }
  return _BundledModelFiles(
    modelId: senseVoiceFullTextModelId,
    modelPath: modelPath,
    tokensPath: tokensPath,
  );
}

Future<void> _writeAtomically(
  File destination,
  Map<String, Object?> payload,
) async {
  final temporary = File('${destination.path}.part');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
    flush: true,
  );
  if (await destination.exists()) await destination.delete();
  await temporary.rename(destination.path);
}

Map<String, dynamic> _runSenseVoiceWorker(Map<String, Object?> message) {
  sherpa.initBindings();
  final initializationWatch = Stopwatch()..start();
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: message['modelPath']! as String,
          language: 'auto',
          useInverseTextNormalization: true,
        ),
        tokens: message['tokensPath']! as String,
        numThreads: 2,
        debug: false,
        modelType: 'sense_voice',
      ),
    ),
  );
  initializationWatch.stop();

  final chunks = (message['chunks']! as List<Object?>)
      .map(
        (item) =>
            _WorkerChunk.fromMap(Map<Object?, Object?>.from(item! as Map)),
      )
      .toList(growable: false);
  final ranges = (message['ranges']! as List<Object?>)
      .map(
        (item) =>
            _WorkerRange.fromMap(Map<Object?, Object?>.from(item! as Map)),
      )
      .toList(growable: false);
  final timelineSources = (message['timelineSources']! as List<Object?>)
      .map(
        (item) => RefinementTimelineSource.fromMap(
          Map<Object?, Object?>.from(item! as Map),
        ),
      )
      .toList(growable: false);
  final sampleRate = message['sampleRate']! as int;
  final segments = <RefinedFullTextSegment>[];
  final tokenCandidates = <RefinedFullTextToken>[];
  var decodeMs = 0;
  var peakRssBytes = ProcessInfo.currentRss;

  try {
    for (var windowIndex = 0; windowIndex < ranges.length; windowIndex += 1) {
      final range = ranges[windowIndex];
      final samples = _readPcmRange(chunks, range);
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
        final decodeWatch = Stopwatch()..start();
        recognizer.decode(stream);
        decodeWatch.stop();
        decodeMs += decodeWatch.elapsedMilliseconds;
        final result = recognizer.getResult(stream);
        final text = _cleanRecognizedText(result.text);
        if (_hasUsableTokenTimestamps(
          tokens: result.tokens,
          timestamps: result.timestamps,
          range: range,
          sampleRate: sampleRate,
        )) {
          for (
            var tokenIndex = 0;
            tokenIndex < result.tokens.length;
            tokenIndex += 1
          ) {
            final tokenText = result.tokens[tokenIndex];
            if (tokenText.isEmpty) continue;
            tokenCandidates.add(
              RefinedFullTextToken(
                text: tokenText,
                atSample:
                    range.startSample +
                    (result.timestamps[tokenIndex] * sampleRate).round(),
                sourceWindowIndex: windowIndex,
                sourceTokenIndex: tokenIndex,
              ),
            );
          }
        }
        if (text.isNotEmpty) {
          segments.add(
            RefinedFullTextSegment(
              startSample: range.startSample,
              endSample: range.endSample,
              text: text,
              language: result.lang,
              emotion: result.emotion,
              event: result.event,
            ),
          );
        }
        final rss = ProcessInfo.currentRss;
        if (rss > peakRssBytes) peakRssBytes = rss;
      } finally {
        stream.free();
      }
    }
  } finally {
    recognizer.free();
  }

  final sourceAudioSamples = message['sourceAudioSamples']! as int;
  final publicRanges = ranges
      .map(
        (range) => FullTextRefinementRange(
          startSample: range.startSample,
          endSample: range.endSample,
        ),
      )
      .toList(growable: false);
  final canonicalTokens = canonicalizeRefinementTokens(
    candidates: tokenCandidates,
    windows: publicRanges,
  );
  final timelineProjection = projectRefinedTimeline(
    canonicalTokens: canonicalTokens,
    sources: timelineSources,
    edgeToleranceSamples: _edgePaddingSamples,
  );
  final canonicalFullText = composeCanonicalRefinedFullText(
    canonicalTokens: canonicalTokens,
    windows: publicRanges,
  );
  final projectedFullText = composeProjectedRefinedFullText(
    projection: timelineProjection,
    canonicalTokens: canonicalTokens,
    sources: timelineSources,
  );
  final fullText = projectedFullText.isNotEmpty
      ? projectedFullText
      : canonicalFullText.isNotEmpty
      ? canonicalFullText
      : composeRefinedFullText(segments);
  if (fullText.trim().isEmpty) {
    throw StateError(l10n.sensevoiceDidNotProduceAUsableTranscript);
  }
  final decodedSamples = ranges.fold<int>(
    0,
    (total, range) => total + range.endSample - range.startSample,
  );
  final audioSeconds = decodedSamples / sampleRate;
  return <String, dynamic>{
    'schemaVersion': refinedFullTextSchemaVersion,
    'status': 'ready',
    'sessionId': message['sessionId']! as String,
    'modelId': message['modelId']! as String,
    'fullText': fullText,
    'sourceAudioSamples': sourceAudioSamples,
    'sampleRate': sampleRate,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'initializationMs': initializationWatch.elapsedMilliseconds,
    'decodeMs': decodeMs,
    'realTimeFactor': audioSeconds <= 0 ? 0 : decodeMs / 1000 / audioSeconds,
    'peakRssBytes': peakRssBytes,
    'sourceTimelineFingerprint':
        message['sourceTimelineFingerprint']! as String,
    'composerVersion': refinedTimelineComposerVersion,
    'canonicalTokens': canonicalTokens.map((token) => token.toMap()).toList(),
    'timelineProjection': timelineProjection
        .map((segment) => segment.toMap())
        .toList(),
    'segments': segments.map((segment) => segment.toMap()).toList(),
  };
}

bool _hasUsableTokenTimestamps({
  required List<String> tokens,
  required List<double> timestamps,
  required _WorkerRange range,
  required int sampleRate,
}) {
  if (tokens.isEmpty || tokens.length != timestamps.length) return false;
  final durationSeconds = (range.endSample - range.startSample) / sampleRate;
  var previous = double.negativeInfinity;
  for (final timestamp in timestamps) {
    if (!timestamp.isFinite ||
        timestamp < 0 ||
        timestamp > durationSeconds + 0.5 ||
        timestamp + 0.000001 < previous) {
      return false;
    }
    previous = timestamp;
  }
  return true;
}

RefinedFullTextDocument _copyWithFullText(
  RefinedFullTextDocument source,
  String fullText, {
  int? composerVersion,
}) => RefinedFullTextDocument(
  sessionId: source.sessionId,
  modelId: source.modelId,
  fullText: fullText,
  sourceAudioSamples: source.sourceAudioSamples,
  sampleRate: source.sampleRate,
  createdAt: source.createdAt,
  segments: source.segments,
  initializationMs: source.initializationMs,
  decodeMs: source.decodeMs,
  realTimeFactor: source.realTimeFactor,
  peakRssBytes: source.peakRssBytes,
  sourceTimelineFingerprint: source.sourceTimelineFingerprint,
  composerVersion: composerVersion ?? source.composerVersion,
  canonicalTokens: source.canonicalTokens,
  timelineProjection: source.timelineProjection,
);

String composeRefinedFullText(Iterable<RefinedFullTextSegment> segments) {
  final ordered = segments.toList(growable: false);
  if (ordered.isEmpty) return '';
  final paragraphs = <String>[];
  var paragraph = ordered.first.text;
  var previous = ordered.first;
  for (final current in ordered.skip(1)) {
    if (current.startSample < previous.endSample) {
      paragraph = _stitchOverlappingText(paragraph, current.text);
    } else {
      paragraphs.add(paragraph);
      paragraph = current.text;
    }
    previous = current;
  }
  paragraphs.add(paragraph);
  return paragraphs.where((text) => text.trim().isNotEmpty).join('\n\n');
}

String _stitchOverlappingText(String left, String right) {
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;

  final leftView = _ComparableOverlapText(left);
  final rightView = _ComparableOverlapText(right);
  final maximum = leftView.normalized.length < rightView.normalized.length
      ? leftView.normalized.length
      : rightView.normalized.length;
  for (var length = maximum.clamp(0, 32).toInt(); length >= 4; length -= 1) {
    if (!_sameRunes(
      leftView.normalized,
      leftView.normalized.length - length,
      rightView.normalized,
      0,
      length,
    )) {
      continue;
    }
    final cut = leftView.sourceIndexForNormalizedSuffix(length);
    final mergedRight = _preserveStableSentencePunctuation(
      leftView: leftView,
      rightView: rightView,
      overlapLength: length,
    );
    return '${String.fromCharCodes(leftView.source.take(cut))}$mergedRight';
  }

  final fuzzy = _findFuzzyOverlap(leftView.normalized, rightView.normalized);
  if (fuzzy != null) {
    final rightRemainder = rightView.sourceIndexAfterNormalizedPrefix(
      fuzzy.rightLength,
    );
    if (rightRemainder >= rightView.source.length) return left;
    return '${_stripTerminalJoinPunctuation(left)}'
        '${String.fromCharCodes(rightView.source.skip(rightRemainder))}';
  }
  return '$left\n\n$right';
}

String _preserveStableSentencePunctuation({
  required _ComparableOverlapText leftView,
  required _ComparableOverlapText rightView,
  required int overlapLength,
}) {
  final leftOverlapStart = leftView.normalized.length - overlapLength;
  final insertions = <_PunctuationInsertion>[];
  for (var boundary = 1; boundary < overlapLength; boundary += 1) {
    // A punctuation mark followed by stable matching context belongs to the
    // sentence, rather than being a forced mark at the edge of a model window.
    if (overlapLength - boundary < 4) continue;
    final leftBoundary = leftView.sourceRunesAtNormalizedBoundary(
      leftOverlapStart + boundary,
    );
    final punctuation = leftBoundary
        .where(_isStrongSentencePunctuation)
        .toList(growable: false);
    if (punctuation.isEmpty) continue;
    final rightBoundary = rightView.sourceRunesAtNormalizedBoundary(boundary);
    if (rightBoundary.any(_isOverlapPunctuation)) continue;
    insertions.add(
      _PunctuationInsertion(
        sourceIndex: rightView.sourceIndexAtNormalizedBoundary(boundary),
        runes: punctuation,
      ),
    );
  }
  if (insertions.isEmpty) return String.fromCharCodes(rightView.source);
  final merged = List<int>.from(rightView.source);
  for (final insertion in insertions.reversed) {
    merged.insertAll(insertion.sourceIndex, insertion.runes);
  }
  return String.fromCharCodes(merged);
}

class _ComparableOverlapText {
  _ComparableOverlapText(String value) : source = value.runes.toList() {
    for (var index = 0; index < source.length; index += 1) {
      final rune = source[index];
      if (_isOverlapIgnorable(rune)) continue;
      normalized.add(rune);
      normalizedSourceIndexes.add(index);
    }
  }

  final List<int> source;
  final List<int> normalized = [];
  final List<int> normalizedSourceIndexes = [];

  int sourceIndexForNormalizedSuffix(int length) =>
      normalizedSourceIndexes[normalized.length - length];

  int sourceIndexAfterNormalizedPrefix(int length) =>
      normalizedSourceIndexes[length - 1] + 1;

  int sourceIndexAtNormalizedBoundary(int boundary) =>
      normalizedSourceIndexes[boundary - 1] + 1;

  Iterable<int> sourceRunesAtNormalizedBoundary(int boundary) sync* {
    if (boundary <= 0 || boundary >= normalized.length) return;
    final start = normalizedSourceIndexes[boundary - 1] + 1;
    final end = normalizedSourceIndexes[boundary];
    for (var index = start; index < end; index += 1) {
      yield source[index];
    }
  }
}

class _PunctuationInsertion {
  const _PunctuationInsertion({required this.sourceIndex, required this.runes});

  final int sourceIndex;
  final List<int> runes;
}

class _FuzzyOverlap {
  const _FuzzyOverlap({
    required this.leftLength,
    required this.rightLength,
    required this.distance,
  });

  final int leftLength;
  final int rightLength;
  final int distance;

  int get score =>
      (leftLength < rightLength ? leftLength : rightLength) * 100 -
      distance * 20 -
      (leftLength - rightLength).abs() * 5;
}

_FuzzyOverlap? _findFuzzyOverlap(List<int> left, List<int> right) {
  final maximumLeft = left.length.clamp(0, 32).toInt();
  final maximumRight = right.length.clamp(0, 32).toInt();
  if (maximumLeft < 4 || maximumRight < 4) return null;
  _FuzzyOverlap? best;
  for (var leftLength = 4; leftLength <= maximumLeft; leftLength += 1) {
    final minimumRight = (leftLength - 2).clamp(4, maximumRight).toInt();
    final candidateMaximumRight = (leftLength + 2)
        .clamp(4, maximumRight)
        .toInt();
    if (minimumRight > candidateMaximumRight) continue;
    final leftStart = left.length - leftLength;
    final leftSlice = left.sublist(leftStart);
    for (
      var rightLength = minimumRight;
      rightLength <= candidateMaximumRight;
      rightLength += 1
    ) {
      final rightSlice = right.take(rightLength).toList(growable: false);
      final distance = _editDistance(leftSlice, rightSlice);
      final longest = leftLength > rightLength ? leftLength : rightLength;
      final allowedDistance = longest >= 10 ? 2 : 1;
      if (distance > allowedDistance || (longest - distance) / longest < 0.8) {
        continue;
      }
      final candidate = _FuzzyOverlap(
        leftLength: leftLength,
        rightLength: rightLength,
        distance: distance,
      );
      if (best == null || candidate.score > best.score) best = candidate;
    }
  }
  return best;
}

int _editDistance(List<int> left, List<int> right) {
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var leftIndex = 0; leftIndex < left.length; leftIndex += 1) {
    final current = List<int>.filled(right.length + 1, 0);
    current[0] = leftIndex + 1;
    for (var rightIndex = 0; rightIndex < right.length; rightIndex += 1) {
      final substitution =
          previous[rightIndex] + (left[leftIndex] == right[rightIndex] ? 0 : 1);
      final insertion = current[rightIndex] + 1;
      final deletion = previous[rightIndex + 1] + 1;
      current[rightIndex + 1] = substitution < insertion
          ? (substitution < deletion ? substitution : deletion)
          : (insertion < deletion ? insertion : deletion);
    }
    previous = current;
  }
  return previous.last;
}

bool _sameRunes(
  List<int> left,
  int leftStart,
  List<int> right,
  int rightStart,
  int length,
) {
  for (var index = 0; index < length; index += 1) {
    if (left[leftStart + index] != right[rightStart + index]) return false;
  }
  return true;
}

bool _isOverlapIgnorable(int rune) => RegExp(
  r'''[\s，。！？；：、,.!?;:…“”‘’"'（）()\[\]【】—-]''',
).hasMatch(String.fromCharCode(rune));

bool _isStrongSentencePunctuation(int rune) =>
    const <int>{0x3002, 0xff01, 0xff1f, 0x2e, 0x21, 0x3f}.contains(rune);

bool _isOverlapPunctuation(int rune) =>
    _isOverlapIgnorable(rune) &&
    !RegExp(r'\s').hasMatch(String.fromCharCode(rune));

String _stripTerminalJoinPunctuation(String value) {
  final runes = value.runes.toList();
  var end = runes.length;
  while (end > 0 && _isOverlapIgnorable(runes[end - 1])) {
    end -= 1;
  }
  return String.fromCharCodes(runes.take(end));
}

Float32List _readPcmRange(List<_WorkerChunk> chunks, _WorkerRange range) {
  final result = Float32List(range.endSample - range.startSample);
  var writeOffset = 0;
  for (final chunk in chunks) {
    final overlapStart = chunk.startSample > range.startSample
        ? chunk.startSample
        : range.startSample;
    final overlapEnd = chunk.endSample < range.endSample
        ? chunk.endSample
        : range.endSample;
    if (overlapEnd <= overlapStart) continue;
    final sampleCount = overlapEnd - overlapStart;
    final fileSampleOffset = overlapStart - chunk.fileStartSample;
    final file = File(chunk.path).openSync();
    try {
      file.setPositionSync(fileSampleOffset * 2);
      final bytes = file.readSync(sampleCount * 2);
      if (bytes.length != sampleCount * 2) {
        throw StateError(l10n.incompletePcmChunk((chunk.path).toString()));
      }
      final data = ByteData.sublistView(bytes);
      for (var index = 0; index < sampleCount; index += 1) {
        result[writeOffset + index] =
            data.getInt16(index * 2, Endian.little) / 32768.0;
      }
      writeOffset += sampleCount;
    } finally {
      file.closeSync();
    }
  }
  if (writeOffset != result.length) {
    throw StateError(
      l10n.audioGapDuringRefinementExpectedGot(
        (result.length).toString(),
        (writeOffset).toString(),
      ),
    );
  }
  return result;
}

String _cleanRecognizedText(String value) => value
    .trim()
    .replaceAll(RegExp(r'\s+([，。！？；：、,.!?;:])'), r'$1')
    .replaceAll(RegExp(r'([，。！？；：、])\s+'), r'$1')
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ');

class _BundledModelFiles {
  const _BundledModelFiles({
    required this.modelId,
    required this.modelPath,
    required this.tokensPath,
  });

  final String modelId;
  final String modelPath;
  final String tokensPath;
}

class _WorkerChunk {
  const _WorkerChunk({
    required this.path,
    required this.startSample,
    required this.endSample,
    required this.fileStartSample,
  });

  factory _WorkerChunk.fromMap(Map<Object?, Object?> map) => _WorkerChunk(
    path: map['path']! as String,
    startSample: map['startSample']! as int,
    endSample: map['endSample']! as int,
    fileStartSample: map['fileStartSample']! as int,
  );

  final String path;
  final int startSample;
  final int endSample;
  final int fileStartSample;
}

class _WorkerRange {
  const _WorkerRange({required this.startSample, required this.endSample});

  factory _WorkerRange.fromMap(Map<Object?, Object?> map) => _WorkerRange(
    startSample: map['startSample']! as int,
    endSample: map['endSample']! as int,
  );

  final int startSample;
  final int endSample;
}

int _messageInteger(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;
