import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/models/local_model_runtime.dart';
import 'package:momentai/core/speaker/speaker_diarization_service.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';

void main() {
  test(
    'rename, merge and undo survive restart without changing model segments',
    () {
      final original = _document();
      final named = original.applyEdit(
        const SpeakerEdit.rename('speaker_1', '  小林  '),
      );
      final merged = named.applyEdit(
        const SpeakerEdit.merge('speaker_3', 'speaker_1'),
      );
      final reloaded = SpeakerDiarizationDocument.fromMap(
        jsonDecode(jsonEncode(merged.toMap())) as Map<String, dynamic>,
      );
      reloaded.validateSpeakerLabels();
      expect(reloaded.speakerIds, ['speaker_1', 'speaker_2']);
      expect(reloaded.displayName('speaker_3'), '小林');
      expect(
        reloaded.segments.map((s) => s.toMap()),
        original.segments.map((s) => s.toMap()),
      );
      expect(reloaded.sourceChunkFingerprint, original.sourceChunkFingerprint);
      expect(reloaded.algorithmVersion, original.algorithmVersion);
      final unmerged = reloaded.applyEdit(const SpeakerEdit.undo());
      expect(unmerged.speakerCount, 3);
      expect(unmerged.displayName('speaker_1'), '小林');
      final unnamed = unmerged.applyEdit(const SpeakerEdit.undo());
      expect(unnamed.hasUserEdits, isFalse);
      expect(unnamed.canUndoEdit, isFalse);
      expect(unnamed.editRevision, 4);
      expect(
        () => unnamed.applyEdit(const SpeakerEdit.undo()),
        throwsStateError,
      );
    },
  );

  test('old documents stay readable and invalid user edits are rejected', () {
    final original = _document();
    expect(original.toMap().containsKey('labelEdits'), isFalse);
    expect(
      SpeakerDiarizationDocument.fromMap(original.toMap()).editRevision,
      0,
    );
    expect(
      () => original.applyEdit(const SpeakerEdit.rename('speaker_4', '小林')),
      throwsStateError,
    );
    expect(
      () => original.applyEdit(const SpeakerEdit.rename('speaker_1', 'a\nb')),
      throwsArgumentError,
    );
    expect(
      () => original.applyEdit(SpeakerEdit.rename('speaker_1', '人' * 41)),
      throwsArgumentError,
    );
    expect(
      () => original.applyEdit(const SpeakerEdit.rename('speaker_1', '说话人 2')),
      throwsArgumentError,
    );
    final named = original.applyEdit(
      const SpeakerEdit.rename('speaker_1', '小林'),
    );
    expect(
      () => named.applyEdit(const SpeakerEdit.rename('speaker_2', '小林')),
      throwsArgumentError,
    );
    expect(
      named
          .applyEdit(const SpeakerEdit.rename('speaker_1', '   '))
          .displayName('speaker_1'),
      '说话人 1',
    );
    final corrupt = named.toMap();
    (corrupt['labelEdits'] as Map)['current'] = {
      'names': <String, String>{},
      'mergedInto': {'speaker_1': 'speaker_9'},
    };
    expect(
      () => SpeakerDiarizationDocument.fromMap(corrupt).validateSpeakerLabels(),
      throwsFormatException,
    );
  });

  test(
    'merge chains flatten and overlap constraints propagate across groups',
    () {
      final merged = _document().applyEdit(
        const SpeakerEdit.merge('speaker_1', 'speaker_3'),
      );
      final all = merged.applyEdit(
        const SpeakerEdit.merge('speaker_3', 'speaker_2'),
      );
      expect(all.speakerIds, ['speaker_2']);
      expect(all.labels.mergedInto, {
        'speaker_1': 'speaker_2',
        'speaker_3': 'speaker_2',
      });
      all.validateSpeakerLabels();
      final overlap = _document(overlap: true);
      expect(overlap.canMergeSpeakers('speaker_1', 'speaker_2'), isFalse);
      expect(
        () => overlap.applyEdit(
          const SpeakerEdit.merge('speaker_1', 'speaker_2'),
        ),
        throwsStateError,
      );
      final group = overlap.applyEdit(
        const SpeakerEdit.merge('speaker_3', 'speaker_1'),
      );
      expect(group.canMergeSpeakers('speaker_1', 'speaker_2'), isFalse);
    },
  );

  test(
    'attribution distinguishes turns from overlap only inside the requested range',
    () {
      final turns = attributeSpeakerRange(
        segments: _document().segments,
        startSample: 0,
        endSample: 60000,
      )!;
      expect(turns.hasMultipleSpeakers, isTrue);
      expect(turns.hasOverlappingSpeech, isFalse);
      final overlap = _document(overlap: true);
      expect(
        attributeSpeakerRange(
          segments: overlap.segments,
          startSample: 18000,
          endSample: 25000,
        )!.hasOverlappingSpeech,
        isTrue,
      );
      expect(
        attributeSpeakerRange(
          segments: overlap.segments.reversed,
          startSample: 0,
          endSample: 18000,
        )!.hasOverlappingSpeech,
        isFalse,
      );
      final merged = _document().applyEdit(
        const SpeakerEdit.merge('speaker_2', 'speaker_1'),
      );
      expect(
        attributeSpeakerRange(
          segments: merged.effectiveSegments,
          startSample: 0,
          endSample: 40000,
        )!.hasMultipleSpeakers,
        isFalse,
      );
    },
  );

  test(
    'undo history is bounded and no-op rename does not consume a revision',
    () {
      var doc = _document();
      for (var i = 0; i < 25; i++) {
        doc = doc.applyEdit(SpeakerEdit.rename('speaker_1', '名称 $i'));
      }
      expect(doc.editHistory.length, maximumSpeakerEditHistory);
      expect(
        identical(
          doc.applyEdit(const SpeakerEdit.rename('speaker_1', '名称 24')),
          doc,
        ),
        isTrue,
      );
      for (var i = 0; i < maximumSpeakerEditHistory; i++) {
        doc = doc.applyEdit(const SpeakerEdit.undo());
      }
      expect(doc.displayName('speaker_1'), '名称 4');
      expect(doc.canUndoEdit, isFalse);
    },
  );

  late Directory directory;
  late File file;
  late SherpaSpeakerDiarizationService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'momentai-speaker-edits-',
    );
    file = File('${directory.path}/$speakerDiarizationResultFileName');
    service = SherpaSpeakerDiarizationService(modelResolver: _NoModels());
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'service saves without models, rejects stale edits and supports crash recovery',
    () async {
      final original = _document();
      await file.writeAsString(jsonEncode(original.toMap()));
      final updated = await service.editResult(
        directory.path,
        expectedDocument: original,
        edit: const SpeakerEdit.rename('speaker_1', '小林'),
      );
      expect(service.hasActiveJobs, isFalse);
      final saved = await file.readAsString();
      await expectLater(
        service.editResult(
          directory.path,
          expectedDocument: original,
          edit: const SpeakerEdit.merge('speaker_3', 'speaker_1'),
        ),
        throwsStateError,
      );
      expect(await file.readAsString(), saved);
      await file.rename('${file.path}.backup');
      final restarted = SherpaSpeakerDiarizationService(
        modelResolver: _NoModels(),
      );
      final snapshot = await restarted.snapshot(directory.path);
      expect(snapshot.document!.displayName('speaker_1'), '小林');
      await restarted.editResult(
        directory.path,
        expectedDocument: updated,
        edit: const SpeakerEdit.undo(),
      );
      expect(
        (await restarted.snapshot(directory.path)).document!.hasUserEdits,
        isFalse,
      );
    },
  );

  test(
    'edit reserves the mutation slot before IO and snapshots wait for the completed write',
    () async {
      final original = _document();
      await file.writeAsString(jsonEncode(original.toMap()));
      final first = service.editResult(
        directory.path,
        expectedDocument: original,
        edit: const SpeakerEdit.rename('speaker_1', '小林'),
      );
      expect(service.hasActiveJobs, isTrue);
      final snapshot = service.snapshot(directory.path);
      await expectLater(
        service.editResult(
          directory.path,
          expectedDocument: original,
          edit: const SpeakerEdit.rename('speaker_2', '小王'),
        ),
        throwsStateError,
      );
      await expectLater(service.deleteResult(directory.path), throwsStateError);
      await expectLater(
        service.analyze(
          SpeakerDiarizationRequest(
            sessionId: 'session',
            directory: directory.path,
          ),
        ),
        throwsStateError,
      );
      await first;
      expect((await snapshot).document!.displayName('speaker_1'), '小林');
      expect(service.hasActiveJobs, isFalse);
    },
  );

  test(
    'failed write retains the prior file and releases the mutation slot',
    () async {
      final original = _document();
      await file.writeAsString(jsonEncode(original.toMap()));
      await Directory('${file.path}.part').create();
      final before = await file.readAsString();
      await expectLater(
        service.editResult(
          directory.path,
          expectedDocument: original,
          edit: const SpeakerEdit.rename('speaker_1', '小林'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), before);
      expect(service.hasActiveJobs, isFalse);
      expect(
        (await service.snapshot(
          directory.path,
        )).document!.displayName('speaker_1'),
        '说话人 1',
      );
    },
  );

  test(
    'analysis blocks editing and a failed rebuild retains saved user labels',
    () async {
      final named = _document().applyEdit(
        const SpeakerEdit.rename('speaker_1', '小林'),
      );
      await file.writeAsString(jsonEncode(named.toMap()));
      final source = Completer<SpeakerDiarizationSource>();
      final analysis = service.analyze(
        SpeakerDiarizationRequest(
          sessionId: 'session',
          directory: directory.path,
          forceRebuild: true,
          loadSource: () => source.future,
        ),
      );
      await expectLater(
        service.editResult(
          directory.path,
          expectedDocument: named,
          edit: const SpeakerEdit.undo(),
        ),
        throwsStateError,
      );
      source.complete(const SpeakerDiarizationSource(chunks: []));
      await expectLater(analysis, throwsStateError);
      expect(
        (await service.snapshot(
          directory.path,
        )).document!.displayName('speaker_1'),
        '小林',
      );
    },
  );
}

SpeakerDiarizationDocument _document({bool overlap = false}) =>
    SpeakerDiarizationDocument(
      sessionId: 'session',
      modelId: 'model',
      sourceAudioSamples: 60000,
      sampleRate: 16000,
      sourceChunkFingerprint: 'sha256:test',
      createdAt: '2026-09-09T00:00:00Z',
      segments: [
        const SpeakerDiarizationSegment(
          speakerId: 'speaker_1',
          startSample: 0,
          endSample: 20000,
        ),
        SpeakerDiarizationSegment(
          speakerId: 'speaker_2',
          startSample: overlap ? 18000 : 20000,
          endSample: 40000,
        ),
        const SpeakerDiarizationSegment(
          speakerId: 'speaker_3',
          startSample: 40000,
          endSample: 60000,
        ),
      ],
      processingMs: 10,
      realTimeFactor: 0.1,
      peakRssBytes: 1,
      windowCount: 1,
    );

class _NoModels implements LocalModelRuntimeResolver {
  @override
  Future<SpeakerDiarizationModelFiles?> speakerDiarizationModelFiles() async =>
      null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected model work.');
}
