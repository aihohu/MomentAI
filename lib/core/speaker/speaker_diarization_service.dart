import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:momentai/l10n/app_localization.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../domain/audio/committed_audio_chunk.dart';
import '../../domain/speaker/speaker_diarization.dart';
import '../models/local_model_manifest.dart';
import '../models/local_model_runtime.dart';
import 'speaker_diarization_algorithms.dart';

const speakerDiarizationResultFileName = 'speaker_diarization.json';
const speakerDiarizationTaskFileName = 'speaker_diarization_task.json';
const _sampleRate = 16000;
const _windowSamples = 10 * 60 * _sampleRate;
const _windowOverlapSamples = 10 * _sampleRate;
const _maximumEmbeddingSamples = 12 * _sampleRate;
const _minimumEmbeddingSamples = 1200 * 16;
const _profileSpeaker = bool.fromEnvironment('SPEAKER_PROFILE');
const _speakerThreads = int.fromEnvironment('SPEAKER_THREADS');

typedef SpeakerDiarizationWorker =
    Future<Map<String, dynamic>> Function(Map<String, Object?> message);

class SpeakerDiarizationRequest {
  const SpeakerDiarizationRequest({
    required this.sessionId,
    required this.directory,
    this.chunks = const [],
    this.boundarySamples = const [],
    this.loadSource,
    this.forceRebuild = false,
    this.requestedSpeakerCount,
  });

  final String sessionId;
  final String directory;
  final List<CommittedAudioChunk> chunks;
  final List<int> boundarySamples;
  final Future<SpeakerDiarizationSource> Function()? loadSource;
  final bool forceRebuild;
  final int? requestedSpeakerCount;
}

class SpeakerDiarizationSource {
  const SpeakerDiarizationSource({
    required this.chunks,
    this.boundarySamples = const [],
  });
  final List<CommittedAudioChunk> chunks;
  final List<int> boundarySamples;
}

abstract interface class SpeakerDiarizationService {
  ValueListenable<bool> get activity;
  bool get hasActiveJobs;

  bool isProcessing(String directory);

  Future<SpeakerDiarizationSnapshot> snapshot(String directory);

  Future<SpeakerDiarizationDocument> analyze(SpeakerDiarizationRequest request);

  Future<SpeakerDiarizationDocument> editResult(
    String directory, {
    required SpeakerDiarizationDocument expectedDocument,
    required SpeakerEdit edit,
  });

  Future<void> deleteResult(String directory);
}

class SherpaSpeakerDiarizationService implements SpeakerDiarizationService {
  SherpaSpeakerDiarizationService({
    required this.modelResolver,
    this.resourceBusy,
    this.nativeLibraryPath,
    this.worker = _runSpeakerWorkerInIsolate,
  });

  final LocalModelRuntimeResolver modelResolver;
  final bool Function()? resourceBusy;
  final String? nativeLibraryPath;
  final SpeakerDiarizationWorker worker;
  final Map<String, _SpeakerDiarizationJob> _jobs = {};
  final Map<String, Completer<void>> _resultMutations = {};
  final _activity = ValueNotifier(false);

  @override
  ValueListenable<bool> get activity => _activity;

  @override
  bool get hasActiveJobs => _jobs.isNotEmpty || _resultMutations.isNotEmpty;

  @override
  bool isProcessing(String directory) => _jobs.containsKey(directory);

  @override
  Future<SpeakerDiarizationSnapshot> snapshot(String directory) async {
    await _resultMutations[directory]?.future;
    final activeJob = _jobs[directory];
    if (activeJob != null) {
      return SpeakerDiarizationSnapshot.processing(
        requestedSpeakerCount: activeJob.requestedSpeakerCount,
        document: activeJob.document,
        message: activeJob.progressMessage,
      );
    }
    return _persistedSnapshot(directory);
  }

  Future<SpeakerDiarizationSnapshot> _persistedSnapshot(
    String directory,
  ) async {
    final result = await _readResultSnapshot(directory);
    final taskFile = File('$directory/$speakerDiarizationTaskFileName');
    await _recoverAtomicFile(taskFile);
    if (!await taskFile.exists()) return result;
    final task =
        jsonDecode(await taskFile.readAsString()) as Map<String, dynamic>;
    // A crash after the atomic result commit must not hide a finished result.
    final resultFile = File('$directory/$speakerDiarizationResultFileName');
    if (await resultFile.exists()) {
      final saved =
          jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
      if (task['runId'] != null && saved['analysisRunId'] == task['runId']) {
        // Clear the stale marker before later label edits replace result metadata.
        try {
          await taskFile.delete();
        } on FileSystemException {
          /* already reconciled */
        }
        return result;
      }
    }
    return SpeakerDiarizationSnapshot(
      status: SpeakerDiarizationStatus.failed,
      document: result.document,
      requestedSpeakerCount: task['requestedSpeakerCount'] as int?,
      message: task['status'] == 'failed'
          ? task['message'] as String?
          : l10n.speakerAnalysisInterrupted,
    );
  }

