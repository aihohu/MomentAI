import 'package:momentai/l10n/app_localization.dart';

import '../core/ai/ai_models.dart';
import '../domain/session/session_summary.dart';
import '../domain/speaker/speaker_diarization.dart';
import '../domain/timeline/timeline_item.dart';
import '../domain/transcript/refined_full_text.dart';
import 'canonical_session_text.dart';
import 'speaker_session_text.dart';
import 'timeline_display_item.dart';

/// Read-only bridge from the product's canonical text to the shared AI layer.
AiSourceSnapshot sessionAiSource({
  required SessionSummary session,
  required List<TimelineItem> timeline,
  required FullTextRefinementSnapshot refinement,
  SpeakerDiarizationDocument? speakers,
}) {
  if (session.status != SessionStatus.completed &&
      session.status != SessionStatus.completedWithGaps) {
    throw AiFailure(l10n.finishSavingTheRecordingBeforeUsingAi);
  }
  final canonical = canonicalSessionText(
    timeline: timeline,
    refinement: refinement,
  );
  if (speakers != null &&
      (speakers.sessionId != session.sessionId ||
          speakers.sourceAudioSamples != session.durationSamples)) {
    throw AiFailure(l10n.speakerResultsDoNotMatchThisRecording);
  }
  return AiSourceSnapshot(
    sessionId: session.sessionId,
    title: session.title.isEmpty ? '未命名记录' : session.title,
    text: canonical.fullText,
    speakerText: speakers == null
        ? null
        : speakerSessionText(canonical: canonical, document: speakers),
    textLayer: canonical.defaultTextLayer == TimelineTextLayer.refined
        ? (canonical.availability == TimelineDisplayAvailability.partial
              ? '精修文字（部分回退实时原文）'
              : '精修文字')
        : '实时原文',
    hasGaps:
        session.hasConfirmedGaps ||
        session.status == SessionStatus.completedWithGaps,
  );
}
