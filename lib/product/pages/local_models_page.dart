import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/models/local_model_manager.dart';
import '../../core/models/local_model_manifest.dart';
import '../app_coordinator.dart';
import '../product_formatters.dart';
import '../product_theme.dart';

class LocalTranscriptionModelsPage extends StatefulWidget {
  const LocalTranscriptionModelsPage({
    super.key,
    required this.coordinator,
    this.manager,
  });

  final AppCoordinator coordinator;
  final LocalModelManager? manager;

  @override
  State<LocalTranscriptionModelsPage> createState() =>
      _LocalTranscriptionModelsPageState();
}

class _LocalTranscriptionModelsPageState
    extends State<LocalTranscriptionModelsPage> {
  Object? _initializationError;
  late Listenable _listenable;

  @override
  void initState() {
    super.initState();
    _listenable = _mergedListenable();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant LocalTranscriptionModelsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coordinator, widget.coordinator) ||
        !identical(oldWidget.manager, widget.manager)) {
      _listenable = _mergedListenable();
      unawaited(_initialize());
    }
  }

  Listenable _mergedListenable() =>
      Listenable.merge([widget.coordinator, ?widget.manager]);

  Future<void> _initialize() async {
    try {
      await widget.manager?.initialize();
    } catch (error) {
      if (mounted) setState(() => _initializationError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final manager = widget.manager;
    return AnimatedBuilder(
      animation: _listenable,
      builder: (context, _) {
        final snapshot = manager?.snapshot;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.modelCenter)),
          body: snapshot == null
              ? _UnavailableCenter(
                  recording: widget.coordinator.hasActiveCapture,
                )
              : !snapshot.initialized
              ? _LoadingCenter(
                  error: _initializationError,
                  onRetry: _initialize,
                )
              : _buildContent(context, manager!, snapshot),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    LocalModelManager manager,
    LocalModelManagerSnapshot snapshot,
  ) {
    final active = snapshot.stateFor(snapshot.activeRealtimeModelId);
    final refinement = snapshot.stateFor(senseVoiceRefinementModelId);
    final speaker = snapshot.stateFor(speakerDiarizationModelId);
    final realtime = snapshot.models
        .where((state) => state.manifest.kind == LocalModelKind.realtime)
        .toList(growable: false);
    final captureProtected =
        widget.coordinator.hasActiveCapture || widget.coordinator.isBusy;
    final protected =
        captureProtected ||
        snapshot.hasOperation ||
        widget.coordinator.isModelOperationActive;
    final blockedReason = captureProtected
        ? l10n.waitUntilRecordingRecoveryOrTranscriptionFinishes
        : snapshot.hasOperation
        ? l10n.anotherModelOperationIsInProgressPause
        : widget.coordinator.isModelOperationActive
        ? l10n.waitUntilSpeakerAnalysisFinishesBeforeManaging
        : null;
    return ListView(
      key: const Key('local-models-page'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _CurrentModelCard(state: active),
        if (widget.coordinator.hasActiveCapture) ...[
          const SizedBox(height: 12),
          const _RecordingGuard(),
        ],
        if (snapshot.globalMessage != null) ...[
          const SizedBox(height: 12),
          _StatusNotice(message: snapshot.globalMessage!),
        ],
        const SizedBox(height: 26),
        _SectionHeader(
          title: l10n.liveTranscription,
          subtitle: l10n.generateTextWhileRecordingSwitchBetweenInstalled,
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < realtime.length; index++) ...[
          _ModelCard(
            state: realtime[index],
            protected: protected,
            blockedReason: blockedReason,
            onPrimary: () => _runPrimary(manager, realtime[index]),
            onPause: () => manager.pause(realtime[index].manifest.id),
            onVerify: () =>
                _run(() => manager.verify(realtime[index].manifest.id)),
            onRestart: () => _confirmRestart(manager, realtime[index]),
            onRemove: () => _confirmRemove(manager, realtime[index]),
            removalBlockedReason: realtime[index].manifest.bundled
                ? l10n.theBuiltInLightweightModelCannotBe549
                : realtime[index].manifest.id == snapshot.activeRealtimeModelId
                ? l10n.currentlyInUseSwitchModelsFirst
                : protected
                ? l10n.waitForTheCurrentModelOperationTo
                : null,
          ),
          if (index != realtime.length - 1) const SizedBox(height: 12),
        ],
        const SizedBox(height: 26),
        _SectionHeader(
          title: l10n.transcriptRefinement,
          subtitle: l10n.afterRecordingAddPunctuationOrganizeParagraphsAnd,
        ),
        const SizedBox(height: 12),
        if (refinement != null)
          _ModelCard(
            state: refinement,
            protected: protected,
            blockedReason: blockedReason,
            onPrimary: () => _runPrimary(manager, refinement),
            onPause: () => manager.pause(refinement.manifest.id),
            onVerify: () => _run(() => manager.verify(refinement.manifest.id)),
            onRestart: () => _confirmRestart(manager, refinement),
            onRemove: () => _confirmRemove(manager, refinement),
            removalBlockedReason: refinement.manifest.bundled
                ? l10n.builtInModelsCannotBeDeleted
                : protected
                ? l10n.waitForTheCurrentModelOperationTo
                : null,
          ),
        const SizedBox(height: 26),
        _SectionHeader(
          title: l10n.speakerAnalysis,
          subtitle: l10n.distinguishSpeakersInARecordingWithoutIdentifying,
        ),
        const SizedBox(height: 12),
        if (speaker != null)
          _ModelCard(
            state: speaker,
            protected: protected,
            blockedReason: blockedReason,
            onPrimary: () => _runPrimary(manager, speaker),
            onPause: () => manager.pause(speaker.manifest.id),
            onVerify: () => _run(() => manager.verify(speaker.manifest.id)),
            onRestart: () => _confirmRestart(manager, speaker),
            onRemove: () => _confirmRemove(manager, speaker),
            removalBlockedReason: protected
                ? l10n.waitForTheCurrentModelOperationTo
                : null,
          ),
        const SizedBox(height: 20),
        const _PrivacyNote(),
      ],
    );
  }

  Future<void> _runPrimary(
    LocalModelManager manager,
    LocalModelInstallState state,
  ) async {
    if (state.busy) return;
    if (state.installed &&
        state.manifest.kind == LocalModelKind.realtime &&
        state.phase != LocalModelInstallPhase.active) {
      await _run(() => manager.activateRealtime(state.manifest.id));
      return;
    }
    if (state.installed) return;
    if (state.downloadedBytes > 0) {
      await _run(() => manager.download(state.manifest.id));
      return;
    }
    final approved = await _confirmDownload(state.manifest);
    if (approved == true) {
      await _run(() => manager.download(state.manifest.id));
    }
  }

  Future<bool?> _confirmDownload(LocalModelManifest manifest) {
    final sourceNames = manifest.artifacts
        .expand((artifact) => artifact.downloadSources)
        .map((source) => source.name)
        .toSet()
        .join(' → ');
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.download((manifest.name).toString()),
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.downloadSizeAboutInstalledSizeAboutUse(
                  (formatBytes(manifest.downloadByteCount)).toString(),
                  (formatBytes(manifest.installedByteCount)).toString(),
                ),
                style: const TextStyle(height: 1.5),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.sourceVerificationExactSizeShaAndPer(
                  (sourceNames.isEmpty ? l10n.bundledAssets : sourceNames)
                      .toString(),
                  (manifest.downloadArtifacts.isEmpty
                          ? l10n.archive
                          : l10n.downloadFile)
                      .toString(),
                ),
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: Key('confirm-model-download-${manifest.id}'),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(l10n.startDownload),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    LocalModelManager manager,
    LocalModelInstallState state,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.delete563((state.manifest.name).toString())),
        content: Text(l10n.onlyLocalModelFilesWillBeDeleted),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: Key('confirm-model-remove-${state.manifest.id}'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.deleteModel),
          ),
        ],
      ),
    );
    if (approved == true) {
      await _run(() => manager.remove(state.manifest.id));
    }
  }

  Future<void> _confirmRestart(
    LocalModelManager manager,
    LocalModelInstallState state,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.downloadAgain((state.manifest.name).toString())),
        content: Text(
          l10n.thisDeletesOfSavedDownloadProgressAnd(
            (formatBytes(state.downloadedBytes)).toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: Key('confirm-model-restart-${state.manifest.id}'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.startOver),
          ),
        ],
      ),
    );
    if (approved == true) {
      await _run(() => manager.restartDownload(state.manifest.id));
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_operationMessage(error))));
    }
  }
}