  Future<SpeakerDiarizationSnapshot> _readResultSnapshot(
    String directory,
  ) async {
    final file = File('$directory/$speakerDiarizationResultFileName');
    await _recoverAtomicFile(file);
    if (!await file.exists()) {
      final model = await modelResolver.speakerDiarizationModelFiles();
      return SpeakerDiarizationSnapshot.unavailable(
        message: model == null
            ? l10n.installTheSpeakerAnalysisModelInModel
            : null,
      );
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schemaVersion'] != 1) {
        throw const FormatException('Unsupported speaker result.');
      }
      if (decoded['status'] == 'ready') {
        final document = SpeakerDiarizationDocument.fromMap(decoded);
        _validateDocument(document);
        return SpeakerDiarizationSnapshot(
          status: SpeakerDiarizationStatus.ready,
          document: document,
          requestedSpeakerCount: document.requestedSpeakerCount,
        );
      }
      if (decoded['status'] == 'failed') {
        return SpeakerDiarizationSnapshot(
          status: SpeakerDiarizationStatus.failed,
          message: decoded['message']?.toString() ?? l10n.speakerAnalysisFailed,
          requestedSpeakerCount: _positiveInteger(
            decoded['requestedSpeakerCount'],
          ),
        );
      }
      return const SpeakerDiarizationSnapshot.unavailable();
    } catch (error) {
      return SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.failed,
        message: l10n.couldNotReadSpeakerAnalysisResults((error).toString()),
      );
    }
  }

  @override
  Future<SpeakerDiarizationDocument> analyze(
    SpeakerDiarizationRequest request,
  ) {
    final existing = _jobs[request.directory];
    if (existing != null) return existing.future;
    if (hasActiveJobs) {
      return Future.error(
        StateError(l10n.anotherRecordingIsBeingAnalyzedTryAgain),
      );
    }
    if (resourceBusy?.call() == true) {
      return Future.error(StateError(l10n.recordingOrAnotherLocalModelTaskIs));
    }
    late final Future<SpeakerDiarizationDocument> job;
    late final _SpeakerDiarizationJob jobState;
    job = Future(() => _analyzeOnce(request)).whenComplete(() {
      if (identical(_jobs[request.directory], jobState)) {
        _jobs.remove(request.directory);
        _activity.value = hasActiveJobs;
      }
    });
    jobState = _SpeakerDiarizationJob(
      future: job,
      requestedSpeakerCount: request.requestedSpeakerCount,
    );
    _jobs[request.directory] = jobState;
    _activity.value = true;
    return job;
  }

  Future<SpeakerDiarizationDocument> _analyzeOnce(
    SpeakerDiarizationRequest request,
  ) async {
    if (request.sessionId.isEmpty || request.directory.isEmpty) {
      throw ArgumentError('Session id and directory are required.');
    }
    final requestedSpeakerCount = request.requestedSpeakerCount;
    if (requestedSpeakerCount != null &&
        (requestedSpeakerCount < 1 ||
            requestedSpeakerCount > maximumRequestedSpeakerCount)) {
      throw ArgumentError(
        l10n.theSpeakerCountMustBeBetweenAnd(
          (maximumRequestedSpeakerCount).toString(),
        ),
      );
    }
    if (resourceBusy?.call() == true) {
      throw StateError(l10n.recordingOrAnotherLocalModelTaskIs);
    }
    final source =
        await request.loadSource?.call() ??
        SpeakerDiarizationSource(
          chunks: request.chunks,
          boundarySamples: request.boundarySamples,
        );
    if (source.chunks.isEmpty) {
      throw StateError(l10n.noSavedAudioIsAvailableForSpeaker);
    }
    final chunks = source.chunks.toList(growable: false)
      ..sort((left, right) => left.startSample.compareTo(right.startSample));
    if (chunks.any((chunk) => chunk.sampleRate != _sampleRate)) {
      throw StateError(l10n.speakerAnalysisCurrentlyRequiresSavedAudioAt);
    }
    final sourceAudioSamples = chunks
        .map((chunk) => chunk.endSample)
        .reduce(math.max);
    final boundaries =
        source.boundarySamples
            .where((sample) => sample > 0 && sample < sourceAudioSamples)
            .toSet()
            .toList()
          ..sort();
    final fingerprint = sourceChunkFingerprint(
      chunks,
      boundarySamples: boundaries,
    );
    final persisted = await _persistedSnapshot(request.directory);
    final persistedDocument = persisted.document;
    _jobs[request.directory]?.document = persistedDocument;
    if (!request.forceRebuild &&
        persisted.status == SpeakerDiarizationStatus.ready &&
        persistedDocument != null &&
        persistedDocument.algorithmVersion ==
            speakerDiarizationAlgorithmVersion &&
        persistedDocument.sessionId == request.sessionId &&
        persistedDocument.modelId == speakerDiarizationModelId &&
        persistedDocument.sourceAudioSamples == sourceAudioSamples &&
        persistedDocument.sourceChunkFingerprint == fingerprint &&
        persistedDocument.requestedSpeakerCount == requestedSpeakerCount) {
      return persistedDocument;
    }

    final modelFiles = await modelResolver.speakerDiarizationModelFiles();
    if (modelFiles == null) {
      throw StateError(l10n.installTheSpeakerAnalysisModelInModel);
    }
    final message = <String, Object?>{
      'sessionId': request.sessionId,
      'modelId': modelFiles.modelId,
      'segmentationPath': modelFiles.segmentationPath,
      'embeddingPath': modelFiles.embeddingPath,
      'nativeLibraryPath': nativeLibraryPath,
      'sourceAudioSamples': sourceAudioSamples,
      'sourceChunkFingerprint': fingerprint,
      'requestedSpeakerCount': requestedSpeakerCount,
      'chunks': chunks.map((chunk) => chunk.toMessage()).toList(),
      'boundarySamples': boundaries,
    };
    final file = File('${request.directory}/$speakerDiarizationResultFileName');
    final taskFile = File(
      '${request.directory}/$speakerDiarizationTaskFileName',
    );
    final runId = DateTime.now().microsecondsSinceEpoch.toString();
    final task = <String, Object?>{
      'schemaVersion': 1,
      'runId': runId,
      'status': 'running',
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'requestedSpeakerCount': requestedSpeakerCount,
    };
    await _writeAtomically(taskFile, task);
    final progress = ReceivePort();
    final subscription = progress.listen((value) {
      if (value is Map) _jobs[request.directory]?.updateProgress(value);
    });
    message['progressPort'] = progress.sendPort;
    try {
      final result = await worker(message);
      final document = SpeakerDiarizationDocument.fromMap(result);
      _validateDocument(document);
      await _writeAtomically(file, {
        ...document.toMap(),
        'analysisRunId': runId,
      });
      // The run id also reconciles a crash between these two operations.
      try {
        await taskFile.delete();
      } on FileSystemException {
        /* result committed */
      }
      return document;
    } catch (error) {
      await _writeAtomically(taskFile, {
        ...task,
        'status': 'failed',
        'message': '$error',
      });
      if (persistedDocument == null) {
        await _writeAtomically(file, {
          'schemaVersion': 1,
          'status': 'failed',
          'sessionId': request.sessionId,
          'modelId': modelFiles.modelId,
          'sourceAudioSamples': sourceAudioSamples,
          'sourceChunkFingerprint': fingerprint,
          'requestedSpeakerCount': requestedSpeakerCount,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'message': '$error',
        });
      }
      rethrow;
    } finally {
      await subscription.cancel();
      progress.close();
    }
  }

  @override
  Future<SpeakerDiarizationDocument> editResult(
    String directory, {
    required SpeakerDiarizationDocument expectedDocument,
    required SpeakerEdit edit,
  }) async {
    final gate = _beginResultMutation(directory);
    try {
      final current = (await _persistedSnapshot(directory)).document;
      if (current == null) {
        throw StateError(l10n.noSpeakerResultsAreAvailableToEdit);
      }
      if (jsonEncode(current.toMap()) != jsonEncode(expectedDocument.toMap())) {
        throw StateError(l10n.speakerResultsHaveChangedReopenThemBefore);
      }
      final updated = current.applyEdit(edit);
      _validateDocument(updated);
      if (!identical(updated, current)) {
        await _writeAtomically(
          File('$directory/$speakerDiarizationResultFileName'),
          updated.toMap(),
        );
      }
      return updated;
    } finally {
      _endResultMutation(directory, gate);
    }
  }

  Completer<void> _beginResultMutation(String directory) {
    if (directory.isEmpty) {
      throw ArgumentError('Session directory is required.');
    }
    if (hasActiveJobs) {
      throw StateError(l10n.speakerResultsAreBeingProcessedWaitBefore);
    }
    final gate = Completer<void>();
    _resultMutations[directory] = gate;
    _activity.value = true;
    return gate;
  }

  void _endResultMutation(String directory, Completer<void> gate) {
    _resultMutations.remove(directory);
    gate.complete();
    _activity.value = hasActiveJobs;
  }

  @override
  Future<void> deleteResult(String directory) async {
    final gate = _beginResultMutation(directory);
    try {
      final file = File('$directory/$speakerDiarizationResultFileName');
      if (await file.exists()) await file.delete();
      final temporary = File('${file.path}.part');
      if (await temporary.exists()) await temporary.delete();
      final backup = File('${file.path}.backup');
      if (await backup.exists()) await backup.delete();
      for (final suffix in ['', '.part', '.backup']) {
        final task = File('$directory/$speakerDiarizationTaskFileName$suffix');
        if (await task.exists()) await task.delete();
      }
    } finally {
      _endResultMutation(directory, gate);
    }
  }
}

