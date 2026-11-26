class RealtimeModelFiles {
  const RealtimeModelFiles({required this.modelId, required this.paths});

  final String modelId;
  final Map<String, String> paths;
}

class RefinementModelFiles {
  const RefinementModelFiles({
    required this.modelId,
    required this.modelPath,
    required this.tokensPath,
  });

  final String modelId;
  final String modelPath;
  final String tokensPath;
}

class SpeakerDiarizationModelFiles {
  const SpeakerDiarizationModelFiles({
    required this.modelId,
    required this.segmentationPath,
    required this.embeddingPath,
  });

  final String modelId;
  final String segmentationPath;
  final String embeddingPath;
}

abstract interface class LocalModelRuntimeResolver {
  Future<RealtimeModelFiles> activeRealtimeModelFiles();

  Future<RefinementModelFiles?> refinementModelFiles();

  Future<SpeakerDiarizationModelFiles?> speakerDiarizationModelFiles();
}

abstract interface class RealtimeModelRuntimeSwitcher {
  Future<void> switchToRealtimeModel(RealtimeModelFiles candidate);
}
