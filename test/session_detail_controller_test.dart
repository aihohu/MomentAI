import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/session/session_experience_gateway.dart';
import 'package:momentai/domain/audio/playback_snapshot.dart';
import 'package:momentai/domain/session/session_summary.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/product/session_detail_controller.dart';

void main() {
  for (final fail in [false, true]) {
    test(
      'dispose stops pending playback before the next page starts (failure=$fail)',
      () async {
        final gateway = _DelayedPlaybackGateway();
        final controller = SessionDetailController(
          session: SessionSummary.fromMap({
            'sessionId': 's',
            'directory': '/s',
            'state': 'completed',
          }),
          gateway: gateway,
        );
        final pending = controller.togglePlayback();
        expect(gateway.commands, ['play:/s']);
        controller.dispose();
        expect(gateway.commands, ['play:/s', 'stop']);
        await gateway.startPlayback('/next');
        if (fail) {
          gateway.started.completeError(StateError('late native failure'));
        } else {
          gateway.started.complete(
            PlaybackSnapshot.fromMap({
              'state': 'playing',
              'directory': '/s',
              'sessionId': 's',
            }),
          );
        }
        await pending;
        expect(gateway.commands, ['play:/s', 'stop', 'play:/next']);
        expect(controller.playback.isIdle, isTrue);
      },
    );
  }

  test('disposing an unused detail does not stop another player', () {
    final gateway = _DelayedPlaybackGateway();
    SessionDetailController(
      session: SessionSummary.fromMap({
        'sessionId': 's',
        'directory': '/s',
        'state': 'completed',
      }),
      gateway: gateway,
    ).dispose();
    expect(gateway.commands, isEmpty);
  });

  test(
    'sound changes coalesce and failed writes restore the last saved value',
    () async {
      final gateway = _PollingGateway();
      final controller = SessionDetailController(
        session: SessionSummary.fromMap({
          'sessionId': 's',
          'directory': '/s',
          'state': 'completed',
        }),
        gateway: gateway,
      );
      await controller.loadPlaybackSound();
      gateway.soundGate = Completer<void>();
      final first = controller.setPlaybackSound(
        const PlaybackSoundSettings(volume: 0.2),
      );
      await controller.setPlaybackSound(
        const PlaybackSoundSettings(volume: 0.5),
      );
      await controller.setPlaybackSound(
        const PlaybackSoundSettings(volume: 0.8, enhanced: true),
      );
      expect(controller.playbackSound.volume, 0.8);
      gateway.soundGate!.complete();
      await first;
      expect(gateway.soundWrites.map((s) => s.volume), [0.2, 0.8]);
      expect(gateway.savedSound.enhanced, isTrue);
      gateway.failSound = true;
      await controller.setPlaybackSound(const PlaybackSoundSettings(volume: 0));
      expect(controller.soundError, isNotNull);
      expect(controller.playbackSound.volume, 0.8);
      expect(controller.playbackSound.enhanced, isTrue);
      controller.dispose();
      final next = SessionDetailController(
        session: controller.session,
        gateway: gateway,
      );
      await next.loadPlaybackSound();
      expect(next.playbackSound.volume, 0.8);
      next.dispose();
    },
  );

  test(
    'background polls retain loaded empty states and join in-flight reads',
    () async {
      final gateway = _PollingGateway();
      final controller = SessionDetailController(
        session: SessionSummary.fromMap({
          'sessionId': 's',
          'directory': '/s',
          'state': 'completed',
        }),
        gateway: gateway,
      );
      await controller.refreshContent();
      final loading = <bool>[];
      controller.addListener(
        () => loading.add(
          controller.loadingTimeline ||
              controller.loadingFullTextRefinement ||
              controller.loadingSpeakerDiarization,
        ),
      );
      gateway.gate = Completer<void>();
      final first = controller.refreshContent();
      final second = controller.refreshContent();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.timelineCalls, 2);
      expect(gateway.refinementCalls, 2);
      expect(gateway.speakerCalls, 2);
      expect(loading, everyElement(false));
      gateway.gate!.complete();
      await Future.wait([first, second]);
      expect(loading, everyElement(false));
      controller.dispose();
    },
  );

  test('position sample resolves the latest entered timeline item', () {
    final timeline = [
      _item('first', 16000),
      _item('second', 32000),
      _item('same_sample_first', 48000),
      _item('same_sample_last', 48000),
      _item('final', 80000),
    ];

    expect(timelineItemAtSample(timeline, 0), isNull);
    expect(timelineItemAtSample(timeline, 16000)?.playbackId, 'first');
    expect(timelineItemAtSample(timeline, 31999)?.playbackId, 'first');
    expect(timelineItemAtSample(timeline, 32000)?.playbackId, 'second');
    expect(
      timelineItemAtSample(timeline, 48000)?.playbackId,
      'same_sample_last',
    );
    expect(
      timelineItemAtSample(timeline, 79999)?.playbackId,
      'same_sample_last',
    );
    expect(timelineItemAtSample(timeline, 100000)?.playbackId, 'final');
  });
}

TimelineItem _item(String id, int sampleOffset) => TimelineItem.fromMap({
  'kind': 'transcript',
  'segmentId': id,
  'sampleOffset': sampleOffset,
  'endSample': sampleOffset + 16000,
  'text': id,
});

class _PollingGateway implements SessionExperienceGateway {
  PlaybackSoundSettings savedSound = const PlaybackSoundSettings();
  final soundWrites = <PlaybackSoundSettings>[];
  Completer<void>? soundGate;
  bool failSound = false;
  @override
  Future<PlaybackSoundSettings> getPlaybackSound() async => savedSound;
  @override
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  ) async {
    soundWrites.add(settings);
    await soundGate?.future;
    if (failSound) throw StateError('Sound update failed');
    return savedSound = settings;
  }

  Completer<void>? gate;
  var timelineCalls = 0;
  var refinementCalls = 0;
  var speakerCalls = 0;
  @override
  Future<List<TimelineItem>> timeline(String directory) async {
    timelineCalls++;
    await gate?.future;
    return [];
  }

  @override
  Future<FullTextRefinementSnapshot> fullTextRefinement(
    String directory,
  ) async {
    refinementCalls++;
    await gate?.future;
    return const FullTextRefinementSnapshot.unavailable();
  }

  @override
  Future<SpeakerDiarizationSnapshot> speakerDiarization(
    String directory,
  ) async {
    speakerCalls++;
    await gate?.future;
    return const SpeakerDiarizationSnapshot.unavailable();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedPlaybackGateway extends _PollingGateway {
  final started = Completer<PlaybackSnapshot>();
  final commands = <String>[];

  @override
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    int sampleOffset = 0,
    String anchorId = '',
    String anchorType = '',
  }) {
    commands.add('play:$directory');
    return directory == '/s'
        ? started.future
        : Future.value(PlaybackSnapshot.idle());
  }

  @override
  Future<PlaybackSnapshot> stopPlayback() async {
    commands.add('stop');
    return PlaybackSnapshot.idle();
  }
}