void _validateDocument(SpeakerDiarizationDocument document) {
  document.validateSpeakerLabels();
  if (document.sessionId.isEmpty ||
      document.modelId.isEmpty ||
      document.sampleRate != _sampleRate ||
      document.sourceAudioSamples <= 0 ||
      !document.sourceChunkFingerprint.startsWith('sha256:') ||
      (document.requestedSpeakerCount != null &&
          (document.requestedSpeakerCount! < 1 ||
              document.requestedSpeakerCount! >
                  maximumRequestedSpeakerCount))) {
    throw const FormatException('Invalid speaker result identity.');
  }
  final speakerPattern = RegExp(r'^speaker_[1-9]\d*$');
  for (final segment in document.segments) {
    if (!speakerPattern.hasMatch(segment.speakerId) ||
        segment.startSample < 0 ||
        segment.endSample > document.sourceAudioSamples ||
        segment.endSample <= segment.startSample) {
      throw const FormatException('Invalid speaker result segment.');
    }
  }
}

String sourceChunkFingerprint(
  Iterable<CommittedAudioChunk> chunks, {
  Iterable<int> boundarySamples = const [],
}) {
  final ordered = chunks.toList(growable: false)
    ..sort((left, right) => left.index.compareTo(right.index));
  final canonical = ordered
      .map(
        (chunk) => {
          'index': chunk.index,
          'path': chunk.path,
          'startSample': chunk.startSample,
          'endSample': chunk.endSample,
          'fileStartSample': chunk.fileStartSample,
          'sampleRate': chunk.sampleRate,
        },
      )
      .toList(growable: false);
  final boundaries = boundarySamples.toSet().toList()..sort();
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode({'chunks': canonical, 'boundaries': boundaries})))}';
}

