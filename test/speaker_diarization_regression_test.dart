import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/models/local_model_manifest.dart';
import 'package:momentai/core/models/local_model_runtime.dart';
import 'package:momentai/core/session/session_experience_gateway.dart';
import 'package:momentai/core/speaker/speaker_diarization_algorithms.dart';
import 'package:momentai/core/speaker/speaker_diarization_service.dart';
import 'package:momentai/domain/audio/committed_audio_chunk.dart';
import 'package:momentai/domain/session/session_summary.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/poc/poc_bridge.dart';
import 'package:momentai/product/session_detail_controller.dart';

void main() {
  test('fast quality guard counts duplicate profiles as one identity', () {
    expect(
      speakerFastPassNeedsFallback(
        localIds: [0],
        embeddings: {
          0: _embedding([1, 0]),
        },
        profiles: [
          _embedding([.99, .1]),
          _embedding([.98, .2]),
          _embedding([0, 1]),
        ],
        profileGroups: [0, 0, 2],
        speechSeconds: {0: 8},
      ),
      isFalse,
    );
    expect(
      speakerFastPassNeedsFallback(
        localIds: [0],
        embeddings: {
          0: _embedding([1, 0]),
        },
        profiles: [
          _embedding([.99, .1]),
          _embedding([.98, .2]),
        ],
        profileGroups: [0, 1],
        speechSeconds: {0: 8},
      ),
      isTrue,
    );
    expect(
      speakerFastPassNeedsFallback(
        localIds: [0],
        embeddings: {},
        profiles: [],
        profileGroups: [],
        speechSeconds: {0: .4},
      ),
      isTrue,
    );
  });
  test('fast windows preserve every sample and never span an interruption', () {
    final chunks = [
      CommittedAudioChunk(
        sessionId: 's',
        directory: '/tmp',
        index: 0,
        path: '/tmp/a.pcm',
        startSample: 0,
        endSample: 346200 * 16,
        sampleRate: 16000,
      ),
    ];
    final windows = planSpeakerDiarizationWindows(
      chunks,
      maximumWindowSamples: 160000,
      overlapSamples: 32000,
      boundarySamples: [123456],
    );
    var previous = 0;
    for (final w in windows) {
      expect(w.endSample - w.startSample, lessThanOrEqualTo(160000));
      expect(w.trustedStartSample, previous);
      expect(w.startSample < 123456 && w.endSample > 123456, isFalse);
      previous = w.trustedEndSample;
    }
    expect(previous, chunks.last.endSample);
    expect(
      () => planSpeakerDiarizationWindows(
        chunks,
        maximumWindowSamples: 10,
        overlapSamples: 10,
      ),
      throwsArgumentError,
    );
  });
  test(
    'brief mixed voice rejoins a clear stable speaker and preserves overlap',
    () {
      final turns = [
        _turn(0, 0, 16000 * 80),
        _turn(1, 16000 * 100, 16000 * 180),
        _turn(2, 16000 * 50, 16000 * 54),
      ];
      final groups = consolidateAutomaticSpeakers([
        _embedding([1, 0, 0]),
        _embedding([0, 1, 0]),
        _embedding([0, .65, math.sqrt(1 - .65 * .65)]),
      ], turns: turns);
      expect(groups[2], groups[1]);
      expect(groups[0], isNot(groups[1]));
      final result = canonicalizeSpeakerTurns(
        turns.map(
          (t) => SpeakerDiarizationTurn(
            speakerIndex: groups[t.speakerIndex],
            startSample: t.startSample,
            endSample: t.endSample,
            islandIndex: t.islandIndex,
          ),
        ),
      );
      expect(
        result.any(
          (t) => t.startSample == 50 * 16000 && t.endSample == 54 * 16000,
        ),
        isTrue,
      );
    },
  );
  test('a real brief third voice is not removed just because it is short', () {
    final groups = consolidateAutomaticSpeakers(
      [
        _embedding([1, 0, 0]),
        _embedding([0, 1, 0]),
        _embedding([.2, .3, .93]),
      ],
      turns: [
        _turn(0, 0, 16000 * 80),
        _turn(1, 16000 * 100, 16000 * 180),
        _turn(2, 16000 * 90, 16000 * 94),
      ],
    );
    expect(groups.toSet(), hasLength(3));
  });
  test('brief ambiguous or simultaneously active labels stay separate', () {
    for (final overlap in [false, true]) {
      final groups = consolidateAutomaticSpeakers(
        [
          _embedding([1, 0, 0]),
          _embedding([0, 1, 0]),
          overlap ? _embedding([.65, 0, .76]) : _embedding([.7, .7, .14]),
        ],
        turns: [
          _turn(0, 0, 16000 * 80),
          _turn(1, 16000 * 100, 16000 * 180),
          _turn(2, 16000 * (overlap ? 50 : 90), 16000 * (overlap ? 54 : 94)),
        ],
      );
      expect(groups.toSet(), hasLength(3));
    }
  });
  test(
    'two rare overlapping labels cannot collapse through a shared anchor',
    () {
      final groups = consolidateAutomaticSpeakers(
        [
          _embedding([1, 0, 0]),
          _embedding([.65, .76, 0]),
          _embedding([.65, .76, 0]),
        ],
        turns: [
          _turn(0, 0, 16000 * 280),
          _turn(1, 16000 * 290, 16000 * 294),
          _turn(2, 16000 * 292, 16000 * 296),
        ],
      );
      expect(groups[1], isNot(groups[2]));
    },
  );
  test('weak repeated identities are not treated as a brief fragment', () {
    final groups = consolidateAutomaticSpeakers(
      [
        _embedding([1, 0]),
        _embedding([.65, .76]),
      ],
      turns: [
        _turn(0, 0, 16000 * 100),
        _turn(1, 16000 * 110, 16000 * 112),
        _turn(1, 16000 * 115, 16000 * 116),
        _turn(1, 16000 * 120, 16000 * 121),
      ],
    );
    expect(groups.toSet(), hasLength(2));
  });
  test(
    'an already busy resource is rejected without publishing a competing job',
    () async {
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
        resourceBusy: () => true,
      );
      var notifications = 0;
      service.activity.addListener(() => notifications++);
      await expectLater(
        service.analyze(
          const SpeakerDiarizationRequest(
            sessionId: 'session',
            directory: '/tmp/session',
          ),
        ),
        throwsStateError,
      );
      expect(notifications, 0);
      expect(service.hasActiveJobs, isFalse);
    },
  );
  test(
    'matching reassigns an ambiguous candidate to keep both existing identities',
    () {
      final mapping = matchSpeakerEmbeddings(
        {
          0: _embedding([.8, .6, 0]),
          1: _embedding([.75, .1, math.sqrt(1 - .75 * .75 - .1 * .1)]),
        },
        [
          _embedding([1, 0, 0]),
          _embedding([0, 1, 0]),
        ],
      );
      expect(mapping, {0: 1, 1: 0});
    },
  );

  test(
    'weak, empty and nonfinite embeddings never take an existing identity',
    () {
      final mapping = matchSpeakerEmbeddings(
        {
          5: _embedding([0, 1]),
          6: Float32List(0),
          7: _embedding([double.nan, 1]),
          8: _embedding([1, 0]),
        },
        [
          _embedding([1, 0]),
        ],
      );
      expect(mapping, {8: 0});
    },
  );

  test(
    'known total count groups the whole session with partial participation per window',
    () {
      final groups = clusterSessionSpeakers([
        _embedding([1, 0, 0]), // A alone in the first window.
        _embedding([0, 1, 0]), // B alone in the next window.
        _embedding([.98, 0, .1]), // A returns.
        _embedding([0, .97, .1]), // B returns.
      ], requestedSpeakerCount: 2);
      expect(groups[0], groups[2]);
      expect(groups[1], groups[3]);
      expect(groups[0], isNot(groups[1]));
    },
  );

  test(
    'a requested count neither invents absent people nor assigns missing embeddings',
    () {
      expect(
        clusterSessionSpeakers([
          _embedding([1, 0]),
        ], requestedSpeakerCount: 2),
        [0],
      );
      final groups = clusterSessionSpeakers([
        _embedding([1, 0]),
        _embedding([.99, .01]),
        Float32List(0),
      ], requestedSpeakerCount: 1);
      expect(groups[0], groups[1]);
      expect(groups[2], isNot(groups[0]));
    },
  );

  test('unusable noise profiles do not consume the known speaker count', () {
    final groups = clusterSessionSpeakers([
      _embedding([1, 0]),
      _embedding([.99, .01]),
      _embedding([0, 1]),
      _embedding([.01, .99]),
      Float32List(0),
      _embedding([double.nan, 0]),
      _embedding([0, 0]),
    ], requestedSpeakerCount: 2);
    expect(groups[0], groups[1]);
    expect(groups[2], groups[3]);
    expect(groups[0], isNot(groups[2]));
    expect(groups.toSet(), hasLength(5));
  });

  test(
    'automatic consolidation merges duplicate labels without a target count',
    () {
      final groups = consolidateAutomaticSpeakers(
        [
          _embedding([1, 0, 0]),
          _embedding([0, 1, 0]),
          _embedding([0, .9, math.sqrt(1 - .9 * .9)]),
        ],
        turns: [
          _turn(0, 0, 16000),
          _turn(1, 16000, 32000),
          _turn(2, 32000, 48000),
        ],
      );
      expect(groups[1], groups[2]);
      expect(groups[0], isNot(groups[1]));
    },
  );

  test(
    'overlapping labels cannot merge even through a similar third profile',
    () {
      final groups = consolidateAutomaticSpeakers(
        [
          _embedding([1, 0]),
          _embedding([.99, .1]),
          _embedding([.98, .2]),
        ],
        turns: [
          _turn(2, 15999, 24000),
          _turn(0, 0, 16000),
          _turn(1, 32000, 48000),
        ],
      );
      expect(groups[0], isNot(groups[2]));
      expect(groups.toSet(), hasLength(2));
    },
  );

  test(
    'automatic consolidation does not chain through an ambiguous profile',
    () {
      final groups = consolidateAutomaticSpeakers([
        _embedding([1, 0]),
        _embedding([math.cos(math.pi / 6), math.sin(math.pi / 6)]),
        _embedding([math.cos(math.pi / 3), math.sin(math.pi / 3)]),
      ], turns: const []);
      expect(groups.toSet(), hasLength(2));
      expect(groups[0], isNot(groups[2]));
    },
  );

  test(
    'distinct voices and missing embeddings retain their automatic labels',
    () {
      final groups = consolidateAutomaticSpeakers([
        _embedding([1, 0, 0]),
        _embedding([0, 1, 0]),
        _embedding([0, 0, 1]),
        _embedding([.6, 0, -.8]),
        Float32List(0),
        _embedding([double.nan, 0, 0]),
      ], turns: const []);
      expect(groups, [0, 1, 2, 3, 4, 5]);
      expect(consolidateAutomaticSpeakers([], turns: const []), isEmpty);
    },
  );

  test(
    'consolidation preserves interruption boundaries and source intervals',
    () {
      final turns = [
        _turn(0, 0, 16000),
        const SpeakerDiarizationTurn(
          speakerIndex: 1,
          startSample: 16000,
          endSample: 32000,
          islandIndex: 1,
        ),
      ];
      final groups = consolidateAutomaticSpeakers([
        _embedding([1, 0]),
        _embedding([.99, .01]),
      ], turns: turns);
      final segments = canonicalizeSpeakerTurns(
        turns.map(
          (turn) => SpeakerDiarizationTurn(
            speakerIndex: groups[turn.speakerIndex],
            startSample: turn.startSample,
            endSample: turn.endSample,
            islandIndex: turn.islandIndex,
          ),
        ),
      );
      expect(segments.map((s) => s.speakerId).toSet(), {'speaker_1'});
      expect(segments.map((s) => (s.startSample, s.endSample)), [
        (0, 16000),
        (16000, 32000),
      ]);
    },
  );

  test('hard boundaries split even a single continuous native chunk', () {
    final windows = planSpeakerDiarizationWindows(
      [_chunk('/tmp')],
      boundarySamples: [8000, 8000],
    );
    expect(windows.map((window) => (window.startSample, window.endSample)), [
      (0, 8000),
      (8000, 16000),
    ]);
    expect(windows[0].islandIndex, isNot(windows[1].islandIndex));
    expect(
      sourceChunkFingerprint([_chunk('/tmp')]),
      isNot(sourceChunkFingerprint([_chunk('/tmp')], boundarySamples: [8000])),
    );
  });

  test(
    'final merging respects both zero-width interruption boundaries and short missing audio',
    () {
      for (final gap in [0, 3200]) {
        final segments = canonicalizeSpeakerTurns([
          const SpeakerDiarizationTurn(
            speakerIndex: 4,
            startSample: 0,
            endSample: 16000,
            islandIndex: 0,
          ),
          SpeakerDiarizationTurn(
            speakerIndex: 4,
            startSample: 16000 + gap,
            endSample: 32000,
            islandIndex: 1,
          ),
          const SpeakerDiarizationTurn(
            speakerIndex: 4,
            startSample: 32000,
            endSample: 48000,
            islandIndex: 1,
          ),
        ]);
        expect(
          segments.map((segment) => (segment.startSample, segment.endSample)),
          [(0, 16000), (16000 + gap, 48000)],
        );
        expect(segments.map((segment) => segment.speakerId).toSet(), {
          'speaker_1',
        });
      }
    },
  );

  test(
    'source preparation is locked, same-session callers join, and failure releases activity',
    () async {
      final directory = await _temporary();
      final source = Completer<SpeakerDiarizationSource>();
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(installed: false),
      );
      final activity = <bool>[];
      service.activity.addListener(() => activity.add(service.activity.value));
      final request = SpeakerDiarizationRequest(
        sessionId: 'session',
        directory: directory.path,
        requestedSpeakerCount: 2,
        loadSource: () => source.future,
      );
      final first = service.analyze(request);
      final failed = expectLater(first, throwsStateError);
      expect(service.activity.value, isTrue);
      expect(identical(service.analyze(request), first), isTrue);
      await expectLater(
        service.analyze(
          SpeakerDiarizationRequest(
            sessionId: 'other',
            directory: '${directory.path}/other',
          ),
        ),
        throwsStateError,
      );
      expect((await service.snapshot(directory.path)).requestedSpeakerCount, 2);
      source.complete(
        SpeakerDiarizationSource(chunks: [_chunk(directory.path)]),
      );
      await failed;
      expect(service.hasActiveJobs, isFalse);
      expect(activity, [true, false]);
    },
  );

  test(
    'gateway carries native interruptions and user pauses without shifting samples',
    () async {
      final directory = await _temporary();
      final bridge = _Bridge(
        directory.path,
        timelineEvents: [
          TimelineItem.fromMap({
            'type': 'audio_interruption_began',
            'sampleOffset': 8000,
          }),
          TimelineItem.fromMap({
            'type': 'audio_interruption_ended',
            'sampleOffset': 8000,
            'payload': {'gapMs': 5000},
          }),
          TimelineItem.fromMap({
            'type': 'user_pause_began',
            'sampleOffset': 4000,
          }),
          TimelineItem.fromMap({
            'type': 'user_pause_ended',
            'sampleOffset': 4000,
            'payload': {'durationMs': 60000},
          }),
          TimelineItem.fromMap({'type': 'bookmark', 'sampleOffset': 2000}),
        ],
      );
      Map<String, Object?>? source;
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
        worker: (message) async {
          source = message;
          return _result(message);
        },
      );
      final gateway = ProductSessionExperienceGateway(
        bridge,
        speakerDiarizationService: service,
      );
      final document = await gateway.analyzeSpeakers(
        sessionId: 'session',
        directory: directory.path,
      );
      expect(source!['boundarySamples'], [4000, 8000]);
      expect(document.sourceAudioSamples, 16000);
      expect(
        document.sourceChunkFingerprint,
        sourceChunkFingerprint(
          [_chunk(directory.path)],
          boundarySamples: [4000, 8000],
        ),
      );
    },
  );

  test(
    'missing-model rebuild retains both persisted labels and controller labels',
    () async {
      final directory = await _temporary();
      final old = await _savePrevious(directory, withUserLabels: true);
      final file = File('${directory.path}/$speakerDiarizationResultFileName');
      final bytes = await file.readAsBytes();
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(installed: false),
      );
      final controller = SessionDetailController(
        session: SessionSummary.fromMap({
          'sessionId': 'session',
          'directory': directory.path,
          'state': 'completed',
        }),
        gateway: ProductSessionExperienceGateway(
          _Bridge(directory.path),
          speakerDiarizationService: service,
        ),
      );
      addTearDown(controller.dispose);
      await controller.refreshSpeakerDiarization();
      await controller.rebuildSpeakerDiarization(requestedSpeakerCount: 2);
      expect(
        controller.speakerDiarization.status,
        SpeakerDiarizationStatus.failed,
      );
      expect(controller.speakerDiarization.document?.createdAt, old.createdAt);
      expect(
        controller.speakerDiarization.document?.displayName('speaker_1'),
        '小林',
      );
      expect(await file.readAsBytes(), bytes);
      expect(
        (await service.snapshot(directory.path)).document?.createdAt,
        old.createdAt,
      );
    },
  );

  test(
    'worker failure and invalid worker output preserve a complete previous result',
    () async {
      final directory = await _temporary();
      await _savePrevious(directory, withUserLabels: true);
      final file = File('${directory.path}/$speakerDiarizationResultFileName');
      final bytes = await file.readAsBytes();
      for (final invalidOutput in [false, true]) {
        final service = SherpaSpeakerDiarizationService(
          modelResolver: const _Resolver(),
          worker: (message) async {
            if (!invalidOutput) throw StateError('worker failed');
            return {..._result(message), 'sampleRate': 8000};
          },
        );
        await expectLater(
          service.analyze(_request(directory, force: true)),
          throwsA(anyOf(isA<Exception>(), isA<Error>())),
        );
        expect(await file.readAsBytes(), bytes);
        expect(
          (await service.snapshot(directory.path)).status,
          SpeakerDiarizationStatus.failed,
        );
        expect(service.activity.value, isFalse);
      }
    },
  );

  test(
    'explicit rebuild bypasses matching cache and atomically replaces it after success',
    () async {
      final directory = await _temporary();
      await _savePrevious(directory, withUserLabels: true);
      var calls = 0;
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
        worker: (message) async {
          calls++;
          return {..._result(message), 'createdAt': 'new-result'};
        },
      );
      expect(
        (await service.analyze(_request(directory))).createdAt,
        'old-result',
      );
      expect(calls, 0);
      expect(
        (await service.snapshot(
          directory.path,
        )).document?.displayName('speaker_1'),
        '小林',
      );
      expect(
        (await service.analyze(_request(directory, force: true))).createdAt,
        'new-result',
      );
      expect(calls, 1);
      expect(
        (await service.snapshot(directory.path)).document?.hasUserEdits,
        isFalse,
      );
      expect(
        (await service.snapshot(directory.path)).document?.canUndoEdit,
        isFalse,
      );
      expect(
        (await service.snapshot(directory.path)).document?.createdAt,
        'new-result',
      );
      expect(
        File(
          '${directory.path}/$speakerDiarizationResultFileName.backup',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'interrupted task is explicit after restart, retains labels, and retries without cache',
    () async {
      final directory = await _temporary();
      final old = await _savePrevious(directory, withUserLabels: true);
      final task = File('${directory.path}/$speakerDiarizationTaskFileName');
      await task.writeAsString(
        jsonEncode({
          'status': 'running',
          'runId': 'aborted',
          'requestedSpeakerCount': 2,
        }),
      );
      var calls = 0;
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
        worker: (message) async {
          calls++;
          return _result(message);
        },
      );
      final snapshot = await service.snapshot(directory.path);
      expect(snapshot.status, SpeakerDiarizationStatus.failed);
      expect(snapshot.message, contains('已中断'));
      expect(snapshot.document?.toMap(), old.toMap());
      expect(service.hasActiveJobs, isFalse);
      await service.analyze(_request(directory));
      expect(calls, 1);
      expect(
        (await service.snapshot(directory.path)).status,
        SpeakerDiarizationStatus.ready,
      );
      expect(await task.exists(), isFalse);
    },
  );

  test(
    'committed result wins if process exits before task marker cleanup',
    () async {
      final directory = await _temporary();
      final old = await _savePrevious(directory);
      await File(
        '${directory.path}/$speakerDiarizationResultFileName',
      ).writeAsString(
        jsonEncode({...old.toMap(), 'analysisRunId': 'finished'}),
      );
      await File(
        '${directory.path}/$speakerDiarizationTaskFileName',
      ).writeAsString(jsonEncode({'status': 'running', 'runId': 'finished'}));
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
      );
      expect(
        (await service.snapshot(directory.path)).status,
        SpeakerDiarizationStatus.ready,
      );
      expect(
        await File(
          '${directory.path}/$speakerDiarizationTaskFileName',
        ).exists(),
        isFalse,
      );
      await service.deleteResult(directory.path);
      expect(
        await File(
          '${directory.path}/$speakerDiarizationTaskFileName',
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'active progress survives page reconnection and failures remain visible after restart',
    () async {
      final directory = await _temporary();
      await _savePrevious(directory);
      final started = Completer<void>();
      final gate = Completer<void>();
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
        worker: (message) async {
          (message['progressPort'] as SendPort).send({
            'stage': 'inference',
            'window': 2,
            'windows': 19,
            'processed': 25,
            'total': 100,
          });
          started.complete();
          await gate.future;
          throw StateError('native failure');
        },
      );
      final run = service.analyze(_request(directory, force: true));
      final failed = expectLater(run, throwsStateError);
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        (await service.snapshot(directory.path)).message,
        contains('2/19'),
      );
      expect((await service.snapshot(directory.path)).message, contains('25%'));
      gate.complete();
      await failed;
      final restarted = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
      );
      final snapshot = await restarted.snapshot(directory.path);
      expect(snapshot.status, SpeakerDiarizationStatus.failed);
      expect(snapshot.message, contains('native failure'));
      expect(snapshot.document, isNotNull);
    },
  );

  test(
    'old algorithm results remain readable but are not reused for a new analysis',
    () async {
      final directory = await _temporary();
      final document = await _savePrevious(directory);
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
        worker: (message) async => _result(message),
      );
      for (
        var version = 1;
        version < speakerDiarizationAlgorithmVersion;
        version++
      ) {
        await File(
          '${directory.path}/$speakerDiarizationResultFileName',
        ).writeAsString(
          jsonEncode({...document.toMap(), 'algorithmVersion': version}),
        );
        expect(
          (await service.snapshot(directory.path)).document?.algorithmVersion,
          version,
        );
        expect(
          (await service.analyze(_request(directory))).algorithmVersion,
          speakerDiarizationAlgorithmVersion,
        );
      }
    },
  );
}

