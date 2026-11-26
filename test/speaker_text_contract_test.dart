import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/ai/ai_models.dart';
import 'package:momentai/core/ai/ai_request.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/domain/session/session_summary.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/canonical_session_text.dart';
import 'package:momentai/product/session_ai_source.dart';
import 'package:momentai/product/speaker_session_text.dart';

void main() {
  test('Android produced archives use Dart text and speaker fingerprints', () {
    for (final name in ['android-media-v1', 'android-speaker-v1']) {
      final zip = ZipDecoder().decodeBytes(
        File('test/fixtures/m2/$name.momentai').readAsBytesSync(),
        verify: true,
      );
      final doc =
          jsonDecode(
                utf8.decode(zip.findFile('session.json')!.content as List<int>),
              )
              as Map;
      final items = (doc['timeline'] as List)
          .map((row) => TimelineItem.fromMap(row as Map))
          .toList();
      expect(
        sourceTimelineFingerprint(refinementTimelineSources(items)),
        doc['canonicalText']['sourceTimelineFingerprint'],
      );
      if (doc['extensions'] != null) {
        final extension = doc['extensions']['speakerDiarizationV1'];
        final document = SpeakerDiarizationDocument.fromMap(
          extension['document'] as Map,
        );
        document.validateSpeakerLabels();
        expect(
          speakerSessionText(
            canonical: canonicalSessionText(
              timeline: items,
              refinement: const FullTextRefinementSnapshot.unavailable(),
            ),
            document: document,
          ),
          extension['textProjection'],
        );
      }
    }
  });
  final fixture =
      jsonDecode(
            File('test/fixtures/m2/speaker-text-v1.json').readAsStringSync(),
          )
          as Map;
  final document = SpeakerDiarizationDocument.fromMap(
    fixture['document'] as Map,
  );
  final timeline = (fixture['canonical']['segments'] as List)
      .map(
        (s) => TimelineItem.fromMap({
          ...s as Map,
          'kind': 'transcript',
          'sampleOffset': s['startSample'],
        }),
      )
      .toList();
  const refinement = FullTextRefinementSnapshot.unavailable();
  final canonical = canonicalSessionText(
    timeline: timeline,
    refinement: refinement,
  );
  final session = SessionSummary.fromMap({
    'sessionId': document.sessionId,
    'title': '公开样例',
    'directory': '/synthetic',
    'state': 'completed',
    'durationSamples': 64000,
    'startedAtWall': document.createdAt,
  });
  AiSourceSnapshot source([SpeakerDiarizationDocument? speakers]) =>
      sessionAiSource(
        session: session,
        timeline: timeline,
        refinement: refinement,
        speakers: speakers,
      );

  test(
    'shared public golden covers single, turns, overlap, partial and no attribution',
    () {
      document.validateSpeakerLabels();
      expect(
        speakerSessionText(canonical: canonical, document: document),
        fixture['expected'],
      );
      expect(canonical.toMap()['schemaVersion'], 1);
      expect(canonical.fullText, fixture['canonical']['fullText']);
      expect(canonical.toMap().containsKey('speakerVersion'), isFalse);
    },
  );

  test(
    'rename, merge, undo and rebuild change AI source without losing canonical text',
    () {
      final original = source(document);
      final renamed = document.applyEdit(
        const SpeakerEdit.rename('speaker_1', '小林'),
      );
      final undone = renamed.applyEdit(const SpeakerEdit.undo());
      final unmerged = document.applyEdit(const SpeakerEdit.undo());
      for (final updated in [renamed, undone, unmerged]) {
        expect(source(updated).fingerprint, isNot(original.fingerprint));
        expect(source(updated).text, original.text);
      }
      final rebuilt = SpeakerDiarizationDocument.fromMap({
        ...document.toMap(),
        'createdAt': '2026-09-10T00:01:00Z',
      });
      expect(source(rebuilt).fingerprint, isNot(original.fingerprint));
      expect(source().payload.containsKey('speakerText'), isFalse);
      expect(
        original.payload.toString(),
        isNot(contains(document.sourceChunkFingerprint)),
      );
      expect(original.payload.toString(), isNot(contains('/synthetic')));
      expect(
        () => source(
          SpeakerDiarizationDocument.fromMap({
            ...document.toMap(),
            'sessionId': 'session_wrong',
          }),
        ),
        throwsA(isA<AiFailure>()),
      );
    },
  );

  test('AI excludes successful dialogue from an earlier speaker revision', () {
    final old = source(document);
    final current = source(
      document.applyEdit(const SpeakerEdit.rename('speaker_1', '小林')),
    );
    final now = DateTime.utc(2026, 9, 10);
    final run = AiRun(
      id: 'old',
      kind: AiRunKind.chat,
      status: AiRunStatus.complete,
      question: '谁说的',
      text: '旧说话人结论',
      conversationId: 'c',
      sourceFingerprint: old.fingerprint,
      textLayer: old.textLayer,
      endpoint: 'https://example.test',
      hasGaps: false,
      model: 'test',
      createdAt: now,
    );
    final request = AiPreparedRequest.create(
      credentials: AiCredentials(
        AiConfiguration(baseUrl: 'https://example.test/v1', model: 'test'),
        'not-real',
      ),
      source: current,
      kind: AiRunKind.chat,
      question: '谁说的',
      conversationId: 'c',
      document: AiDocument(
        session.sessionId,
        [run],
        conversations: [
          AiConversation(id: 'c', title: '样例', createdAt: now, updatedAt: now),
        ],
      ),
    );
    expect(request.historyCount, 0);
    expect(request.omittedHistoryCount, 1);
    expect(request.preview, isNot(contains('旧说话人结论')));
    expect(request.messages.first.content, contains('不得把整段'));
  });

  test(
    'persisted corrupt segments and overlap merges cannot be revived by undo',
    () {
      expect(
        () => SpeakerDiarizationDocument.fromMap({
          ...document.toMap(),
          'segments': [null],
        }),
        throwsFormatException,
      );
      final edits = Map<String, Object?>.from(
        document.toMap()['labelEdits'] as Map,
      );
      edits['history'] = [
        {
          'names': <String, String>{},
          'mergedInto': {'speaker_2': 'speaker_4'},
        },
      ];
      expect(
        () => SpeakerDiarizationDocument.fromMap({
          ...document.toMap(),
          'labelEdits': edits,
        }).validateSpeakerLabels(),
        throwsFormatException,
      );
    },
  );
}