class SpeakerDiarizationWindow {
  const SpeakerDiarizationWindow({
    required this.startSample,
    required this.endSample,
    required this.trustedStartSample,
    required this.trustedEndSample,
    required this.islandIndex,
  });

  final int startSample;
  final int endSample;
  final int trustedStartSample;
  final int trustedEndSample;
  final int islandIndex;
}

List<SpeakerDiarizationWindow> planSpeakerDiarizationWindows(
  Iterable<CommittedAudioChunk> input, {
  Iterable<int> boundarySamples = const [],
  int maximumWindowSamples = _windowSamples,
  int overlapSamples = _windowOverlapSamples,
}) {
  if (maximumWindowSamples <= 0 ||
      overlapSamples < 0 ||
      overlapSamples >= maximumWindowSamples) {
    throw ArgumentError('Invalid diarization window sizes');
  }
  final chunks = input.toList(growable: false)
    ..sort((left, right) => left.startSample.compareTo(right.startSample));
  if (chunks.isEmpty) return const [];
  final islands = <_SampleRange>[];
  var start = chunks.first.startSample;
  var end = chunks.first.endSample;
  for (final chunk in chunks.skip(1)) {
    if (chunk.startSample > end) {
      islands.add(_SampleRange(start, end));
      start = chunk.startSample;
      end = chunk.endSample;
    } else if (chunk.endSample > end) {
      end = chunk.endSample;
    }
  }
  islands.add(_SampleRange(start, end));

  final boundaries = boundarySamples.toSet().toList()..sort();
  final splitIslands = <_SampleRange>[];
  for (final island in islands) {
    var cursor = island.start;
    for (final boundary in boundaries) {
      if (boundary <= cursor || boundary >= island.end) continue;
      splitIslands.add(_SampleRange(cursor, boundary));
      cursor = boundary;
    }
    splitIslands.add(_SampleRange(cursor, island.end));
  }
  final result = <SpeakerDiarizationWindow>[];
  for (var islandIndex = 0; islandIndex < splitIslands.length; islandIndex++) {
    final island = splitIslands[islandIndex];
    final raw = <_SampleRange>[];
    var cursor = island.start;
    while (cursor < island.end) {
      final windowEnd = math.min(cursor + maximumWindowSamples, island.end);
      raw.add(_SampleRange(cursor, windowEnd));
      if (windowEnd == island.end) break;
      cursor = windowEnd - overlapSamples;
    }
    for (var index = 0; index < raw.length; index += 1) {
      final window = raw[index];
      final trustedStart = index == 0
          ? window.start
          : (raw[index - 1].end + window.start) ~/ 2;
      final trustedEnd = index + 1 == raw.length
          ? window.end
          : (window.end + raw[index + 1].start) ~/ 2;
      result.add(
        SpeakerDiarizationWindow(
          startSample: window.start,
          endSample: window.end,
          trustedStartSample: trustedStart,
          trustedEndSample: trustedEnd,
          islandIndex: islandIndex,
        ),
      );
    }
  }
  return result;
}

