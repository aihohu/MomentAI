import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/models/local_model_manager.dart';
import '../../core/models/local_model_manifest.dart';
import '../../core/system/product_system_gateway.dart';
import '../../domain/session/session_summary.dart';
import '../../poc/poc_bridge.dart';
import '../app_coordinator.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import '../widgets/session_summary_card.dart';

class ProductHomePage extends StatefulWidget {
  const ProductHomePage({
    super.key,
    required this.coordinator,
    required this.onOpenCapture,
    required this.onOpenRecords,
    required this.onOpenSession,
    required this.onOpenRecovery,
    required this.onOpenSettings,
    required this.onOpenModels,
    this.localModelManager,
    this.active = true,
  });

  final AppCoordinator coordinator;
  final VoidCallback onOpenCapture;
  final VoidCallback onOpenRecords;
  final ValueChanged<SessionSummary> onOpenSession;
  final ValueChanged<RecoveryCandidate> onOpenRecovery;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenModels;
  final LocalModelManager? localModelManager;
  final bool active;

  @override
  State<ProductHomePage> createState() => _ProductHomePageState();
}

class _ProductHomePageState extends State<ProductHomePage> {
  var _refinementDialogScheduled = false;
  var _refinementDialogHandled = false;

  AppCoordinator get coordinator => widget.coordinator;
  VoidCallback get onOpenCapture => widget.onOpenCapture;
  VoidCallback get onOpenRecords => widget.onOpenRecords;
  ValueChanged<SessionSummary> get onOpenSession => widget.onOpenSession;
  ValueChanged<RecoveryCandidate> get onOpenRecovery => widget.onOpenRecovery;
  VoidCallback get onOpenSettings => widget.onOpenSettings;
  VoidCallback get onOpenModels => widget.onOpenModels;
  LocalModelManager? get localModelManager => widget.localModelManager;

