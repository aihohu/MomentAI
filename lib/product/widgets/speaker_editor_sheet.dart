import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/speaker/speaker_diarization.dart';
import '../product_theme.dart';
import '../speaker_localization.dart';

class SpeakerEditorSheet extends StatefulWidget {
  const SpeakerEditorSheet({
    super.key,
    required this.document,
    required this.speakerId,
    required this.onSave,
  });

  final SpeakerDiarizationDocument document;
  final String speakerId;
  final Future<String?> Function(SpeakerEdit edit) onSave;

  @override
  State<SpeakerEditorSheet> createState() => _SpeakerEditorSheetState();
}

class _SpeakerEditorSheetState extends State<SpeakerEditorSheet> {
  late final _name = TextEditingController(
    text: widget.document.labels.names[widget.speakerId] ?? '',
  );
  String? _targetId;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save(SpeakerEdit edit) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onSave(edit);
    } catch (_) {
      error = l10n.changesWereNotSavedTryAgainShortly;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
    if (error == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final document = widget.document;
    final others = document.speakerIds.where((id) => id != widget.speakerId);
    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.manageSpeakers,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.namesApplyOnlyToThisRecordingClear,
                style: TextStyle(color: ProductColors.mutedInk),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('speaker-name-input'),
                controller: _name,
                enabled: !_saving,
                maxLength: 40,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l10n.speakerName,
                  hintText: localizedSpeakerDefault(widget.speakerId),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) =>
                    _save(SpeakerEdit.rename(widget.speakerId, _name.text)),
              ),
              FilledButton(
                key: const Key('save-speaker-name'),
                onPressed: _saving
                    ? null
                    : () => _save(
                        SpeakerEdit.rename(widget.speakerId, _name.text),
                      ),
                child: Text(l10n.saveName),
              ),
              if (others.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  l10n.mergeDuplicateSpeakers,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.ifIsTheSamePersonAsAnother(
                    (localizedSpeakerName(
                      document,
                      widget.speakerId,
                    )).toString(),
                  ),
                  style: const TextStyle(
                    color: ProductColors.mutedInk,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('speaker-merge-target'),
                  initialValue: _targetId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.mergeInto,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final id in others)
                      DropdownMenuItem(
                        value: id,
                        enabled: document.canMergeSpeakers(
                          widget.speakerId,
                          id,
                        ),
                        child: Text(
                          document.canMergeSpeakers(widget.speakerId, id)
                              ? localizedSpeakerName(document, id)
                              : l10n.overlapDetected(
                                  (localizedSpeakerName(
                                    document,
                                    id,
                                  )).toString(),
                                ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (id) => setState(() => _targetId = id),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.speakersWithOverlappingSpeechCannotBeMerged,
                  style: TextStyle(color: ProductColors.mutedInk, fontSize: 12),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  key: const Key('merge-speakers'),
                  onPressed: _saving || _targetId == null
                      ? null
                      : () => _save(
                          SpeakerEdit.merge(widget.speakerId, _targetId!),
                        ),
                  child: Text(l10n.mergeIntoSelectedSpeaker),
                ),
              ],
              if (_saving) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('speaker-editor-error'),
                  style: const TextStyle(color: ProductColors.vermilion),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