Future<Map<String, dynamic>> _runSpeakerWorkerInIsolate(
  Map<String, Object?> message,
) {
  final language = applicationLocale.languageCode;
  return Isolate.run(() {
    setApplicationLanguage(language);
    return _runSpeakerWorker(message);
  });
}

/// A single window contains all committed speech, so the Session count belongs
/// in native clustering, before local turns lose their distinct embeddings.
/// Multiple windows/islands may contain only a subset of the participants.
int speakerWindowClusterCount({
  required List<SpeakerDiarizationWindow> windows,
  required int? requestedSpeakerCount,
}) => windows.length == 1 ? requestedSpeakerCount ?? -1 : -1;

Map<String, dynamic> _runSpeakerWorker(Map<String, Object?> message) {
  final fast =
      Platform.isAndroid || const bool.fromEnvironment('SPEAKER_FAST_WINDOWS');
  final total = Stopwatch()..start();
  final candidate = _runSpeakerWorkerPass(message, fastWindows: fast);
  if (candidate.remove('_requiresFullPass') != true) return candidate;
  if (_profileSpeaker) {
    debugPrint(
      'SPEAKER_PROFILE uncertain fast pass; using full-window fallback',
    );
  }
  final result = _runSpeakerWorkerPass(message, fastWindows: false)
    ..remove('_requiresFullPass');
  result['processingMs'] = total.elapsedMilliseconds;
  result['realTimeFactor'] =
      total.elapsedMilliseconds * 16 / (message['sourceAudioSamples']! as int);
  result['peakRssBytes'] = math.max(
    result['peakRssBytes'] as int,
    candidate['peakRssBytes'] as int,
  );
  return result;
}