Float32List _embedding(List<double> value) => Float32List.fromList(value);

SpeakerDiarizationTurn _turn(int speaker, int start, int end) =>
    SpeakerDiarizationTurn(
      speakerIndex: speaker,
      startSample: start,
      endSample: end,
      islandIndex: 0,
    );

Future<Directory> _temporary() async {
  final directory = await Directory.systemTemp.createTemp(
    'speaker-regression-',
  );
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

CommittedAudioChunk _chunk(String directory) => CommittedAudioChunk(
  sessionId: 'session',
  directory: directory,
  index: 0,
  path: '$directory/audio.pcm',
  startSample: 0,
  endSample: 16000,
  sampleRate: 16000,
);

SpeakerDiarizationRequest _request(Directory directory, {bool force = false}) =>
    SpeakerDiarizationRequest(
      sessionId: 'session',
      directory: directory.path,
      chunks: [_chunk(directory.path)],
      forceRebuild: force,
    );

Map<String, dynamic> _result(Map<String, Object?> message) => {
  ...message,
  'schemaVersion': 1,
  'algorithmVersion': speakerDiarizationAlgorithmVersion,
  'status': 'ready',
  'sampleRate': 16000,
  'createdAt': 'new-result',
  'processingMs': 1,
  'realTimeFactor': .1,
  'peakRssBytes': 1,
  'windowCount': 1,
  'segments': [
    {'speakerId': 'speaker_1', 'startSample': 0, 'endSample': 16000},
  ],
};

Future<SpeakerDiarizationDocument> _savePrevious(
  Directory directory, {
  bool withUserLabels = false,
}) async {
  var document = SpeakerDiarizationDocument.fromMap(
    _result({
      'sessionId': 'session',
      'modelId': speakerDiarizationModelId,
      'sourceAudioSamples': 16000,
      'sourceChunkFingerprint': sourceChunkFingerprint([
        _chunk(directory.path),
      ]),
    })..['createdAt'] = 'old-result',
  );
  if (withUserLabels) {
    document = document.applyEdit(const SpeakerEdit.rename('speaker_1', '小林'));
  }
  await File(
    '${directory.path}/$speakerDiarizationResultFileName',
  ).writeAsString(jsonEncode(document.toMap()));
  return document;
}

class _Resolver implements LocalModelRuntimeResolver {
  const _Resolver({this.installed = true});
  final bool installed;
  @override
  Future<SpeakerDiarizationModelFiles?> speakerDiarizationModelFiles() async =>
      installed
      ? const SpeakerDiarizationModelFiles(
          modelId: speakerDiarizationModelId,
          segmentationPath: 'test',
          embeddingPath: 'test',
        )
      : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bridge implements PoCBridge {
  _Bridge(this.directory, {this.timelineEvents = const []});
  final String directory;
  final List<TimelineItem> timelineEvents;
  @override
  Future<List<CommittedAudioChunk>> committedChunks(
    String directory, {
    int afterSample = 0,
  }) async => [_chunk(directory)];
  @override
  Future<List<TimelineItem>> timeline(String directory) async => timelineEvents;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
