// ignore_for_file: prefer_initializing_formals
import 'package:momentai/l10n/app_localization.dart';

enum LocalModelKind { realtime, refinement, speakerDiarization }

enum LocalModelArtifactFormat { tarBzip2, directFile }

class LocalModelDownloadSource {
  const LocalModelDownloadSource({required String name, required this.uri})
    : _name = name;

  final String _name;
  String get name => localizedModelText(_name);
  final Uri uri;
}

class LocalModelDownloadArtifact {
  const LocalModelDownloadArtifact({
    required this.id,
    required this.fileName,
    required this.byteCount,
    required this.sha256,
    required this.downloadSources,
    this.format = LocalModelArtifactFormat.tarBzip2,
    this.archiveRoot,
    this.installPath,
  });

  final String id;
  final String fileName;
  final int byteCount;
  final String sha256;
  final List<LocalModelDownloadSource> downloadSources;
  final LocalModelArtifactFormat format;
  final String? archiveRoot;
  final String? installPath;
}

class LocalModelFileManifest {
  const LocalModelFileManifest({
    required this.logicalName,
    required this.archivePath,
    required this.byteCount,
    required this.sha256,
    this.assetPath,
    this.artifactId = 'archive',
  });

  final String logicalName;
  final String archivePath;
  final int byteCount;
  final String sha256;
  final String? assetPath;
  final String artifactId;
}

class LocalModelManifest {
  const LocalModelManifest({
    required this.id,
    required this.version,
    required String name,
    required String description,
    required this.kind,
    required List<String> languages,
    required String qualityLabel,
    required this.installedByteCount,
    required this.minimumMemoryBytes,
    required this.license,
    required this.files,
    String? technicalName,
    this.bundled = false,
    this.downloadSources = const [],
    this.archiveByteCount,
    this.archiveSha256,
    this.downloadArtifacts = const [],
  }) : _name = name,
       _description = description,
       _languages = languages,
       _qualityLabel = qualityLabel,
       _technicalName = technicalName;

  final String id;
  final String version;
  final String _name;
  String get name => localizedModelText(_name);
  final String _description;
  String get description => localizedModelText(_description);
  final LocalModelKind kind;
  final List<String> _languages;
  List<String> get languages =>
      _languages.map(localizedModelText).toList(growable: false);
  final String _qualityLabel;
  String get qualityLabel => localizedModelText(_qualityLabel);
  final int installedByteCount;
  final int minimumMemoryBytes;
  final String license;
  final List<LocalModelFileManifest> files;
  final String? _technicalName;
  String? get technicalName =>
      _technicalName == null ? null : localizedModelText(_technicalName);
  final bool bundled;
  final List<LocalModelDownloadSource> downloadSources;
  final int? archiveByteCount;
  final String? archiveSha256;
  final List<LocalModelDownloadArtifact> downloadArtifacts;

  bool get downloadable => !bundled && artifacts.isNotEmpty;

  List<LocalModelDownloadArtifact> get artifacts {
    if (downloadArtifacts.isNotEmpty) return downloadArtifacts;
    final byteCount = archiveByteCount;
    final sha256 = archiveSha256;
    if (downloadSources.isEmpty || byteCount == null || sha256 == null) {
      return const [];
    }
    return [
      LocalModelDownloadArtifact(
        id: 'archive',
        fileName: '$id-$version.tar.bz2',
        byteCount: byteCount,
        sha256: sha256,
        downloadSources: downloadSources,
        archiveRoot: id,
      ),
    ];
  }

  int get downloadByteCount =>
      artifacts.fold(0, (total, artifact) => total + artifact.byteCount);

  String get installationName {
    if (bundled) return '$version-bundled';
    final identity = artifacts
        .map((artifact) => artifact.sha256.substring(0, 8))
        .join('-');
    return '$version-$identity';
  }
}

const lightweightRealtimeModelId =
    'sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23';
const balancedRealtimeModelId =
    'sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30';
const senseVoiceRefinementModelId =
    'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';
const speakerDiarizationModelId =
    'sherpa-onnx-speaker-diarization-pyannote-3dspeaker-int8';