Map<String, dynamic> _runSpeakerWorkerPass(
  Map<String, Object?> message, {
  required bool fastWindows,
}) {
  final watch = Stopwatch()..start();
  final threads = _speakerThreads > 0 ? _speakerThreads : 2;
  sherpa.initBindings(message['nativeLibraryPath'] as String?);
  final requestedSpeakerCount = message['requestedSpeakerCount'] as int?;
  final chunks = (message['chunks']! as List<Object?>)
      .map(
        (item) =>
            _WorkerChunk.fromMap(Map<Object?, Object?>.from(item! as Map)),
      )
      .toList(growable: false);
  final publicChunks = chunks
      .map(
        (chunk) => CommittedAudioChunk(
          sessionId: message['sessionId']! as String,
          directory: '',
          index: chunk.index,
          path: chunk.path,
          startSample: chunk.startSample,
          endSample: chunk.endSample,
          sampleRate: _sampleRate,
          fileStartSample: chunk.fileStartSample,
        ),
      )
      .toList(growable: false);
  final windows = planSpeakerDiarizationWindows(
    publicChunks,
    maximumWindowSamples: fastWindows ? 10 * _sampleRate : _windowSamples,
    overlapSamples: fastWindows ? 2 * _sampleRate : _windowOverlapSamples,
    boundarySamples: (message['boundarySamples'] as List<Object?>? ?? const [])
        .cast<int>(),
  );
  final nativeCount = speakerWindowClusterCount(
    windows: windows,
    requestedSpeakerCount: requestedSpeakerCount,
  );
  final finalizedLocally = nativeCount > 0;
  final diarizer = sherpa.OfflineSpeakerDiarization(
    sherpa.OfflineSpeakerDiarizationConfig(
      segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
        pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
          model: message['segmentationPath']! as String,
        ),
        numThreads: threads,
        debug: _profileSpeaker,
      ),
      embedding: sherpa.SpeakerEmbeddingExtractorConfig(
        model: message['embeddingPath']! as String,
        numThreads: threads,
        debug: false,
      ),
      clustering: sherpa.FastClusteringConfig(
        numClusters: nativeCount,
        threshold: 0.9,
      ),
      minDurationOn: 0.3,
      minDurationOff: 0.5,
    ),
  );
  sherpa.SpeakerEmbeddingExtractor? extractor;
  final profiles = <_SpeakerProfile>[];
  final result = <SpeakerDiarizationTurn>[];
  var peakRssBytes = ProcessInfo.currentRss;
  var requiresFullPass = false;
  try {
    for (var windowIndex = 0; windowIndex < windows.length; windowIndex++) {
      final window = windows[windowIndex];
      final port = message['progressPort'] as SendPort?;
      void report(String stage, [int processed = 0, int total = 0]) =>
          port?.send({
            'window': windowIndex + 1,
            'windows': windows.length,
            'stage': stage,
            'processed': processed,
            'total': total,
          });
      report('inference');
      final samples = _readPcmRange(
        chunks,
        window.startSample,
        window.endSample,
      );
      final nativeWatch = Stopwatch()..start();
      final localSegments = diarizer.processWithCallback(
        samples: samples,
        callback: (processed, total) {
          report('inference', processed, total);
          return 0;
        },
      );
      report('alignment');
      if (_profileSpeaker) {
        debugPrint(
          'SPEAKER_PROFILE nativeMs=${nativeWatch.elapsedMilliseconds}',
        );
      }
      final localIds =
          localSegments
              .where(
                (segment) =>
                    window.startSample + (segment.start * _sampleRate).round() <
                        window.trustedEndSample &&
                    window.startSample + (segment.end * _sampleRate).round() >
                        window.trustedStartSample,
              )
              .map((segment) => segment.speaker)
              .toSet()
              .toList(growable: false)
            ..sort((left, right) {
              double firstStart(int speaker) => localSegments
                  .where((segment) => segment.speaker == speaker)
                  .map((segment) => segment.start)
                  .fold(double.infinity, math.min);
              return firstStart(left).compareTo(firstStart(right));
            });
      final embeddings = <int, Float32List>{};
      final embeddingWatch = Stopwatch()..start();
      // Do not keep a second embedding session/thread pool alive during native
      // segmentation. It is needed only to reconcile identities after inference.
      if (!finalizedLocally && localIds.isNotEmpty) {
        extractor = sherpa.SpeakerEmbeddingExtractor(
          config: sherpa.SpeakerEmbeddingExtractorConfig(
            model: message['embeddingPath']! as String,
            numThreads: threads,
            debug: false,
          ),
        );
      }
      for (final localId in finalizedLocally ? const <int>[] : localIds) {
        final embedding = _embeddingForLocalSpeaker(
          extractor!,
          samples,
          localSegments.where((segment) => segment.speaker == localId),
        );
        if (embedding != null) embeddings[localId] = embedding;
      }
      extractor?.free();
      extractor = null;
      if (fastWindows && !finalizedLocally) {
        final centroids = profiles.map((p) => p.centroid).toList();
        requiresFullPass = speakerFastPassNeedsFallback(
          localIds: localIds,
          embeddings: embeddings,
          profiles: centroids,
          profileGroups: consolidateAutomaticSpeakers(centroids, turns: result),
          speechSeconds: {
            for (final id in localIds)
              id: localSegments
                  .where((s) => s.speaker == id)
                  .fold<double>(0, (n, s) => n + s.end - s.start),
          },
        );
      }
      if (_profileSpeaker) {
        debugPrint(
          'SPEAKER_PROFILE embeddingMs=${embeddingWatch.elapsedMilliseconds}',
        );
        for (var i = 0; i < localIds.length; i++) {
          for (var j = i + 1; j < localIds.length; j++) {
            final a = embeddings[localIds[i]], b = embeddings[localIds[j]];
            if (a != null && b != null) {
              debugPrint(
                'SPEAKER_PROFILE similarity $i/$j=${speakerCosine(a, b)}',
              );
            }
          }
        }
      }
      final mapping = finalizedLocally
          ? {for (var i = 0; i < localIds.length; i++) localIds[i]: i}
          : _assignGlobalSpeakers(
              localIds,
              embeddings,
              profiles,
              matchExisting: requestedSpeakerCount == null,
            );
      for (final segment in localSegments) {
        final absoluteStart =
            window.startSample + (segment.start * _sampleRate).round();
        final absoluteEnd =
            window.startSample + (segment.end * _sampleRate).round();
        final clippedStart = math.max(absoluteStart, window.trustedStartSample);
        final clippedEnd = math.min(absoluteEnd, window.trustedEndSample);
        if (clippedEnd <= clippedStart) continue;
        result.add(
          SpeakerDiarizationTurn(
            speakerIndex: mapping[segment.speaker]!,
            islandIndex: window.islandIndex,
            startSample: clippedStart,
            endSample: clippedEnd,
          ),
        );
      }
      peakRssBytes = math.max(peakRssBytes, ProcessInfo.currentRss);
      // Stop the speculative pass as soon as quality cannot be established.
      // No partial labels are persisted; the caller reruns the original pipeline.
      if (requiresFullPass) break;
    }
  } finally {
    extractor?.free();
    diarizer.free();
  }
  (message['progressPort'] as SendPort?)?.send({'stage': 'finalizing'});
  final assignment = finalizedLocally
      ? const <int>[]
      : requestedSpeakerCount == null
      ? consolidateAutomaticSpeakers(
          profiles.map((profile) => profile.centroid).toList(),
          turns: result,
        )
      : clusterSessionSpeakers(
          profiles.map((profile) => profile.centroid).toList(),
          requestedSpeakerCount: requestedSpeakerCount,
        );
  final merged = canonicalizeSpeakerTurns(
    result.map(
      (turn) => SpeakerDiarizationTurn(
        speakerIndex: finalizedLocally
            ? turn.speakerIndex
            : assignment[turn.speakerIndex],
        startSample: turn.startSample,
        endSample: turn.endSample,
        islandIndex: turn.islandIndex,
      ),
    ),
  );
  watch.stop();
  final durationSeconds = (message['sourceAudioSamples']! as int) / _sampleRate;
  return <String, dynamic>{
    '_requiresFullPass': requiresFullPass,
    'schemaVersion': 1,
    'algorithmVersion': speakerDiarizationAlgorithmVersion,
    'status': 'ready',
    'sessionId': message['sessionId']! as String,
    'modelId': message['modelId']! as String,
    'sourceAudioSamples': message['sourceAudioSamples']! as int,
    'sampleRate': _sampleRate,
    'sourceChunkFingerprint': message['sourceChunkFingerprint']! as String,
    'requestedSpeakerCount': requestedSpeakerCount,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'processingMs': watch.elapsedMilliseconds,
    'realTimeFactor': durationSeconds <= 0
        ? 0
        : watch.elapsedMilliseconds / 1000 / durationSeconds,
    'peakRssBytes': peakRssBytes,
    'windowCount': windows.length,
    'segments': merged.map((segment) => segment.toMap()).toList(),
  };
}