  @override
  void didUpdateWidget(covariant ProductHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localModelManager != widget.localModelManager) {
      _refinementDialogScheduled = false;
      _refinementDialogHandled = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final animation = localModelManager == null
        ? coordinator
        : Listenable.merge([coordinator, localModelManager!]);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        if (coordinator.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        final activeId = coordinator.capture.sessionId;
        final recent = coordinator.sessions
            .where((session) => session.sessionId != activeId)
            .take(3)
            .toList(growable: false);
        final modelSnapshot = localModelManager?.snapshot;
        final refinement = modelSnapshot?.stateFor(senseVoiceRefinementModelId);
        final showRefinementSuggestion =
            modelSnapshot?.shouldSuggestRefinementDownload == true &&
            modelSnapshot?.hasOperation != true &&
            !coordinator.hasActiveCapture &&
            !coordinator.isBusy &&
            coordinator.recoveryCandidates.isEmpty;
        if (showRefinementSuggestion && refinement != null) {
          _scheduleRefinementDialog();
        }
        return Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: coordinator.refresh,
                child: ListView(
                  key: const PageStorageKey('product-home'),
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  children: [
                    const _BrandHeader(),
                    const SizedBox(height: 10),
                    Text(
                      l10n.captureTheMomentAnIdeaHappens,
                      style: TextStyle(
                        color: ProductColors.mutedInk,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (coordinator.error != null) ...[
                      _ErrorBanner(
                        onRetry: coordinator.refresh,
                        onDismiss: coordinator.clearError,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (coordinator.recoveryCandidates.isNotEmpty) ...[
                      _RecoveryCard(
                        candidate: coordinator.recoveryCandidates.first,
                        busy: coordinator.isBusy,
                        additionalCount:
                            coordinator.recoveryCandidates.length - 1,
                        onRecover: () => onOpenRecovery(
                          coordinator.recoveryCandidates.first,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (coordinator.hasActiveCapture) ...[
                      _ActiveCaptureCard(snapshot: coordinator.capture),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.recentRecordings,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (coordinator.sessions.length > recent.length)
                          TextButton(
                            onPressed: onOpenRecords,
                            child: Text(l10n.viewAll),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (recent.isEmpty)
                      const _EmptyRecent()
                    else
                      ...recent.expand(
                        (session) => [
                          SessionSummaryCard(
                            session: session,
                            onTap: () => onOpenSession(session),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FloatingActionButton.extended(
                  key: const Key('product-primary-action'),
                  heroTag: 'product-home-record',
                  backgroundColor: ProductColors.forest,
                  foregroundColor: Colors.white,
                  onPressed:
                      coordinator.isBusy || coordinator.requestingPermission
                      ? null
                      : coordinator.hasActiveCapture
                      ? onOpenCapture
                      : () => _beginRecording(context),
                  icon: Icon(
                    coordinator.hasActiveCapture
                        ? Icons.arrow_forward_rounded
                        : Icons.mic_rounded,
                  ),
                  label: Text(
                    coordinator.capture.isUserPaused
                        ? l10n.returnToRecording
                        : coordinator.hasActiveCapture
                        ? l10n.keepRecording
                        : l10n.startRecording,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _beginRecording(BuildContext context) async {
    if (!coordinator.storage.canStartRecording) {
      final openRecords = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.notEnoughStorageToStart),
          content: Text(
            l10n.thisDeviceHasFreeAtLeastIs(
              (formatBytes(coordinator.storage.availableBytes)).toString(),
              (formatBytes(
                coordinator.storage.minimumRequiredBytes,
              )).toString(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.later),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.viewRecordings),
            ),
          ],
        ),
      );
      if (openRecords == true) onOpenRecords();
      return;
    }

    try {
      await coordinator.startRecording(defaultSessionTitle(DateTime.now()));
      if (context.mounted && coordinator.hasActiveCapture) onOpenCapture();
    } catch (error) {
      if (!context.mounted) return;
      final modelBusy = coordinator.isModelOperationActive;
      final permissionError = error is ProductPermissionException
          ? error
          : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          content: Text(
            modelBusy
                ? l10n.aModelIsDownloadingVerifyingInstallingOr748
                : permissionError?.message ??
                      (error is UnsupportedError
                          ? l10n.recordingIsNotSupportedOnThisDevice
                          : l10n.couldNotStartRecordingTryAgainShortly),
          ),
          action: modelBusy
              ? SnackBarAction(label: l10n.viewModels, onPressed: onOpenModels)
              : permissionError != null
              ? SnackBarAction(
                  label: l10n.viewPermissions,
                  onPressed: onOpenSettings,
                )
              : null,
        ),
      );
    }
  }

  Future<void> _dismissRefinementSuggestion(
    BuildContext context,
    LocalModelManager manager,
  ) async {
    try {
      await manager.dismissRefinementSuggestion();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.couldNotSaveTheReminderPreferenceTry)),
      );
    }
  }

  void _scheduleRefinementDialog() {
    if (_refinementDialogScheduled || _refinementDialogHandled) return;
    _refinementDialogScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refinementDialogScheduled = false;
      if (!mounted || _refinementDialogHandled) return;
      final manager = localModelManager;
      final currentSnapshot = manager?.snapshot;
      final currentRefinement = currentSnapshot?.stateFor(
        senseVoiceRefinementModelId,
      );
      final canShow =
          widget.active &&
          ModalRoute.of(context)?.isCurrent == true &&
          !coordinator.isLoading &&
          !coordinator.isBusy &&
          !coordinator.hasActiveCapture &&
          coordinator.recoveryCandidates.isEmpty &&
          currentSnapshot?.shouldSuggestRefinementDownload == true &&
          currentSnapshot?.hasOperation != true &&
          currentRefinement != null;
      if (!canShow) return;
      _refinementDialogHandled = true;
      unawaited(_showRefinementDialog(currentRefinement));
    });
  }

  Future<void> _showRefinementDialog(LocalModelInstallState refinement) async {
    final continuing = refinement.downloadedBytes > 0;
    final result = await showDialog<_RefinementDialogAction>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        key: const Key('refinement-model-suggestion-dialog'),
        icon: const Icon(
          Icons.auto_awesome_rounded,
          color: ProductColors.forest,
        ),
        title: Text(
          continuing
              ? l10n.continueInstallingRefinement
              : l10n.installTranscriptRefinement,
        ),
        content: Text(
          continuing
              ? l10n.downloadProgressSavedContinueInstallingMultilingualRefinement(
                  (formatBytes(refinement.downloadedBytes)).toString(),
                )
              : l10n.installMultilingualRefinementToAddPunctuationAnd(
                  (formatBytes(refinement.totalBytes)).toString(),
                ),
        ),
        actions: [
          TextButton(
            key: const Key('dismiss-refinement-suggestion'),
            onPressed: () =>
                Navigator.pop(dialogContext, _RefinementDialogAction.later),
            child: Text(l10n.later),
          ),
          FilledButton(
            key: const Key('open-refinement-model'),
            onPressed: () => Navigator.pop(
              dialogContext,
              _RefinementDialogAction.openModels,
            ),
            child: Text(continuing ? l10n.resumeDownload : l10n.viewModels),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (result) {
      case _RefinementDialogAction.later:
        final manager = localModelManager;
        if (manager != null) {
          await _dismissRefinementSuggestion(context, manager);
        }
        break;
      case _RefinementDialogAction.openModels:
        onOpenModels();
        break;
      case null:
        break;
    }
  }
}

enum _RefinementDialogAction { later, openModels }

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    context.strings;
    return Wrap(
      spacing: 16,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          l10n.momentai,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: ProductColors.ink,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: ProductColors.forestSoft,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lock_outline_rounded,
                size: 15,
                color: ProductColors.forest,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  l10n.localMode,
                  style: const TextStyle(
                    color: ProductColors.forest,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActiveCaptureCard extends StatelessWidget {
  const _ActiveCaptureCard({required this.snapshot});

  final PoCSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final interrupted = snapshot.state == 'interrupted';
    final paused = snapshot.state == 'paused';
    return Card(
      color: interrupted
          ? ProductColors.amberSoft
          : paused
          ? ProductColors.forestSoft
          : ProductColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(
                  interrupted
                      ? Icons.warning_amber_rounded
                      : paused
                      ? Icons.pause_circle_outline_rounded
                      : Icons.fiber_manual_record,
                  size: 18,
                  color: interrupted
                      ? ProductColors.amber
                      : paused
                      ? ProductColors.forest
                      : ProductColors.vermilion,
                ),
                Text(
                  interrupted
                      ? l10n.recordingInterrupted
                      : paused
                      ? l10n.recordingPaused
                      : l10n.recording519,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  formatDuration(snapshot.capturedMs),
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              paused
                  ? l10n.audioPositionMicrophoneStopped(
                      (formatDuration(snapshot.committedMs)).toString(),
                    )
                  : l10n.safelySavedThroughAboutMsBehind(
                      (formatDuration(snapshot.committedMs)).toString(),
                      (snapshot.rpoMs).toString(),
                    ),
              style: TextStyle(
                color: interrupted ? ProductColors.amber : ProductColors.forest,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryCard extends StatelessWidget {
  const _RecoveryCard({
    required this.candidate,
    required this.busy,
    required this.onRecover,
    required this.additionalCount,
  });

  final RecoveryCandidate candidate;
  final bool busy;
  final VoidCallback onRecover;
  final int additionalCount;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Card(
      color: ProductColors.amberSoft,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.restore_rounded, color: ProductColors.amber),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.unfinishedRecordingFound,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    l10n.preserved762(
                      (formatDuration(candidate.committedMs)).toString(),
                      (additionalCount > 0
                              ? l10n.more((additionalCount).toString())
                              : '')
                          .toString(),
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : onRecover,
              child: Text(l10n.viewAndRecover),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.onRetry, required this.onDismiss});

  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Material(
      color: ProductColors.amberSoft,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            const Icon(Icons.sync_problem_rounded, color: ProductColors.amber),
            const SizedBox(width: 10),
            Expanded(child: Text(l10n.someLocalDataCouldNotBeRead)),
            TextButton(onPressed: onRetry, child: Text(l10n.retry)),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
              tooltip: l10n.close,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRecent extends StatelessWidget {
  const _EmptyRecent();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        child: Column(
          children: [
            const Icon(
              Icons.graphic_eq_rounded,
              size: 34,
              color: ProductColors.forest,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.noRecordingsYet,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(l10n.yourFirstCompletedRecordingWillAppearHere),
          ],
        ),
      ),
    );
  }
}
