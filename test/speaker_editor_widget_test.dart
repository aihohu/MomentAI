import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/product/widgets/speaker_editor_sheet.dart';

void main() {
  testWidgets(
    'editor remains usable with large text and keyboard and retains input after save failure',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final save = Completer<String?>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 260),
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => SpeakerEditorSheet(
                    document: _document,
                    speakerId: 'speaker_1',
                    onSave: (_) {
                      calls++;
                      return save.future;
                    },
                  ),
                ),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('speaker-name-input')));
      await tester.enterText(find.byKey(const Key('speaker-name-input')), '小林');
      await tester.ensureVisible(find.byKey(const Key('save-speaker-name')));
      await tester.tap(find.byKey(const Key('save-speaker-name')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-speaker-name')))
            .onPressed,
        isNull,
      );
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      save.complete('修改未保存：存储空间不足。');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('speaker-editor-error')));
      expect(find.text('修改未保存：存储空间不足。'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('speaker-name-input')))
            .controller!
            .text,
        '小林',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-speaker-name')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

const _document = SpeakerDiarizationDocument(
  sessionId: 'session',
  modelId: 'model',
  sourceAudioSamples: 32000,
  sampleRate: 16000,
  sourceChunkFingerprint: 'sha256:test',
  createdAt: 'test',
  segments: [
    SpeakerDiarizationSegment(
      speakerId: 'speaker_1',
      startSample: 0,
      endSample: 16000,
    ),
    SpeakerDiarizationSegment(
      speakerId: 'speaker_2',
      startSample: 16000,
      endSample: 32000,
    ),
  ],
  processingMs: 1,
  realTimeFactor: 0.1,
  peakRssBytes: 1,
  windowCount: 1,
);
