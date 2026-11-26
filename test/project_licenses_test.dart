import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/project_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline license bundle preserves model terms and logo ownership',
    () async {
      final entries = await loadProjectLicenses().toList();
      final texts = {
        for (final entry in entries)
          entry.packages.single: entry.paragraphs
              .map((paragraph) => paragraph.text)
              .join('\n'),
      };
      expect(texts['MomentAI logo'], contains('Copyright 2026 hohu.org'));
      expect(texts['Zipformer 14M'], contains('Apache License'));
      expect(
        texts['SenseVoice Small'],
        contains('FunASR Model Open Source License Agreement'),
      );
      expect(texts['Pyannote segmentation 3.0'], contains('2023 CNRS'));
      expect(texts['Pyannote segmentation 3.0'], contains('2022 CNRS'));
      expect(texts['3D-Speaker ERes2Net-Base'], contains('Apache License'));
      expect(texts['Native: eigen'], contains('Mozilla Public License'));
      expect(texts['Native: simple-sentencepiece'], contains('Susumu Yata'));
      expect(
        texts['Native: onnxruntime'],
        contains('THIRD PARTY SOFTWARE NOTICES'),
      );
    },
  );
}