const enhancedRealtimeModelId =
    'sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30';

final class OfficialLocalModelCatalog {
  OfficialLocalModelCatalog._();

  static const schemaVersion = 1;

  static final models = <LocalModelManifest>[
    const LocalModelManifest(
      id: lightweightRealtimeModelId,
      version: '2023-02-23',
      name: '普通话 · 轻量',
      description: '速度优先，体积更小；没有网络也能立即开始记录。',
      kind: LocalModelKind.realtime,
      languages: ['普通话'],
      qualityLabel: '轻量',
      installedByteCount: 30975688,
      minimumMemoryBytes: 1073741824,
      license: 'Apache-2.0',
      bundled: true,
      files: [
        LocalModelFileManifest(
          logicalName: 'encoder',
          archivePath: 'encoder-epoch-99-avg-1.int8.onnx',
          assetPath:
              'assets/$lightweightRealtimeModelId/encoder-epoch-99-avg-1.int8.onnx',
          byteCount: 21621684,
          sha256:
              '1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1',
        ),
        LocalModelFileManifest(
          logicalName: 'decoder',
          archivePath: 'decoder-epoch-99-avg-1.onnx',
          assetPath:
              'assets/$lightweightRealtimeModelId/decoder-epoch-99-avg-1.onnx',
          byteCount: 7509745,
          sha256:
              '5ee0f03a2768ff1d5c83ef3a493243c7935d316cd41280037b14783a3467cc78',
        ),
        LocalModelFileManifest(
          logicalName: 'joiner',
          archivePath: 'joiner-epoch-99-avg-1.int8.onnx',
          assetPath:
              'assets/$lightweightRealtimeModelId/joiner-epoch-99-avg-1.int8.onnx',
          byteCount: 1795562,
          sha256:
              'a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169',
        ),
        LocalModelFileManifest(
          logicalName: 'tokens',
          archivePath: 'tokens.txt',
          assetPath: 'assets/$lightweightRealtimeModelId/tokens.txt',
          byteCount: 48697,
          sha256:
              '8b294db9045d6e5f94647f4c1eec1af4da143a75053c399611444b378ff966ac',
        ),
      ],
    ),
    LocalModelManifest(
      id: senseVoiceRefinementModelId,
      version: '2024-07-17',
      name: '多语种精修',
      description: '录音结束后补全标点、整理段落，并改善中英文混合内容。',
      kind: LocalModelKind.refinement,
      languages: const ['普通话', '英语', '日语', '韩语', '粤语'],
      qualityLabel: '推荐',
      installedByteCount: 239549735,
      minimumMemoryBytes: 2147483648,
      license: 'FunASR model license',
      technicalName: 'SenseVoice Small · 本地运行',
      downloadSources: [
        LocalModelDownloadSource(
          name: 'ModelScope',
          uri: Uri.parse(
            'https://modelscope.cn/api/v1/models/'
            'aihohu/SenseVoiceSmall-ONNX-INT8/repo?Revision=master&'
            'FilePath=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
          ),
        ),
        LocalModelDownloadSource(
          name: 'GitHub',
          uri: Uri.parse(
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
            'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
          ),
        ),
      ],
      archiveByteCount: 163002883,
      archiveSha256:
          '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e',
      files: const [
        LocalModelFileManifest(
          logicalName: 'model',
          archivePath: 'model.int8.onnx',
          byteCount: 239233841,
          sha256:
              'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
        ),
        LocalModelFileManifest(
          logicalName: 'tokens',
          archivePath: 'tokens.txt',
          byteCount: 315894,
          sha256:
              'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
        ),
      ],
    ),
    LocalModelManifest(
      id: speakerDiarizationModelId,
      version: 'pyannote-3.0-3dspeaker-zh-v1',
      name: '本地说话人分割',
      description: '在设备上区分“谁在什么时候说话”，只生成匿名标签，不上传录音。',
      kind: LocalModelKind.speakerDiarization,
      languages: const ['普通话优先', '多语种可用'],
      qualityLabel: '匿名分割',
      installedByteCount: 41134267,
      minimumMemoryBytes: 2147483648,
      license: 'MIT (Pyannote) + Apache-2.0 (3D-Speaker)',
      technicalName: 'Pyannote 3.0 INT8 + 3D-Speaker',
      downloadArtifacts: [
        LocalModelDownloadArtifact(
          id: 'segmentation',
          fileName: 'pyannote-segmentation-3.0-int8.onnx',
          byteCount: 1540506,
          sha256:
              'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d',
          format: LocalModelArtifactFormat.directFile,
          installPath: 'segmentation.int8.onnx',
          downloadSources: [
            LocalModelDownloadSource(
              name: 'Hugging Face 中国镜像',
              uri: Uri.parse(
                'https://hf-mirror.com/csukuangfj/'
                'sherpa-onnx-pyannote-segmentation-3-0/resolve/main/'
                'model.int8.onnx',
              ),
            ),
            LocalModelDownloadSource(
              name: 'Hugging Face',
              uri: Uri.parse(
                'https://huggingface.co/csukuangfj/'
                'sherpa-onnx-pyannote-segmentation-3-0/resolve/main/'
                'model.int8.onnx',
              ),
            ),
          ],
        ),
        LocalModelDownloadArtifact(
          id: 'embedding',
          fileName:
              '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
          byteCount: 39593761,
          sha256:
              '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b',
          format: LocalModelArtifactFormat.directFile,
          installPath: 'embedding.onnx',
          downloadSources: [
            LocalModelDownloadSource(
              name: 'Hugging Face 中国镜像',
              uri: Uri.parse(
                'https://hf-mirror.com/csukuangfj/speaker-embedding-models/'
                'resolve/main/'
                '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
              ),
            ),
            LocalModelDownloadSource(
              name: 'Hugging Face',
              uri: Uri.parse(
                'https://huggingface.co/csukuangfj/speaker-embedding-models/'
                'resolve/main/'
                '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
              ),
            ),
          ],
        ),
      ],
      files: const [
        LocalModelFileManifest(
          logicalName: 'segmentation',
          archivePath: 'segmentation.int8.onnx',
          artifactId: 'segmentation',
          byteCount: 1540506,
          sha256:
              'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d',
        ),
        LocalModelFileManifest(
          logicalName: 'embedding',
          archivePath: 'embedding.onnx',
          artifactId: 'embedding',
          byteCount: 39593761,
          sha256:
              '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b',
        ),
      ],
    ),
  ];
}

