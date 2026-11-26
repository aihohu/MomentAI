import '../domain/speaker/speaker_diarization.dart';
import '../l10n/app_localization.dart';
import 'speaker_session_text.dart';

String localizedSpeakerDefault(String id) {
  final number = RegExp(r'^speaker_(\d+)$').firstMatch(id)?.group(1);
  return number == null ? l10n.speakerDefault : l10n.speakerNumber(number);
}

String localizedSpeakerName(SpeakerDiarizationDocument document, String id) {
  final resolved = document.labels.resolve(id);
  return document.labels.names[resolved] ?? localizedSpeakerDefault(resolved);
}

/// A presentation copy: canonical attribution and its hash remain unchanged.
Map<String, Object?> localizedSpeakerAttribution({
  required SpeakerDiarizationDocument document,
  required int startSample,
  required int endSample,
  List<SpeakerDiarizationSegment>? effectiveSegments,
}) {
  final result = speakerTextAttribution(
    document: document,
    startSample: startSample,
    endSample: endSample,
    effectiveSegments: effectiveSegments,
  );
  final names = (result['speakerIds'] as List<String>)
      .map((id) => localizedSpeakerName(document, id))
      .toList();
  final joined = names.join(l10n.localeName == 'zh' ? '、' : ', ');
  return {
    ...result,
    'displayNames': names,
    'label': switch (result['attribution']) {
      'single' => names.single,
      'multiple' => l10n.speakerMultiple(joined),
      'overlap' => l10n.speakerOverlap(joined),
      'uncertain' => l10n.speakerUncertain(joined),
      _ => l10n.speakerUnknown,
    },
  };
}