class _UnavailableCenter extends StatelessWidget {
  const _UnavailableCenter({required this.recording});

  final bool recording;

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('local-models-page'),
    padding: const EdgeInsets.all(24),
    children: [
      if (recording) ...[const _RecordingGuard(), const SizedBox(height: 16)],
      Text(l10n.modelCenterIsNotConnectedRecordingsAnd),
    ],
  );
}

class _LoadingCenter extends StatelessWidget {
  const _LoadingCenter({required this.error, required this.onRetry});

  final Object? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    if (error == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.couldNotReadLocalModelStatusRecordings),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: Text(l10n.checkAgain)),
          ],
        ),
      ),
    );
  }
}

class _CurrentModelCard extends StatelessWidget {
  const _CurrentModelCard({required this.state});

  final LocalModelInstallState? state;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final manifest = state?.manifest;
    return Container(
      key: const Key('current-local-model'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ProductColors.forest,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.currentLiveTranscriptionModel(
              (manifest?.name ?? l10n.loading).toString(),
            ),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            manifest?.description ?? l10n.checkingLocalModel,
            style: const TextStyle(color: Color(0xFFDCE8E1), height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.verified_rounded, color: Colors.white, size: 18),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.verifiedFullyOfflineFallsBackToThe,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 5),
      Text(
        subtitle,
        style: const TextStyle(color: ProductColors.mutedInk, height: 1.45),
      ),
    ],
  );
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.state,
    required this.protected,
    required this.blockedReason,
    required this.onPrimary,
    required this.onPause,
    required this.onVerify,
    required this.onRestart,
    required this.onRemove,
    required this.removalBlockedReason,
  });

  final LocalModelInstallState state;
  final bool protected;
  final String? blockedReason;
  final VoidCallback onPrimary;
  final VoidCallback onPause;
  final VoidCallback onVerify;
  final VoidCallback onRestart;
  final VoidCallback onRemove;
  final String? removalBlockedReason;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final manifest = state.manifest;
    final downloading = state.phase == LocalModelInstallPhase.downloading;
    final processing =
        state.phase == LocalModelInstallPhase.verifying ||
        state.phase == LocalModelInstallPhase.installing ||
        state.phase == LocalModelInstallPhase.switching ||
        state.phase == LocalModelInstallPhase.removing;
    return Card(
      key: Key('local-model-${manifest.id}'),
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: ProductColors.forestSoft,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(switch (manifest.kind) {
                    LocalModelKind.refinement => Icons.auto_awesome_rounded,
                    LocalModelKind.speakerDiarization =>
                      Icons.record_voice_over_rounded,
                    LocalModelKind.realtime => Icons.graphic_eq_rounded,
                  }, color: ProductColors.forest),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        manifest.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      if (manifest.technicalName != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          manifest.technicalName!,
                          style: const TextStyle(
                            color: ProductColors.forest,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        manifest.description,
                        style: const TextStyle(
                          color: ProductColors.mutedInk,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (state.installed)
                  PopupMenuButton<String>(
                    key: Key('model-actions-${manifest.id}'),
                    tooltip: l10n.modelActions,
                    onSelected: (value) {
                      if (value == 'verify') onVerify();
                      if (value == 'remove') onRemove();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'verify',
                        enabled: !protected,
                        child: Text(
                          protected
                              ? l10n.verifyAgainOperationInProgress
                              : l10n.verifyAgain,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        enabled: removalBlockedReason == null,
                        child: Text(
                          removalBlockedReason == null
                              ? l10n.deleteModel
                              : l10n.deleteModel587(
                                  (removalBlockedReason).toString(),
                                ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 13),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _ModelTag(
                  label: manifest.bundled
                      ? l10n.builtIn(
                          (formatBytes(manifest.installedByteCount)).toString(),
                        )
                      : l10n.download(
                          (formatBytes(manifest.downloadByteCount)).toString(),
                        ),
                ),
                _ModelTag(label: manifest.qualityLabel),
                _ModelTag(label: manifest.languages.join(' / ')),
              ],
            ),
            if (downloading ||
                state.downloadedBytes > 0 && !state.installed) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: processing ? null : state.progress,
              ),
              const SizedBox(height: 6),
              Text(
                '${formatBytes(state.downloadedBytes)} / ${formatBytes(state.totalBytes)}',
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 12,
                ),
              ),
              if (downloading) ...[
                const SizedBox(height: 3),
                Text(
                  _downloadTransferLabel(state),
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
            if (state.message != null) ...[
              const SizedBox(height: 10),
              Text(
                state.message!,
                style: TextStyle(
                  color: state.phase == LocalModelInstallPhase.failed
                      ? ProductColors.vermilion
                      : ProductColors.forest,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: downloading
                  ? OutlinedButton.icon(
                      key: Key('pause-model-${manifest.id}'),
                      onPressed: onPause,
                      icon: const Icon(Icons.pause_rounded),
                      label: Text(l10n.pauseDownload),
                    )
                  : processing
                  ? FilledButton.tonalIcon(
                      onPressed: null,
                      icon: const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      label: Text(
                        state.phase == LocalModelInstallPhase.verifying
                            ? l10n.verifying
                            : state.phase == LocalModelInstallPhase.switching
                            ? l10n.switchingRealtimeModel
                            : state.phase == LocalModelInstallPhase.removing
                            ? l10n.deleting
                            : l10n.installing,
                      ),
                    )
                  : FilledButton.tonal(
                      key: Key('primary-model-${manifest.id}'),
                      onPressed: protected
                          ? null
                          : state.phase == LocalModelInstallPhase.active
                          ? null
                          : onPrimary,
                      child: Text(_primaryLabel(state)),
                    ),
            ),
            if (!state.installed &&
                !state.busy &&
                state.downloadedBytes > 0) ...[
              const SizedBox(height: 6),
              TextButton(
                key: Key('restart-model-${manifest.id}'),
                onPressed: protected ? null : onRestart,
                child: Text(l10n.deleteProgressAndStartOver),
              ),
            ],
            if (protected && !state.busy && blockedReason != null) ...[
              const SizedBox(height: 8),
              Text(
                blockedReason!,
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelTag extends StatelessWidget {
  const _ModelTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: ProductColors.forestSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: ProductColors.forest,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _RecordingGuard extends StatelessWidget {
  const _RecordingGuard();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ProductColors.amberSoft,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.fiber_manual_record, size: 18, color: ProductColors.amber),
        SizedBox(width: 9),
        Expanded(
          child: Text(
            l10n.recordingOrTranscriptionIsInProgressWait,
            style: TextStyle(
              color: ProductColors.amber,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class _StatusNotice extends StatelessWidget {
  const _StatusNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ProductColors.forestSoft,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline_rounded, color: ProductColors.forest),
        const SizedBox(width: 9),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: ProductColors.forestSoft,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, color: ProductColors.forest),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            l10n.onlyModelFilesAreDownloadedRecordingsPhotos,
            style: TextStyle(
              color: ProductColors.forest,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

String _primaryLabel(LocalModelInstallState state) {
  if (state.phase == LocalModelInstallPhase.active) return l10n.inUse;
  if (state.installed && state.manifest.kind == LocalModelKind.realtime) {
    return l10n.useThisModel;
  }
  if (state.installed) return l10n.installed;
  if (state.phase == LocalModelInstallPhase.paused ||
      state.downloadedBytes > 0) {
    return l10n.resumeDownload;
  }
  if (state.phase == LocalModelInstallPhase.failed) return l10n.retry;
  return l10n.download599;
}

String _downloadTransferLabel(LocalModelInstallState state) {
  final resume = state.resumedFromBytes > 0
      ? l10n.resumingFrom((formatBytes(state.resumedFromBytes)).toString())
      : '';
  final speed = state.bytesPerSecond;
  if (speed <= 0) return l10n.measuringSpeed((resume).toString());
  final remaining = (state.totalBytes - state.downloadedBytes).clamp(
    0,
    state.totalBytes,
  );
  final seconds = (remaining / speed).ceil();
  final eta = seconds < 60
      ? l10n.aboutSec((seconds).toString())
      : seconds < 3600
      ? l10n.aboutMin(((seconds / 60).ceil()).toString())
      : l10n.aboutHr(((seconds / 3600).ceil()).toString());
  return l10n.sRemaining(
    (resume).toString(),
    (formatBytes(speed.round())).toString(),
    (eta).toString(),
  );
}

String _operationMessage(Object error) => switch (error) {
  LocalModelOperationException value => value.message,
  _ => '$error',
};

String productModelName(String modelId) {
  if (modelId.isEmpty) return l10n.loading;
  if (modelId == balancedRealtimeModelId ||
      modelId.contains('zipformer-zh-int8-2025-06-30')) {
    return l10n.mandarinBalanced;
  }
  if (modelId == lightweightRealtimeModelId ||
      modelId.contains('zipformer-zh-14M')) {
    return l10n.mandarinLightweightBuiltIn;
  }
  return l10n.installedLocalModel;
}

String productModelDescription(String modelId) {
  if (modelId == balancedRealtimeModelId ||
      modelId.contains('zipformer-zh-int8-2025-06-30')) {
    return l10n.mandarinBalancedAccuracyAndSpeedFullyOffline;
  }
  if (modelId == lightweightRealtimeModelId ||
      modelId.contains('zipformer-zh-14M')) {
    return l10n.mandarinSpeedFirstFullyOfflineTranscription;
  }
  return l10n.onDeviceTranscriptionRecordingsAreNotUploaded;
}
