import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/canonical_session_text.dart';
import 'package:momentai/product/timeline_display_item.dart';

void main() {
  test('canonical consumer text keeps sample anchors and both text layers', () {
    final timeline = [_transcript('seg_1', 0, 16000, '实时原文')];
    final sources = refinementTimelineSources(timeline);
    final refinement = FullTextRefinementSnapshot(
      status: FullTextRefinementStatus.ready,
      document: RefinedFullTextDocument(
        sessionId: 'session_1',
        modelId: 'sensevoice-test',
        fullText: '精修文字。',
        sourceAudioSamples: 16000,
        sampleRate: 16000,
        createdAt: DateTime.utc(2026, 8, 30),
        segments: const [],
        initializationMs: 1,
        decodeMs: 2,
        realTimeFactor: 0.01,
        peakRssBytes: 3,
        sourceTimelineFingerprint: sourceTimelineFingerprint(sources),
        composerVersion: refinedTimelineComposerVersion,
        timelineProjection: const [
          RefinedTimelineSegment(
            segmentId: 'seg_1',
            startSample: 0,
            endSample: 16000,
            refinedText: '精修文字。',
            fallback: false,
          ),
        ],
      ),
    );

    final canonical = canonicalSessionText(
      timeline: timeline,
      refinement: refinement,
    );

    expect(canonical.availability, TimelineDisplayAvailability.ready);
    expect(canonical.defaultTextLayer, TimelineTextLayer.refined);
    expect(canonical.fullText, '精修文字。');
    expect(canonical.segments.single.segmentId, 'seg_1');
    expect(canonical.segments.single.startSample, 0);
    expect(canonical.segments.single.endSample, 16000);
    expect(canonical.segments.single.liveText, '实时原文');
    expect(canonical.segments.single.refinedText, '精修文字。');
    expect(canonical.segments.single.text, '精修文字。');
    expect(canonical.toMap()['format'], 'org.hohu.momentai.canonical-text');
  });

  test(
    'canonical consumer text safely falls back when projection is stale',
    () {
      final timeline = [_transcript('seg_1', 0, 16000, '实时原文')];
      final refinement = FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument(
          sessionId: 'session_1',
          modelId: 'sensevoice-test',
          fullText: '不应消费的过期精修',
          sourceAudioSamples: 16000,
          sampleRate: 16000,
          createdAt: DateTime.utc(2026, 8, 30),
          segments: const [],
          initializationMs: 1,
          decodeMs: 2,
          realTimeFactor: 0.01,
          peakRssBytes: 3,
          sourceTimelineFingerprint: 'sha256:stale',
          composerVersion: refinedTimelineComposerVersion,
          timelineProjection: const [
            RefinedTimelineSegment(
              segmentId: 'seg_1',
              startSample: 0,
              endSample: 16000,
              refinedText: '不应消费的过期精修',
              fallback: false,
            ),
          ],
        ),
      );

      final canonical = canonicalSessionText(
        timeline: timeline,
        refinement: refinement,
      );

      expect(canonical.availability, TimelineDisplayAvailability.stale);
      expect(canonical.defaultTextLayer, TimelineTextLayer.live);
      expect(canonical.fullText, '实时原文');
      expect(canonical.segments.single.refinedText, isNull);
      expect(canonical.segments.single.textLayer, TimelineTextLayer.live);
    },
  );
}

TimelineItem _transcript(
  String segmentId,
  int startSample,
  int endSample,
  String text,
) => TimelineItem.fromMap({
  'kind': 'transcript',
  'segmentId': segmentId,
  'sampleOffset': startSample,
  'startSample': startSample,
  'endSample': endSample,
  'startMs': startSample * 1000 ~/ 16000,
  'endMs': endSample * 1000 ~/ 16000,
  'text': text,
});
