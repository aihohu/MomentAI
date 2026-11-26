import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/models/local_model_runtime.dart';
import 'package:momentai/core/speaker/speaker_diarization_service.dart';
import 'package:momentai/domain/audio/committed_audio_chunk.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';

void main() {
  test(
    'known count reaches native clustering only for the complete single window',
    () {
      final short = [_chunk(index: 0, start: 0, end: 400 * 16000)];
      final whole = planSpeakerDiarizationWindows(short);
      expect(
        speakerWindowClusterCount(windows: whole, requestedSpeakerCount: 2),
        2,
      );
      expect(
        speakerWindowClusterCount(windows: whole, requestedSpeakerCount: 4),
        4,
      );
      expect(
        speakerWindowClusterCount(windows: whole, requestedSpeakerCount: null),
        -1,
      );
      for (final windows in [
        planSpeakerDiarizationWindows([
          _chunk(index: 0, start: 0, end: 1200 * 16000),
        ]),
        planSpeakerDiarizationWindows(short, boundarySamples: [200 * 16000]),
        planSpeakerDiarizationWindows([
          _chunk(index: 0, start: 0, end: 16000),
          _chunk(index: 1, start: 32000, end: 48000),
        ]),
        <SpeakerDiarizationWindow>[],
      ]) {
        expect(
          speakerWindowClusterCount(windows: windows, requestedSpeakerCount: 2),
          -1,
        );
      }
    },
  );
  test('long audio windows bound memory and own every sample exactly once', () {
    final chunks = [_chunk(index: 0, start: 0, end: 25 * 60 * 16000)];

    final windows = planSpeakerDiarizationWindows(chunks);

    expect(windows, hasLength(3));
    expect(windows.first.startSample, 0);
    expect(windows.last.endSample, 25 * 60 * 16000);
    for (var index = 0; index < windows.length; index++) {
      final window = windows[index];
      expect(
        window.endSample - window.startSample,
        lessThanOrEqualTo(10 * 60 * 16000),
      );
      expect(
        window.trustedStartSample,
        greaterThanOrEqualTo(window.startSample),
      );
      expect(window.trustedEndSample, lessThanOrEqualTo(window.endSample));
      if (index > 0) {
        expect(window.trustedStartSample, windows[index - 1].trustedEndSample);
        expect(window.startSample, lessThan(windows[index - 1].endSample));
      }
    }
  });

  test('window planning never analyzes across a confirmed audio gap', () {
    final chunks = [
      _chunk(index: 0, start: 0, end: 16000),
      _chunk(index: 1, start: 32000, end: 48000),
    ];

    final windows = planSpeakerDiarizationWindows(chunks);

    expect(windows, hasLength(2));
    expect((windows[0].startSample, windows[0].endSample), (0, 16000));
    expect((windows[1].startSample, windows[1].endSample), (32000, 48000));
  });

  test('timeline attribution reports one or multiple anonymous speakers', () {
    const segments = [
      SpeakerDiarizationSegment(
        speakerId: 'speaker_1',
        startSample: 0,
        endSample: 20000,
      ),
      SpeakerDiarizationSegment(
        speakerId: 'speaker_2',
        startSample: 20000,
        endSample: 40000,
      ),
    ];

    final first = attributeSpeakerRange(
      segments: segments,
      startSample: 1000,
      endSample: 12000,
    );
    final crossing = attributeSpeakerRange(
      segments: segments,
      startSample: 16000,
      endSample: 26000,
    );

    expect(first?.speakerIds, ['speaker_1']);
    expect(first?.dominantSpeakerId, 'speaker_1');
    expect(crossing?.speakerIds, ['speaker_2', 'speaker_1']);
    expect(crossing?.hasMultipleSpeakers, isTrue);
    expect(speakerDisplayName('speaker_2'), '说话人 2');
  });

  test(
    'persisted speaker results are readable and independently deletable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'momentai-speaker-result-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File('${directory.path}/$speakerDiarizationResultFileName');
      await file.writeAsString('''
{"schemaVersion":1,"status":"ready","sessionId":"session","modelId":"model","sourceAudioSamples":32000,"sampleRate":16000,"sourceChunkFingerprint":"sha256:test","requestedSpeakerCount":2,"createdAt":"2026-09-05T00:00:00Z","processingMs":20,"realTimeFactor":0.01,"peakRssBytes":1,"windowCount":1,"segments":[{"speakerId":"speaker_1","startSample":0,"endSample":16000},{"speakerId":"speaker_2","startSample":16000,"endSample":32000}]}
''', flush: true);
      final service = SherpaSpeakerDiarizationService(
        modelResolver: const _Resolver(),
      );

      final snapshot = await service.snapshot(directory.path);

      expect(snapshot.status, SpeakerDiarizationStatus.ready);
      expect(snapshot.document?.speakerCount, 2);
      expect(snapshot.document?.requestedSpeakerCount, 2);
      await file.rename('${file.path}.backup');
      final recovered = await service.snapshot(directory.path);
      expect(recovered.status, SpeakerDiarizationStatus.ready);
      expect(await file.exists(), isTrue);
      await service.deleteResult(directory.path);
      expect(await file.exists(), isFalse);
    },
  );

  test('chunk fingerprint changes when immutable sample facts change', () {
    final original = sourceChunkFingerprint([
      _chunk(index: 0, start: 0, end: 16000),
    ]);
    final changed = sourceChunkFingerprint([
      _chunk(index: 0, start: 0, end: 16001),
    ]);

    expect(original, startsWith('sha256:'));
    expect(changed, isNot(original));
  });

  test('running snapshot preserves requested speaker count', () async {
    final directory = await Directory.systemTemp.createTemp(
      'momentai-speaker-running-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final resolver = _DeferredResolver();
    final service = SherpaSpeakerDiarizationService(modelResolver: resolver);
    final analysis = service.analyze(
      SpeakerDiarizationRequest(
        sessionId: 'session',
        directory: directory.path,
        chunks: [_chunk(index: 0, start: 0, end: 16000)],
        requestedSpeakerCount: 2,
      ),
    );

    final snapshot = await service.snapshot(directory.path);

    expect(snapshot.status, SpeakerDiarizationStatus.processing);
    expect(snapshot.requestedSpeakerCount, 2);
    resolver.complete(null);
    await expectLater(analysis, throwsStateError);
  });

  test('requested speaker count is validated before model work', () async {
    final service = SherpaSpeakerDiarizationService(
      modelResolver: const _Resolver(),
    );

    await expectLater(
      service.analyze(
        SpeakerDiarizationRequest(
          sessionId: 'session',
          directory: '/tmp/session',
          chunks: [_chunk(index: 0, start: 0, end: 16000)],
          requestedSpeakerCount: maximumRequestedSpeakerCount + 1,
        ),
      ),
      throwsArgumentError,
    );
  });
}

