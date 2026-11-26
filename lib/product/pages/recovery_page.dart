import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/session/session_experience_gateway.dart';
import '../../domain/session/session_summary.dart';
import '../../poc/poc_bridge.dart';
import '../ai_services.dart';
import '../app_coordinator.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import 'session_detail_page.dart';

class ProductRecoveryPage extends StatefulWidget {
  const ProductRecoveryPage({
    super.key,
    required this.candidate,
    required this.coordinator,
    required this.gateway,
    this.aiServices,
  });

  final RecoveryCandidate candidate;
  final AppCoordinator coordinator;
  final SessionExperienceGateway gateway;
  final AiServices? aiServices;

  @override
  State<ProductRecoveryPage> createState() => _ProductRecoveryPageState();
}

class _ProductRecoveryPageState extends State<ProductRecoveryPage> {
  RecoveryOutcome? _outcome;
  Object? _error;
  bool _busy = false;
  bool _transcriptionFailed = false;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final candidate = widget.candidate;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.recoverRecording)),
        body: SafeArea(
          top: false,
          child: ListView(
            key: const Key('product-recovery-page'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Icon(
                _outcome?.hasConfirmedGaps == true
                    ? Icons.warning_amber_rounded
                    : Icons.restore_rounded,
                size: 58,
                color: _outcome?.hasConfirmedGaps == true
                    ? ProductColors.amber
                    : ProductColors.forest,
              ),
              const SizedBox(height: 16),
              Text(
                candidate.title.isEmpty
                    ? l10n.unfinishedRecordingFound
                    : candidate.title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.momentaiWillVerifyTheDatabaseContinuousAudio,
                textAlign: TextAlign.center,
                style: TextStyle(color: ProductColors.mutedInk, height: 1.5),
              ),
              const SizedBox(height: 22),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      _RecoveryFact(
                        label: l10n.savedAudio,
                        value: formatDuration(candidate.committedMs),
                      ),
                      const Divider(height: 24),
                      _RecoveryFact(
                        label: l10n.maximumPossibleGap,
                        value: !candidate.rpoKnown
                            ? l10n.unknownCheckAfterRecovery
                            : candidate.rpoMs <= 0
                            ? l10n.noneFoundYet
                            : l10n.aboutMs((candidate.rpoMs).toString()),
                      ),
                      const Divider(height: 24),
                      _RecoveryFact(
                        label: l10n.savedPhotos,
                        value: l10n.photos(
                          (candidate.imageCommittedCount).toString(),
                        ),
                      ),
                      if (candidate.imagePendingCount > 0) ...[
                        const Divider(height: 24),
                        _RecoveryFact(
                          label: l10n.photosToVerify,
                          value: l10n.photos(
                            (candidate.imagePendingCount).toString(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 20),
                Card(
                  color: ProductColors.forestSoft,
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.verifyingOriginalFilesAndCompletingLocalTranscription,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 20),
                Card(
                  color: ProductColors.amberSoft,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _transcriptionFailed
                              ? l10n.audioRecoveredTranscriptionIsIncomplete
                              : l10n.automaticRecoveryIsNotComplete,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _transcriptionFailed
                              ? l10n.savedAudioPhotosAndTimelineAreUnchanged
                              : l10n.originalFilesRemainOnThisDeviceAnd,
                          style: const TextStyle(height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (_transcriptionFailed) ...[
                FilledButton.icon(
                  key: const Key('retry-product-recovery-transcription'),
                  onPressed: _busy ? null : _retryTranscription,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(l10n.retryLocalTranscription),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('view-product-recovery-without-transcript'),
                  onPressed: _busy ? null : () => _openRecovered(true),
                  child: Text(l10n.viewOriginalsFirst),
                ),
              ] else
                FilledButton.icon(
                  key: const Key('recover-product-session'),
                  onPressed: _busy ? null : _recover,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(
                    _error == null
                        ? l10n.recoverAndView
                        : l10n.verifyAndRecoverAgain,
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                l10n.recoveryWillDetermineWhetherTheRecordingIs,
                textAlign: TextAlign.center,
                style: TextStyle(color: ProductColors.mutedInk, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _recover() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _transcriptionFailed = false;
    });
    try {
      _outcome = await widget.coordinator.recoverSession(widget.candidate);
      await widget.gateway.recoverTranscription(
        sessionId: widget.candidate.sessionId,
        directory: widget.candidate.directory,
      );
      await widget.coordinator.refreshSessions();
      if (mounted) await _openRecovered(false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _transcriptionFailed = _outcome != null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryTranscription() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.gateway.recoverTranscription(
        sessionId: widget.candidate.sessionId,
        directory: widget.candidate.directory,
      );
      await widget.coordinator.refreshSessions();
      if (mounted) await _openRecovered(false);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRecovered(bool transcriptionFailed) async {
    SessionSummary? session;
    for (final item in widget.coordinator.sessions) {
      if (item.sessionId == widget.candidate.sessionId) {
        session = item;
        break;
      }
    }
    if (session == null) {
      await widget.coordinator.refreshSessions();
      for (final item in widget.coordinator.sessions) {
        if (item.sessionId == widget.candidate.sessionId) {
          session = item;
          break;
        }
      }
    }
    if (!mounted || session == null) {
      setState(
        () => _error = StateError(l10n.couldNotReadRecoveryResultsTryAgain),
      );
      return;
    }
    await Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => ProductSessionDetailPage(
          session: session!,
          gateway: widget.gateway,
          coordinator: widget.coordinator,
          recoveryOutcome: _outcome,
          recoveryTranscriptionFailed: transcriptionFailed,
          aiServices: widget.aiServices,
        ),
      ),
    );
  }
}

class _RecoveryFact extends StatelessWidget {
  const _RecoveryFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    );
  }
}