String localizedModelText(String value) => switch (value) {
  '普通话 · 轻量' => l10n.mandarinLightweight,
  '速度优先，体积更小；没有网络也能立即开始记录。' => l10n.lightweightDescription,
  '普通话' => l10n.mandarin,
  '轻量' => l10n.lightweight,
  '多语种精修' => l10n.multilingualRefinement,
  '录音结束后补全标点、整理段落，并改善中英文混合内容。' => l10n.refinementDescription,
  '英语' => l10n.languageEn,
  '日语' => l10n.languageJa,
  '韩语' => l10n.languageKo,
  '粤语' => l10n.languageYue,
  '推荐' => l10n.recommended,
  'SenseVoice Small · 本地运行' => l10n.sensevoiceLocal,
  '本地说话人分割' => l10n.localSpeakerDiarization,
  '在设备上区分“谁在什么时候说话”，只生成匿名标签，不上传录音。' => l10n.speakerModelDescription,
  '普通话优先' => l10n.mandarinFirst,
  '多语种可用' => l10n.multilingualAvailable,
  '匿名分割' => l10n.anonymousDiarization,
  'Hugging Face 中国镜像' => l10n.huggingfaceMirror,
  '普通话 · 增强' => l10n.enhancedMandarin,
  '增强' => l10n.enhancedModelQuality,
  '更大模型，适合性能充裕的设备；运行时更占内存和电量。' => l10n.enhancedModelDescription,
  '普通话 · 均衡' => l10n.mandarinBalanced,
  '改善录音过程中的实时文字，适合空间和性能充足的设备。' => l10n.balancedDescription,
  '准确度与速度平衡' => l10n.balancedQuality,
  _ => value,
};