Float32List? _embeddingForLocalSpeaker(
  sherpa.SpeakerEmbeddingExtractor extractor,
  Float32List samples,
  Iterable<sherpa.OfflineSpeakerDiarizationSegment> input,
) {
  final segments = input.toList(growable: false)
    ..sort(
      (left, right) =>
          (right.end - right.start).compareTo(left.end - left.start),
    );
  final selected = <Float32List>[];
  var total = 0;
  for (final segment in segments) {
    if (total >= _maximumEmbeddingSamples) break;
    final start = (segment.start * _sampleRate).round().clamp(
      0,
      samples.length,
    );
    final end = (segment.end * _sampleRate).round().clamp(
      start,
      samples.length,
    );
    final count = math.min(end - start, _maximumEmbeddingSamples - total);
    if (count <= 0) continue;
    selected.add(Float32List.sublistView(samples, start, start + count));
    total += count;
  }
  if (total < _minimumEmbeddingSamples) return null;
  final waveform = Float32List(total);
  var offset = 0;
  for (final slice in selected) {
    waveform.setRange(offset, offset + slice.length, slice);
    offset += slice.length;
  }
  final stream = extractor.createStream();
  try {
    stream.acceptWaveform(samples: waveform, sampleRate: _sampleRate);
    stream.inputFinished();
    if (!extractor.isReady(stream)) return null;
    final embedding = extractor.compute(stream);
    return embedding.isEmpty ? null : _normalize(embedding);
  } finally {
    stream.free();
  }
}

Map<int, int> _assignGlobalSpeakers(
  List<int> localIds,
  Map<int, Float32List> embeddings,
  List<_SpeakerProfile> profiles, {
  required bool matchExisting,
}) {
  final result = matchExisting
      ? matchSpeakerEmbeddings(
          embeddings,
          profiles.map((profile) => profile.centroid).toList(),
        )
      : <int, int>{};
  for (final localId in localIds) {
    final embedding = embeddings[localId];
    final existing = result[localId];
    if (existing != null) {
      if (embedding != null) profiles[existing].add(embedding);
    } else {
      result[localId] = profiles.length;
      profiles.add(
        _SpeakerProfile(
          embedding ?? Float32List(0),
          hasEmbedding: embedding != null,
        ),
      );
    }
  }
  return result;
}

int? _positiveInteger(Object? value) {
  final parsed = value is num ? value.round() : int.tryParse('$value');
  return parsed != null && parsed > 0 ? parsed : null;
}

