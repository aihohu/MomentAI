import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/session/session_transfer_gateway.dart';
import '../../domain/session/session_summary.dart';
import '../product_formatters.dart';
import '../product_theme.dart';

class SessionImportPage extends StatefulWidget {
  const SessionImportPage({super.key, required this.gateway});
  final SessionTransferGateway gateway;

  @override
  State<SessionImportPage> createState() => _SessionImportPageState();
}

class _SessionImportPageState extends State<SessionImportPage> {
  SessionImportPreview? _preview;
  Object? _error;
  bool _busy = false;
  bool _committing = false;
  bool _finished = false;

  Future<void> _choose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await widget.gateway.pickImport();
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (preview == null || _busy) return;
    setState(() {
      _busy = true;
      _committing = true;
      _error = null;
    });
    try {
      final session = await widget.gateway.commitImport(
        preview.token,
        asCopy: preview.conflict,
      );
      if (!mounted) return;
      _finished = true;
      setState(() => _busy = false);
      // Rebuild PopScope before requesting pop, including on predictive-back platforms.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop<SessionSummary>(session);
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _preview = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    if (!_finished) {
      unawaited(widget.gateway.cancelImport().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final preview = _preview;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.importRecording)),
        body: SafeArea(
          child: ListView(
            key: const Key('session-import-scroll'),
            padding: const EdgeInsets.all(20),
            children: [
              Text(l10n.chooseAMomentAIExportFromFilesIt),
              const SizedBox(height: 12),
              Text(
                l10n.thisVersionSupportsOriginalUncompressedZipStore,
                style: TextStyle(color: ProductColors.mutedInk, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (_busy) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Text(
                  _committing
                      ? l10n.rebuildingAndSafelySavingTheRecording
                      : l10n.chooseAFileToVerifyItsArchive,
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                OutlinedButton.icon(
                  key: const Key('choose-session-import'),
                  onPressed: _choose,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(
                    preview == null
                        ? l10n.chooseMomentAIFile
                        : l10n.chooseAnotherFile,
                  ),
                ),
                if (preview != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preview.title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.startedEnded(
                              (preview.startedAt).toString(),
                              (preview.stoppedAt).toString(),
                            ),
                          ),
                          Text(
                            l10n.duration(
                              (formatDuration(
                                preview.durationSamples * 1000 ~/ 16000,
                              )).toString(),
                              (formatBytes(preview.archiveBytes)).toString(),
                            ),
                          ),
                          Text(
                            l10n.timelineItems(
                              (preview.timelineItemCount).toString(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            l10n.sourceId((preview.sessionId).toString()),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (preview.hasConfirmedGaps)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        l10n.theOriginalRecordingHasConfirmedGapsThe,
                        style: TextStyle(
                          color: ProductColors.vermilion,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(l10n.importPreservesAudioOriginalRefinedTextAnd),
                  if (preview.conflict)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        l10n.aRecordingWithThisIdAlreadyExists,
                        style: TextStyle(
                          color: ProductColors.amber,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('confirm-session-import'),
                    onPressed: _commit,
                    icon: const Icon(Icons.download_done_rounded),
                    label: Text(
                      preview.conflict
                          ? l10n.saveACopyAndOpen
                          : l10n.importAndOpen,
                    ),
                  ),
                ],
                TextButton(
                  key: const Key('cancel-session-import'),
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    sessionTransferError(_error!),
                    style: const TextStyle(color: ProductColors.vermilion),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