CommittedAudioChunk _chunk({
  required int index,
  required int start,
  required int end,
}) => CommittedAudioChunk(
  sessionId: 'session',
  directory: '/tmp/session',
  index: index,
  path: '/tmp/chunk_$index.pcm',
  startSample: start,
  endSample: end,
  sampleRate: 16000,
);

class _Resolver implements LocalModelRuntimeResolver {
  const _Resolver();

  @override
  Future<RealtimeModelFiles> activeRealtimeModelFiles() =>
      throw UnimplementedError();

  @override
  Future<RefinementModelFiles?> refinementModelFiles() =>
      throw UnimplementedError();

  @override
  Future<SpeakerDiarizationModelFiles?> speakerDiarizationModelFiles() async =>
      null;
}

class _DeferredResolver implements LocalModelRuntimeResolver {
  final _speaker = Completer<SpeakerDiarizationModelFiles?>();

  void complete(SpeakerDiarizationModelFiles? value) {
    if (!_speaker.isCompleted) _speaker.complete(value);
  }

  @override
  Future<RealtimeModelFiles> activeRealtimeModelFiles() =>
      throw UnimplementedError();

  @override
  Future<RefinementModelFiles?> refinementModelFiles() =>
      throw UnimplementedError();

  @override
  Future<SpeakerDiarizationModelFiles?> speakerDiarizationModelFiles() =>
      _speaker.future;
}
