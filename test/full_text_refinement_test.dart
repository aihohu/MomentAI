import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/core/models/local_model_runtime.dart';
import 'package:momentai/domain/audio/committed_audio_chunk.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';

void main() {
  test(
    'forced retry bypasses cache and keeps previous refinement on failure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'momentai-manual-refinement-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/full_text_refinement.json');
      final payload = {
        'schemaVersion': 4,
        'status': 'ready',
        'sessionId': 'saved',
        'modelId': senseVoiceFullTextModelId,
        'fullText': 'Previous usable text.',
        'sourceAudioSamples': 16000,
        'sampleRate': 16000,
        'createdAt': '2026-09-20T00:00:00Z',
        'composerVersion': 4,
        'sourceTimelineFingerprint': sourceTimelineFingerprint([]),
        'timelineProjection': [],
        'segments': [],
        'canonicalTokens': [],
        'imported': true,
      };
      await file.writeAsString(jsonEncode(payload));
      final bytes = await file.readAsBytes();
      final resolver = _MissingRefinementModel();
      final service = SenseVoiceFullTextRefinementService(
        modelResolver: resolver,
      );
      final chunks = [
        CommittedAudioChunk(
          sessionId: 'saved',
          directory: directory.path,
          index: 0,
          path: '${directory.path}/audio.pcm',
          startSample: 0,
          endSample: 16000,
          sampleRate: 16000,
        ),
      ];
      final cached = await service.refine(
        FullTextRefinementRequest(
          sessionId: 'saved',
          directory: directory.path,
          chunks: chunks,
          timeline: [],
        ),
      );
      expect(cached.fullText, 'Previous usable text.');
      expect(resolver.calls, 0);
      await expectLater(
        service.refine(
          FullTextRefinementRequest(
            sessionId: 'saved',
            directory: directory.path,
            chunks: chunks,
            timeline: [],
            forceRebuild: true,
          ),
        ),
        throwsStateError,
      );
      expect(resolver.calls, 1);
      expect(await file.readAsBytes(), bytes);
      final failed = await service.snapshot(directory.path);
      expect(failed.status, FullTextRefinementStatus.failed);
      expect(failed.document!.fullText, 'Previous usable text.');
      expect(service.hasActiveJobs, isFalse);
      await service.refine(
        FullTextRefinementRequest(
          sessionId: 'saved',
          directory: directory.path,
          chunks: chunks,
          timeline: [],
        ),
      );
      expect(
        (await service.snapshot(directory.path)).status,
        FullTextRefinementStatus.ready,
      );
    },
  );

  test(
    'imported projection preserves full text without inventing inference tokens',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'momentai-import-refinement-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/full_text_refinement.json');
      final payload = {
        'schemaVersion': 4,
        'status': 'ready',
        'sessionId': 'session_import_copy',
        'modelId': 'sensevoice-export',
        'fullText': '精修全文。\n\n第二段。',
        'sourceAudioSamples': 480111,
        'sampleRate': 16000,
        'createdAt': '2026-08-31T00:00:00Z',
        'composerVersion': 4,
        'sourceTimelineFingerprint': 'sha256:imported',
        'timelineProjection': [
          {
            'segmentId': 'original-segment',
            'startSample': 16053,
            'endSample': 480111,
            'refinedText': '第二段。',
            'fallback': false,
          },
        ],
        'segments': [],
        'canonicalTokens': [],
        'imported': true,
      };
      await file.writeAsString(jsonEncode(payload));
      final before = await file.readAsString();
      final snapshot = await SenseVoiceFullTextRefinementService().snapshot(
        directory.path,
      );
      expect(snapshot.status, FullTextRefinementStatus.ready);
      expect(snapshot.document!.fullText, payload['fullText']);
      expect(snapshot.document!.timelineProjection.single.startSample, 16053);
      expect(snapshot.document!.canonicalTokens, isEmpty);
      expect(await file.readAsString(), before);
    },
  );

  test('plans semantic ranges without changing transcript anchors', () {
    final ranges = planFullTextRefinementRanges(
      sourceAudioSamples: 1988788,
      timeline: [
        _transcript(0, 82990),
        _transcript(82990, 409510),
        _transcript(507193, 671818),
        _transcript(671818, 769501),
        _transcript(867184, 982285),
        _transcript(982285, 1310170),
        _transcript(1310170, 1473430),
        _transcript(1521589, 1587166),
        _transcript(1587166, 1915051),
        _transcript(1915051, 1988788),
      ],
    );

    expect(ranges, hasLength(5));
    expect(ranges.first.startSample, 0);
    expect(ranges.first.endSample, 422310);
    expect(ranges[2].endSample, 1322970);
    expect(ranges[3].startSample, 1297370);
    expect(ranges[2].endSample, greaterThan(ranges[3].startSample));
    expect(ranges.last.startSample, 1508789);
    expect(ranges.last.endSample, 1988788);
    for (final range in ranges) {
      expect(range.endSample - range.startSample, lessThanOrEqualTo(480000));
    }
  });

  test('stitches overlapped recognition without mid-sentence paragraphs', () {
    const segments = [
      RefinedFullTextSegment(
        startSample: 0,
        endSample: 340000,
        text: '或者就是在闭起眼睛的那一刻。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 314400,
        endSample: 560000,
        text: '闭起眼睛的那一刻，对于生活在凤凰城的翠翠来说。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 620000,
        endSample: 800000,
        text: '下一段。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
    ];

    expect(
      composeRefinedFullText(segments),
      '或者就是在闭起眼睛的那一刻，对于生活在凤凰城的翠翠来说。\n\n下一段。',
    );
  });

  test('stitches punctuation and one-character overlap differences', () {
    const segments = [
      RefinedFullTextSegment(
        startSample: 0,
        endSample: 340000,
        text: '为何要自斟具酌？就是因。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 314400,
        endSample: 560000,
        text: '具酌就是因为我想明白无误地展现自己的原则。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 534400,
        endSample: 720000,
        text: '你应当解释这些矛盾。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 694400,
        endSample: 880000,
        text: '是这些矛盾，最好的方法是写下来。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 854400,
        endSample: 1040000,
        text: '所以对我而言生。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 1014400,
        endSample: 1200000,
        text: '所以对我而言，生活就像一幅图。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
    ];

    final text = composeRefinedFullText(segments);

    expect(text, contains('为何要自斟具酌就是因为'));
    expect(text, contains('你应当解释这些矛盾，最好的方法是写下来'));
    expect(text, contains('所以对我而言，生活就像一幅图'));
    expect(text, isNot(contains('就是因。\n\n具酌')));
    expect(text, isNot(contains('这些矛盾。\n\n是这些矛盾')));
    expect(text, isNot(contains('所以对我而言生。\n\n所以对我而言')));
  });

  test('preserves a stable sentence boundary inside an exact overlap', () {
    const segments = [
      RefinedFullTextSegment(
        startSample: 0,
        endSample: 340000,
        text: '我的原则以及我是如何总结出这些原则的。我这一生。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
      RefinedFullTextSegment(
        startSample: 314400,
        endSample: 560000,
        text: '这些原则的我这一生犯了很多错误。',
        language: '<|zh|>',
        emotion: '<|NEUTRAL|>',
        event: '<|Speech|>',
      ),
    ];

    expect(composeRefinedFullText(segments), '我的原则以及我是如何总结出这些原则的。我这一生犯了很多错误。');
  });

  test('falls back to bounded full-audio ranges when live text is absent', () {
    final ranges = planFullTextRefinementRanges(
      sourceAudioSamples: 65 * 16000,
      timeline: const [],
    );

    expect(ranges, hasLength(3));
    expect(ranges[0].startSample, 0);
    expect(ranges[0].endSample, 30 * 16000);
    expect(ranges[1].startSample, 30 * 16000);
    expect(ranges[1].endSample, 60 * 16000);
    expect(ranges[2].endSample, 65 * 16000);
  });

  test('fingerprint is stable but changes with source timeline facts', () {
    const sources = [
      RefinementTimelineSource(
        segmentId: 'segment_a',
        startSample: 0,
        endSample: 16000,
        text: '原始文字',
      ),
    ];

    final first = sourceTimelineFingerprint(sources);
    final second = sourceTimelineFingerprint(sources);
    final changed = sourceTimelineFingerprint(const [
      RefinementTimelineSource(
        segmentId: 'segment_a',
        startSample: 0,
        endSample: 16001,
        text: '原始文字',
      ),
    ]);

    expect(first, startsWith('sha256:'));
    expect(first, hasLength(71));
    expect(second, first);
    expect(changed, isNot(first));
  });

  test('canonical tokens use one context-rich owner in window overlaps', () {
    const windows = [
      FullTextRefinementRange(startSample: 0, endSample: 100),
      FullTextRefinementRange(startSample: 80, endSample: 180),
    ];
    const candidates = [
      RefinedFullTextToken(
        text: '左',
        atSample: 85,
        sourceWindowIndex: 0,
        sourceTokenIndex: 0,
      ),
      RefinedFullTextToken(
        text: '旧',
        atSample: 95,
        sourceWindowIndex: 0,
        sourceTokenIndex: 1,
      ),
      RefinedFullTextToken(
        text: '重',
        atSample: 85,
        sourceWindowIndex: 1,
        sourceTokenIndex: 0,
      ),
      RefinedFullTextToken(
        text: '右',
        atSample: 95,
        sourceWindowIndex: 1,
        sourceTokenIndex: 1,
      ),
    ];

    final canonical = canonicalizeRefinementTokens(
      candidates: candidates,
      windows: windows,
    );

    expect(canonical.map((token) => token.text), ['左', '右']);
    expect(
      composeCanonicalRefinedFullText(
        canonicalTokens: canonical,
        windows: windows,
      ),
      '左右',
    );
  });

  test('projects tokens by immutable segment id and safely falls back', () {
    const sources = [
      RefinementTimelineSource(
        segmentId: 'segment_a',
        startSample: 0,
        endSample: 100,
        text: '实时原文 A',
      ),
      RefinementTimelineSource(
        segmentId: 'segment_b',
        startSample: 120,
        endSample: 220,
        text: '实时原文 B',
      ),
      RefinementTimelineSource(
        segmentId: 'segment_c',
        startSample: 240,
        endSample: 340,
        text: '实时原文 C',
      ),
    ];
    const tokens = [
      RefinedFullTextToken(
        text: '精',
        atSample: 20,
        sourceWindowIndex: 0,
        sourceTokenIndex: 0,
      ),
      RefinedFullTextToken(
        text: '修',
        atSample: 105,
        sourceWindowIndex: 0,
        sourceTokenIndex: 1,
      ),
      RefinedFullTextToken(
        text: '。',
        atSample: 230,
        sourceWindowIndex: 0,
        sourceTokenIndex: 2,
      ),
    ];

    final projection = projectRefinedTimeline(
      canonicalTokens: tokens,
      sources: sources,
      edgeToleranceSamples: 20,
    );

    expect(projection.map((item) => item.segmentId), [
      'segment_a',
      'segment_b',
      'segment_c',
    ]);
    expect(projection[0].refinedText, '精修');
    expect(projection[0].fallback, isFalse);
    expect(projection[1].refinedText, '实时原文 B');
    expect(projection[1].fallback, isTrue);
    expect(projection[2].refinedText, '实时原文 C');
    expect(projection[2].fallback, isTrue);
  });

  test('refined full text document survives a persistence round trip', () {
    final source = RefinedFullTextDocument(
      sessionId: 'session_test',
      modelId: senseVoiceFullTextModelId,
      fullText: '第一段。\n\nGood morning.',
      sourceAudioSamples: 32000,
      sampleRate: 16000,
      createdAt: DateTime.utc(2026, 8, 28, 15),
      segments: const [
        RefinedFullTextSegment(
          startSample: 0,
          endSample: 32000,
          text: '第一段。Good morning.',
          language: '<|zh|>',
          emotion: '<|NEUTRAL|>',
          event: '<|Speech|>',
        ),
      ],
      initializationMs: 2800,
      decodeMs: 300,
      realTimeFactor: 0.15,
      peakRssBytes: 800000000,
      sourceTimelineFingerprint: 'sha256:test',
      canonicalTokens: const [
        RefinedFullTextToken(
          text: '第一段。',
          atSample: 1000,
          sourceWindowIndex: 0,
          sourceTokenIndex: 0,
        ),
      ],
      timelineProjection: const [
        RefinedTimelineSegment(
          segmentId: 'segment_0_32000',
          startSample: 0,
          endSample: 32000,
          refinedText: '第一段。Good morning.',
          fallback: false,
        ),
      ],
    );

    final restored = RefinedFullTextDocument.fromMap(source.toMap());

    expect(restored.fullText, source.fullText);
    expect(restored.modelId, senseVoiceFullTextModelId);
    expect(restored.segments.single.language, '<|zh|>');
    expect(restored.realTimeFactor, 0.15);
    expect(restored.sourceTimelineFingerprint, 'sha256:test');
    expect(restored.canonicalTokens.single.atSample, 1000);
    expect(restored.timelineProjection.single.segmentId, 'segment_0_32000');
    expect(source.toMap()['schemaVersion'], refinedFullTextSchemaVersion);
  });

  test(
    'v4 snapshot keeps canonical full text instead of legacy stitching',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'momentai_refinement_v4_snapshot_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = RefinedFullTextDocument(
        sessionId: 'session_v4',
        modelId: senseVoiceFullTextModelId,
        fullText: '规范 token 全文。',
        sourceAudioSamples: 32000,
        sampleRate: 16000,
        createdAt: DateTime.utc(2026, 8, 30),
        segments: const [
          RefinedFullTextSegment(
            startSample: 0,
            endSample: 32000,
            text: '旧窗口拼接文字。',
            language: '<|zh|>',
            emotion: '<|NEUTRAL|>',
            event: '<|Speech|>',
          ),
        ],
        initializationMs: 1,
        decodeMs: 1,
        realTimeFactor: 0.1,
        peakRssBytes: 1,
        sourceTimelineFingerprint: 'sha256:v4',
        canonicalTokens: const [
          RefinedFullTextToken(
            text: '规范 token 全文。',
            atSample: 100,
            sourceWindowIndex: 0,
            sourceTokenIndex: 0,
          ),
        ],
      );
      final file = File('${directory.path}/full_text_refinement.json');
      await file.writeAsString(jsonEncode(document.toMap()));

      final snapshot = await SenseVoiceFullTextRefinementService().snapshot(
        directory.path,
      );

      expect(snapshot.document?.fullText, '规范 token 全文。');
    },
  );

  test('migrates persisted v1 text with the safer overlap composer', () async {
    final directory = await Directory.systemTemp.createTemp(
      'momentai_refinement_migration_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final payload = <String, Object?>{
      'schemaVersion': 1,
      'status': 'ready',
      'sessionId': 'session_migration',
      'modelId': senseVoiceFullTextModelId,
      'fullText': '所以对我而言生。\n\n所以对我而言，生活就像一幅图。',
      'sourceAudioSamples': 640000,
      'sampleRate': 16000,
      'createdAt': DateTime.utc(2026, 8, 30).toIso8601String(),
      'initializationMs': 400,
      'decodeMs': 1000,
      'realTimeFactor': 0.03,
      'peakRssBytes': 500000000,
      'segments': const [
        {
          'startSample': 0,
          'endSample': 340000,
          'text': '所以对我而言生。',
          'language': '<|zh|>',
          'emotion': '<|NEUTRAL|>',
          'event': '<|Speech|>',
        },
        {
          'startSample': 314400,
          'endSample': 640000,
          'text': '所以对我而言，生活就像一幅图。',
          'language': '<|zh|>',
          'emotion': '<|NEUTRAL|>',
          'event': '<|Speech|>',
        },
      ],
    };
    final file = File('${directory.path}/full_text_refinement.json');
    await file.writeAsString(jsonEncode(payload));

    final snapshot = await SenseVoiceFullTextRefinementService().snapshot(
      directory.path,
    );
    final migrated = jsonDecode(await file.readAsString()) as Map;

    expect(snapshot.document?.fullText, '所以对我而言，生活就像一幅图。');
    expect(migrated['schemaVersion'], refinedFullTextSchemaVersion);
    expect(migrated['fullText'], snapshot.document?.fullText);
  });

  test(
    'migrates persisted v2 text while preserving sentence boundaries',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'momentai_refinement_v2_migration_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final payload = <String, Object?>{
        'schemaVersion': 2,
        'status': 'ready',
        'sessionId': 'session_v2_migration',
        'modelId': senseVoiceFullTextModelId,
        'fullText': '总结出这些原则的我这一生犯了很多错误。',
        'sourceAudioSamples': 640000,
        'sampleRate': 16000,
        'createdAt': DateTime.utc(2026, 8, 30).toIso8601String(),
        'initializationMs': 400,
        'decodeMs': 1000,
        'realTimeFactor': 0.03,
        'peakRssBytes': 500000000,
        'segments': const [
          {
            'startSample': 0,
            'endSample': 340000,
            'text': '我是如何总结出这些原则的。我这一生。',
            'language': '<|zh|>',
            'emotion': '<|NEUTRAL|>',
            'event': '<|Speech|>',
          },
          {
            'startSample': 314400,
            'endSample': 640000,
            'text': '这些原则的我这一生犯了很多错误。',
            'language': '<|zh|>',
            'emotion': '<|NEUTRAL|>',
            'event': '<|Speech|>',
          },
        ],
      };
      final file = File('${directory.path}/full_text_refinement.json');
      await file.writeAsString(jsonEncode(payload));

      final snapshot = await SenseVoiceFullTextRefinementService().snapshot(
        directory.path,
      );
      final migrated = jsonDecode(await file.readAsString()) as Map;

      expect(snapshot.document?.fullText, '我是如何总结出这些原则的。我这一生犯了很多错误。');
      expect(migrated['schemaVersion'], refinedFullTextSchemaVersion);
      expect(migrated['fullText'], snapshot.document?.fullText);
    },
  );

  test('reads v3 safely without inventing a timeline projection', () async {
    final directory = await Directory.systemTemp.createTemp(
      'momentai_refinement_v3_migration_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final payload = <String, Object?>{
      'schemaVersion': 3,
      'status': 'ready',
      'sessionId': 'session_v3_migration',
      'modelId': senseVoiceFullTextModelId,
      'fullText': '已有的精修全文。',
      'sourceAudioSamples': 32000,
      'sampleRate': 16000,
      'createdAt': DateTime.utc(2026, 8, 30).toIso8601String(),
      'initializationMs': 400,
      'decodeMs': 1000,
      'realTimeFactor': 0.5,
      'peakRssBytes': 500000000,
      'segments': const [
        {
          'startSample': 0,
          'endSample': 32000,
          'text': '已有的精修全文。',
          'language': '<|zh|>',
          'emotion': '<|NEUTRAL|>',
          'event': '<|Speech|>',
        },
      ],
    };
    final file = File('${directory.path}/full_text_refinement.json');
    await file.writeAsString(jsonEncode(payload));

    final snapshot = await SenseVoiceFullTextRefinementService().snapshot(
      directory.path,
    );
    final migrated = jsonDecode(await file.readAsString()) as Map;

    expect(snapshot.status, FullTextRefinementStatus.ready);
    expect(snapshot.document?.fullText, '已有的精修全文。');
    expect(snapshot.document?.sourceTimelineFingerprint, isEmpty);
    expect(snapshot.document?.composerVersion, 0);
    expect(snapshot.document?.canonicalTokens, isEmpty);
    expect(snapshot.document?.timelineProjection, isEmpty);
    expect(migrated['schemaVersion'], refinedFullTextSchemaVersion);
  });
}

TimelineItem _transcript(int startSample, int endSample) =>
    TimelineItem.fromMap(<Object?, Object?>{
      'kind': 'transcript',
      'segmentId': 'segment_${startSample}_$endSample',
      'sampleOffset': startSample,
      'endSample': endSample,
      'startMs': startSample * 1000 ~/ 16000,
      'endMs': endSample * 1000 ~/ 16000,
      'text': '转写',
    });

class _MissingRefinementModel implements LocalModelRuntimeResolver {
  int calls = 0;
  @override
  Future<RefinementModelFiles?> refinementModelFiles() async {
    calls++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