Float32List _readPcmRange(
  List<_WorkerChunk> chunks,
  int startSample,
  int endSample,
) {
  final result = Float32List(endSample - startSample);
  var writeOffset = 0;
  for (final chunk in chunks) {
    final overlapStart = math.max(chunk.startSample, startSample);
    final overlapEnd = math.min(chunk.endSample, endSample);
    if (overlapEnd <= overlapStart) continue;
    final sampleCount = overlapEnd - overlapStart;
    final fileSampleOffset = overlapStart - chunk.fileStartSample;
    final file = File(chunk.path).openSync();
    try {
      file.setPositionSync(fileSampleOffset * 2);
      final bytes = file.readSync(sampleCount * 2);
      if (bytes.length != sampleCount * 2) {
        throw StateError(
          l10n.incompletePcmDataForSpeakerAnalysis((chunk.path).toString()),
        );
      }
      final data = ByteData.sublistView(bytes);
      for (var index = 0; index < sampleCount; index++) {
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
      l10n.audioGapInSpeakerAnalysisExpectedGot(
        (result.length).toString(),
        (writeOffset).toString(),
      ),
    );
  }
  return result;
}

Float32List _normalize(Float32List value) {
  var squared = 0.0;
  for (final item in value) {
    squared += item * item;
  }
  final norm = math.sqrt(squared);
  if (norm == 0) return value;
  final result = Float32List(value.length);
  for (var index = 0; index < value.length; index++) {
    result[index] = value[index] / norm;
  }
  return result;
}

Future<void> _writeAtomically(
  File destination,
  Map<String, Object?> payload,
) async {
  final temporary = File('${destination.path}.part');
  final backup = File('${destination.path}.backup');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
    flush: true,
  );
  if (await backup.exists()) await backup.delete();
  if (await destination.exists()) {
    await destination.rename(backup.path);
  }
  try {
    await temporary.rename(destination.path);
    if (await backup.exists()) await backup.delete();
  } catch (_) {
    if (!await destination.exists() && await backup.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  }
}

Future<void> _recoverAtomicFile(File destination) async {
  final backup = File('${destination.path}.backup');
  if (await destination.exists()) {
    if (await backup.exists()) await backup.delete();
    return;
  }
  if (await backup.exists()) await backup.rename(destination.path);
}

class _SampleRange {
  const _SampleRange(this.start, this.end);

  final int start;
  final int end;
}

class _WorkerChunk {
  const _WorkerChunk({
    required this.index,
    required this.path,
    required this.startSample,
    required this.endSample,
    required this.fileStartSample,
  });

  factory _WorkerChunk.fromMap(Map<Object?, Object?> map) => _WorkerChunk(
    index: map['index']! as int,
    path: map['path']! as String,
    startSample: map['startSample']! as int,
    endSample: map['endSample']! as int,
    fileStartSample: map['fileStartSample']! as int,
  );

  final int index;
  final String path;
  final int startSample;
  final int endSample;
  final int fileStartSample;
}

class _SpeakerDiarizationJob {
  _SpeakerDiarizationJob({
    required this.future,
    required this.requestedSpeakerCount,
  });

  final Future<SpeakerDiarizationDocument> future;
  SpeakerDiarizationDocument? document;
  final int? requestedSpeakerCount;
  final startedAt = DateTime.now();
  int window = 0;
  int windows = 0;
  int processed = 0;
  int total = 0;
  String stage = 'preparing';

  void updateProgress(Map value) {
    stage = value['stage'] as String? ?? stage;
    window = value['window'] as int? ?? window;
    windows = value['windows'] as int? ?? windows;
    processed = value['processed'] as int? ?? 0;
    total = value['total'] as int? ?? 0;
  }

  String get progressMessage {
    final elapsed = DateTime.now().difference(startedAt);
    final time =
        '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    if (stage == 'finalizing') return l10n.speakerAnalysisFinalizing(time);
    if (windows == 0) return l10n.speakerAnalysisPreparing(time);
    final detail = stage == 'alignment' || total > 0 && processed >= total
        ? l10n.speakerAnalysisAligning
        : total <= 0
        ? l10n.speakerAnalysisComputing
        : '${(100 * processed / total).floor().clamp(0, 99)}%';
    return l10n.speakerAnalysisProgress('$window', '$windows', detail, time);
  }
}

class _SpeakerProfile {
  _SpeakerProfile(Float32List embedding, {required this.hasEmbedding})
    : centroid = embedding;

  Float32List centroid;
  bool hasEmbedding;
  int count = 1;

  void add(Float32List embedding) {
    if (!hasEmbedding || centroid.length != embedding.length) {
      centroid = embedding;
      hasEmbedding = true;
      count = 1;
      return;
    }
    final combined = Float32List(centroid.length);
    for (var index = 0; index < centroid.length; index++) {
      combined[index] =
          (centroid[index] * count + embedding[index]) / (count + 1);
    }
    centroid = _normalize(combined);
    count += 1;
  }
}
