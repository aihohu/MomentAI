import 'package:flutter/material.dart';

import '../../domain/audio/playback_snapshot.dart';
import '../../l10n/app_localization.dart';
import '../session_detail_controller.dart';

class PlaybackSoundSheet extends StatelessWidget {
  const PlaybackSoundSheet({super.key, required this.controller});

  final SessionDetailController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final strings = context.strings;
      final settings = controller.playbackSound;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.playbackVolume,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text('${(settings.volume * 100).round()}%'),
                ],
              ),
              Text(strings.playbackVolumeHint),
              Slider(
                key: const Key('playback-volume-slider'),
                value: settings.volume,
                divisions: 100,
                label: '${(settings.volume * 100).round()}%',
                semanticFormatterCallback: (value) =>
                    '${(value * 100).round()}%',
                onChanged: controller.soundLoading
                    ? null
                    : (value) => controller.setPlaybackSound(
                        PlaybackSoundSettings(
                          volume: value,
                          enhanced: settings.enhanced,
                        ),
                      ),
              ),
              SwitchListTile.adaptive(
                key: const Key('playback-enhancement-switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(strings.playbackEnhancement),
                subtitle: Text(strings.playbackEnhancementHint),
                value: settings.enhanced,
                onChanged: controller.soundLoading
                    ? null
                    : (value) => controller.setPlaybackSound(
                        PlaybackSoundSettings(
                          volume: settings.volume,
                          enhanced: value,
                        ),
                      ),
              ),
              if (controller.soundError != null) ...[
                Text(
                  strings.playbackSoundError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: controller.soundSaving || controller.soundLoading
                      ? null
                      : controller.loadPlaybackSound,
                  child: Text(strings.playbackSoundRetry),
                ),
              ],
              TextButton(
                key: const Key('playback-sound-reset'),
                onPressed: controller.soundLoading
                    ? null
                    : () => controller.setPlaybackSound(
                        const PlaybackSoundSettings(),
                      ),
                child: Text(strings.playbackSoundReset),
              ),
            ],
          ),
        ),
      );
    },
  );
}
