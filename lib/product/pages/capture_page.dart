import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../domain/timeline/timeline_item.dart';
import '../../poc/poc_bridge.dart';
import '../app_coordinator.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import '../widgets/product_timeline_card.dart';
import '../widgets/record_content_view.dart';

class ProductCapturePage extends StatefulWidget {
  const ProductCapturePage({
    super.key,
    required this.coordinator,
    this.onOpenDetails,
  });

  final AppCoordinator coordinator;
  final Future<void> Function(String sessionId)? onOpenDetails;

  @override
  State<ProductCapturePage> createState() => _ProductCapturePageState();
}

class _ProductCapturePageState extends State<ProductCapturePage> {
  static const _timelineTailThreshold = 24.0;

  Timer? _timelineTimer;
  final _captureScrollController = ScrollController();
  var _allowPop = false;
  var _selectedView = RecordContentView.timeline;
  var _followTimelineTail = true;
  var _userDraggingTimeline = false;
  var _lastTimelineItemCount = 0;
  String? _detailNavigationSessionId;
  Object? _detailNavigationError;

  AppCoordinator get coordinator => widget.coordinator;

  @override
  void initState() {
    super.initState();
    unawaited(coordinator.refreshCaptureTimeline());
    _timelineTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && coordinator.hasActiveCapture) {
        unawaited(coordinator.refreshCaptureTimeline());
      }
    });
  }

  @override
  void dispose() {
    _timelineTimer?.cancel();
    _captureScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return AnimatedBuilder(
      animation: coordinator,
      builder: (context, _) {
        final snapshot = coordinator.capture;
        final terminal =
            snapshot.state == 'completed' ||
            snapshot.state == 'completed_with_gaps';
        if (terminal && !coordinator.isBusy && _detailNavigationError == null) {
          _scheduleOpenDetails(snapshot.sessionId);
        }
        return PopScope<void>(
          canPop: _allowPop || !coordinator.hasActiveCapture,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_confirmLeaveCapture());
          },
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: terminal
                  ? null
                  : MediaQuery.textScalerOf(context).scale(1) > 1.4
                  ? 88
                  : 64,
              title: terminal
                  ? Text(l10n.openingRecording)
                  : _CaptureAppBarTitle(snapshot: snapshot),
            ),
            body: SafeArea(
              top: false,
              child: terminal
                  ? _CaptureDirectingView(
                      hasGaps: snapshot.state == 'completed_with_gaps',
                      error: _detailNavigationError,
                      onRetry: () => _retryOpenDetails(snapshot.sessionId),
                    )
                  : _activeCaptureBody(context),
            ),
            bottomNavigationBar: terminal
                ? null
                : _CaptureDock(
                    coordinator: coordinator,
                    onCamera: _openCamera,
                    onThought: _openThought,
                    onBookmark: _addBookmark,
                    pauseButton: _pauseButton(),
                    endButton: _endButton(),
                  ),
          ),
        );
      },
    );
  }

  Widget _activeCaptureBody(BuildContext context) {
    final snapshot = coordinator.capture;
    final interrupted = snapshot.state == 'interrupted';
    final paused = snapshot.state == 'paused';
    final timeline = coordinator.captureTimeline;
    final transcripts = committedTranscripts(timeline);
    final showsTimelineItems =
        _selectedView == RecordContentView.timeline &&
        coordinator.timelineError == null;
    _scheduleTimelineTailFollow(timeline.length);

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _handleCaptureScroll,
          child: ListView.builder(
            key: const Key('product-capture-page'),
            controller: _captureScrollController,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
            itemCount: 1 + (showsTimelineItems ? timeline.length : 0),
            itemBuilder: (context, index) {
              if (index > 0) {
                final item = timeline[index - 1];
                return ProductTimelineRow(
                  item: item,
                  isFirst: index == 1,
                  isLast: index == timeline.length,
                  inactivePlaybackLabel: l10n.playbackIsAvailableAfterRecording,
                  showImagePlaybackAction: false,
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CaptureClock(snapshot: snapshot),
                  const SizedBox(height: 18),
                  _RecordingStatusPanel(coordinator: coordinator),
                  if (interrupted) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.youCanAddNotesAfterResuming,
                      style: TextStyle(
                        color: ProductColors.amber,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.photosNotesAndHighlightsCannotBeAdded,
                      style: TextStyle(
                        color: ProductColors.amber,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                  if (paused) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.theMicrophoneIsStoppedAndTheAudio,
                      style: TextStyle(
                        color: ProductColors.forest,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.youCanStillAddPhotosNotesAnd,
                      style: TextStyle(
                        color: ProductColors.mutedInk,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  RecordContentSwitcher(
                    groupName: 'capture',
                    selected: _selectedView,
                    onChanged: _changeSelectedView,
                  ),
                  const SizedBox(height: 18),
                  if (_selectedView == RecordContentView.timeline)
                    _LiveTimeline(coordinator: coordinator)
                  else
                    _LiveFullText(items: transcripts),
                  if (showsTimelineItems && timeline.isNotEmpty)
                    const SizedBox(height: 10),
                ],
              );
            },
          ),
        ),
        if (_selectedView == RecordContentView.timeline &&
            timeline.isNotEmpty &&
            !_followTimelineTail)
          Positioned(
            right: 20,
            bottom: 14,
            child: FilledButton.tonalIcon(
              key: const Key('capture-jump-to-latest'),
              onPressed: _resumeTimelineTailFollow,
              icon: const Icon(Icons.arrow_downward_rounded),
              label: Text(l10n.jumpToLatest),
            ),
          ),
      ],
    );
  }

  void _changeSelectedView(RecordContentView view) {
    setState(() {
      _selectedView = view;
      if (view == RecordContentView.timeline) {
        _followTimelineTail = true;
        _lastTimelineItemCount = -1;
      }
    });
  }

  bool _handleCaptureScroll(ScrollNotification notification) {
    if (_selectedView != RecordContentView.timeline) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userDraggingTimeline = true;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _setTimelineTailFollow(
        notification.metrics.extentAfter <= _timelineTailThreshold,
      );
    } else if (notification is ScrollEndNotification && _userDraggingTimeline) {
      _userDraggingTimeline = false;
      _setTimelineTailFollow(
        notification.metrics.extentAfter <= _timelineTailThreshold,
      );
    }
    return false;
  }

  void _setTimelineTailFollow(bool value) {
    if (_followTimelineTail == value || !mounted) return;
    setState(() => _followTimelineTail = value);
  }

  void _scheduleTimelineTailFollow(int itemCount) {
    final itemCountChanged = itemCount != _lastTimelineItemCount;
    _lastTimelineItemCount = itemCount;
    if (!itemCountChanged ||
        !_followTimelineTail ||
        _selectedView != RecordContentView.timeline) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _followTimelineTail) {
        unawaited(_scrollToTimelineTail());
      }
    });
  }

  void _resumeTimelineTailFollow() {
    _setTimelineTailFollow(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scrollToTimelineTail());
    });
  }

  Future<void> _scrollToTimelineTail() async {
    if (!_captureScrollController.hasClients) return;
    final position = _captureScrollController.position;
    final target = position.maxScrollExtent;
    if ((target - position.pixels).abs() <= 1) return;
    await _captureScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _endButton() {
    final snapshot = coordinator.capture;
    final finalizing = snapshot.state == 'finalizing';
    return OutlinedButton.icon(
      key: const Key('end-product-recording'),
      style: OutlinedButton.styleFrom(
        backgroundColor: ProductColors.paper,
        foregroundColor: ProductColors.vermilion,
        side: const BorderSide(color: ProductColors.vermilion),
      ),
      onPressed:
          snapshot.canStop &&
              !coordinator.isBusy &&
              !coordinator.isCaptureActionBusy
          ? _confirmStop
          : null,
      icon: coordinator.isBusy || finalizing
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.stop_circle_outlined),
      label: Text(finalizing ? l10n.finishingSafely464 : l10n.finishAndSave),
    );
  }

  Widget _pauseButton() {
    final snapshot = coordinator.capture;
    final pausing = snapshot.state == 'pausing';
    final resuming = snapshot.state == 'resuming';
    return FilledButton.icon(
      key: const Key('toggle-product-recording-pause'),
      onPressed:
          !coordinator.isBusy &&
              !coordinator.isCaptureActionBusy &&
              (snapshot.canPause || snapshot.canResume)
          ? _togglePause
          : null,
      icon: pausing || resuming
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(snapshot.canResume ? Icons.mic_rounded : Icons.pause_rounded),
      label: Text(
        pausing
            ? l10n.pausing
            : resuming
            ? l10n.resuming
            : snapshot.canResume
            ? l10n.resumeRecording
            : snapshot.state == 'interrupted'
            ? l10n.waitingToResume
            : l10n.pauseRecording,
      ),
    );
  }

  Future<void> _togglePause() async {
    final wasPaused = coordinator.capture.canResume;
    try {
      if (wasPaused) {
        await coordinator.resumeRecording();
      } else {
        await coordinator.pauseRecording();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasPaused
                ? l10n.recordingResumedFromTheSameAudioPosition
                : l10n.recordingPausedTheMicrophoneIsStopped,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasPaused
                ? l10n.cannotResumeRecordingRightNowCheckMicrophone
                : l10n.pausingDidNotFinishSafelyCheckThe,
          ),
        ),
      );
    }
  }

  Future<void> _confirmLeaveCapture() async {
    if (!coordinator.hasActiveCapture) {
      _leavePage();
      return;
    }
    if (coordinator.capture.state == 'finalizing') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.savingTheFinalAudioSegmentYouCan)),
      );
      return;
    }
    if (!coordinator.needsBackgroundExitConfirmation) {
      _leavePage();
      return;
    }
    final paused = coordinator.capture.state == 'paused';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          paused
              ? l10n.returnHomeAndStayPaused
              : l10n.returnHomeAndKeepRecording,
        ),
        content: Text(
          paused
              ? l10n.theMicrophoneWillRemainStoppedReturnTo
              : l10n.recordingWillContinueHomeWillShowThe,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.stayHere),
          ),
          FilledButton(
            key: const Key('confirm-background-recording'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.returnHome),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      coordinator.acknowledgeBackgroundExit();
      _leavePage();
    }
  }

  void _leavePage() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  void _scheduleOpenDetails(String sessionId) {
    if (sessionId.isEmpty || _detailNavigationSessionId == sessionId) return;
    _detailNavigationSessionId = sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openDetails(sessionId));
    });
  }

  Future<void> _openDetails(String sessionId) async {
    final openDetails = widget.onOpenDetails;
    if (openDetails == null) {
      _leavePage();
      return;
    }
    try {
      await openDetails(sessionId);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _detailNavigationError = error;
        _detailNavigationSessionId = null;
      });
    }
  }

  void _retryOpenDetails(String sessionId) {
    setState(() => _detailNavigationError = null);
    _scheduleOpenDetails(sessionId);
  }

  Future<void> _openCamera() async {
    final paused = coordinator.capture.state == 'paused';
    if (!coordinator.cameraPurposeExplained) {
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            paused
                ? l10n.takePhotosWhilePaused
                : l10n.recordingContinuesWhileTakingPhotos,
          ),
          content: Text(
            paused
                ? l10n.momentaiUsesTheCameraOnlyWhenYou
                : l10n.momentaiUsesTheCameraOnlyWhenYou483,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.notNow484),
            ),
            FilledButton(
              key: const Key('confirm-open-product-camera'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.openCamera),
            ),
          ],
        ),
      );
      if (allowed != true || !mounted) return;
      coordinator.markCameraPurposeExplained();
    }
    try {
      final result = await coordinator.openCamera();
      if (!mounted || result['cancelled'] == true) return;
      final count = _number(result['photoCount']);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            paused
                ? l10n.safelySavedPhotosRecordingRemainsPaused(
                    (count).toString(),
                  )
                : l10n.safelySavedPhotosRecordingContinuedThroughout(
                    (count).toString(),
                  ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.cameraUnavailable),
          content: Text(
            paused
                ? l10n.recordingIsStillPausedAndSavedContent
                : l10n.recordingContinuesAndSavedContentIsUnaffected,
          ),
          actions: [
            TextButton(
              key: const Key('open-settings-for-product-camera'),
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await coordinator.openSystemSettings();
                } catch (_) {
                  // The recording remains active; settings can be opened later.
                }
              },
              child: Text(l10n.systemSettings),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(paused ? l10n.keepPaused : l10n.resumeRecording),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _openThought() async {
    final result = await showModalBottomSheet<Map<Object?, Object?>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ThoughtSheet(coordinator: coordinator),
    );
    if (result == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.noteSavedAt(
            (formatDuration(_number(result['atMs']))).toString(),
          ),
        ),
      ),
    );
  }

  Future<void> _addBookmark() async {
    try {
      final result = await coordinator.addBookmark();
      if (!mounted) return;
      final count = coordinator.captureTimeline
          .where((item) => item.isBookmark && item.isCommitted)
          .length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.highlightSavedAt(
              (count).toString(),
              (formatDuration(_number(result['atMs']))).toString(),
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            coordinator.capture.state == 'paused'
                ? l10n.highlightWasNotSavedRecordingRemainsPaused
                : l10n.highlightWasNotSavedRecordingContinuesTry,
          ),
        ),
      );
    }
  }

  Future<void> _confirmStop() async {
    final paused = coordinator.capture.state == 'paused';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.finishThisRecording),
        content: Text(
          paused
              ? l10n.audioIsPausedMomentAIWillSaveThe
              : l10n.momentaiWillSaveTheFinalAudioSegment,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.keepRecording),
          ),
          FilledButton(
            key: const Key('confirm-end-product-recording'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.finishAndSave),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await coordinator.stopRecording();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.finishingHasNotCompletedSafelyTryAgain)),
      );
    }
  }
}

class _CaptureAppBarTitle extends StatelessWidget {
  const _CaptureAppBarTitle({required this.snapshot});

  final PoCSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final interrupted = snapshot.state == 'interrupted';
    final paused = snapshot.state == 'paused';
    final finalizing = snapshot.state == 'finalizing';
    final transitioningPause = const {
      'pausing',
      'resuming',
    }.contains(snapshot.state);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              interrupted
                  ? Icons.pause_circle_filled_rounded
                  : paused || transitioningPause
                  ? Icons.pause_circle_outline_rounded
                  : Icons.fiber_manual_record,
              size: 13,
              color: interrupted || transitioningPause
                  ? ProductColors.amber
                  : paused
                  ? ProductColors.forest
                  : ProductColors.vermilion,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                finalizing
                    ? l10n.finishingSafely464
                    : interrupted
                    ? l10n.recordingInterrupted
                    : snapshot.state == 'pausing'
                    ? l10n.pausingSafely
                    : snapshot.state == 'resuming'
                    ? l10n.resumingRecording
                    : paused
                    ? l10n.recordingPaused
                    : l10n.recording506,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          formatDuration(snapshot.capturedMs),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _CaptureClock extends StatelessWidget {
  const _CaptureClock({required this.snapshot});

  final PoCSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final interrupted = snapshot.state == 'interrupted';
    final paused = snapshot.state == 'paused';
    final finalizing = snapshot.state == 'finalizing';
    final pausing = snapshot.state == 'pausing';
    final resuming = snapshot.state == 'resuming';
    return Column(
      children: [
        Icon(
          interrupted
              ? Icons.pause_circle_outline_rounded
              : paused || pausing || resuming
              ? Icons.pause_circle_outline_rounded
              : Icons.graphic_eq_rounded,
          size: 48,
          color: interrupted || pausing || resuming
              ? ProductColors.amber
              : paused
              ? ProductColors.forest
              : ProductColors.vermilion,
        ),
        const SizedBox(height: 10),
        Text(
          formatDuration(snapshot.capturedMs),
          key: const Key('product-capture-duration'),
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
            color: ProductColors.ink,
            fontWeight: FontWeight.w300,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          finalizing
              ? l10n.finishingSafely464
              : interrupted
              ? (snapshot.canResumeAfterInterruption
                    ? l10n.recordingWasInterruptedCheckMicrophoneAccessAnd
                    : l10n.recordingIsInterruptedWaitingForTheSystem)
              : pausing
              ? l10n.savingTheFinalAudioAndStoppingThe
              : resuming
              ? l10n.reactivatingTheMicrophone
              : paused
              ? l10n.recordingPausedAudioTimeIsNotAdvancing
              : l10n.recordingContinuesInTheBackgroundAndWith,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: interrupted || pausing || resuming
                ? ProductColors.amber
                : paused
                ? ProductColors.forest
                : ProductColors.mutedInk,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _CaptureActions extends StatelessWidget {
  const _CaptureActions({
    required this.coordinator,
    required this.onCamera,
    required this.onThought,
    required this.onBookmark,
  });

  final AppCoordinator coordinator;
  final VoidCallback onCamera;
  final VoidCallback onThought;
  final VoidCallback onBookmark;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final enabled = coordinator.canAddCaptureEvent;
    return Row(
      children: [
        Expanded(
          child: _CaptureActionButton(
            buttonKey: const Key('product-capture-photo'),
            icon: Icons.camera_alt_outlined,
            label: l10n.photo,
            busy: coordinator.captureAction == 'camera',
            onTap: enabled ? onCamera : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _CaptureActionButton(
            buttonKey: const Key('product-capture-thought'),
            icon: Icons.edit_note_rounded,
            label: l10n.note,
            busy: coordinator.captureAction == 'thought',
            onTap: enabled ? onThought : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _CaptureActionButton(
            buttonKey: const Key('product-capture-bookmark'),
            icon: Icons.bookmark_add_outlined,
            label: l10n.highlight,
            busy: coordinator.captureAction == 'bookmark',
            onTap: enabled ? onBookmark : null,
          ),
        ),
      ],
    );
  }
}

class _CaptureDock extends StatelessWidget {
  const _CaptureDock({
    required this.coordinator,
    required this.onCamera,
    required this.onThought,
    required this.onBookmark,
    required this.pauseButton,
    required this.endButton,
  });

  final AppCoordinator coordinator;
  final VoidCallback onCamera;
  final VoidCallback onThought;
  final VoidCallback onBookmark;
  final Widget pauseButton;
  final Widget endButton;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Material(
      color: ProductColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: Colors.black26,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CaptureActions(
                coordinator: coordinator,
                onCamera: onCamera,
                onThought: onThought,
                onBookmark: onBookmark,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: pauseButton),
                  const SizedBox(width: 10),
                  Expanded(child: endButton),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptureActionButton extends StatelessWidget {
  const _CaptureActionButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          key: buttonKey,
          color: onTap == null
              ? ProductColors.line.withValues(alpha: 0.35)
              : ProductColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: ProductColors.line),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 54),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        icon,
                        size: 21,
                        color: onTap == null
                            ? ProductColors.mutedInk
                            : ProductColors.forest,
                      ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveFullText extends StatelessWidget {
  const _LiveFullText({required this.items});

  final List<TimelineItem> items;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final visible = items.length <= 20
        ? items
        : items.sublist(items.length - 20);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.savedTranscript,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              l10n.segments((items.length).toString()),
              style: const TextStyle(color: ProductColors.mutedInk),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TranscriptFullText(
          items: visible,
          emptyMessage: l10n.savedLocalTranscriptionAppearsHerePhotosNotes,
        ),
        if (visible.length < items.length) ...[
          const SizedBox(height: 10),
          Text(
            l10n.showingTheLatestSegmentsEarlierTextWill(
              (visible.length).toString(),
            ),
            style: const TextStyle(color: ProductColors.mutedInk, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _RecordingStatusPanel extends StatelessWidget {
  const _RecordingStatusPanel({required this.coordinator});

  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final snapshot = coordinator.capture;
    final paused = snapshot.state == 'paused';
    final pausing = snapshot.state == 'pausing';
    final resuming = snapshot.state == 'resuming';
    final interrupted = snapshot.state == 'interrupted';
    final hasCommittedAudio =
        snapshot.chunkCount > 0 || snapshot.committedMs > 0;
    final transcriptionDelayed = snapshot.asrQueueDepth > 0;
    final transcriptionUnavailable = snapshot.asrMode != 'normal';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Column(
          children: [
            _StatusRow(
              icon: paused
                  ? Icons.pause_circle_outline_rounded
                  : Icons.fiber_manual_record,
              iconColor: interrupted || pausing || resuming
                  ? ProductColors.amber
                  : paused
                  ? ProductColors.forest
                  : ProductColors.vermilion,
              label: interrupted
                  ? l10n.recordingInterrupted
                  : pausing
                  ? l10n.pausingSafely
                  : resuming
                  ? l10n.resumingRecording
                  : paused
                  ? l10n.recordingPaused
                  : l10n.recording519,
              value: formatDuration(snapshot.capturedMs),
              detail: paused
                  ? l10n.pausedTimesPausesAreExcludedFromAudio(
                      (snapshot.userPauseCount).toString(),
                    )
                  : null,
            ),
            const Divider(height: 1),
            _StatusRow(
              icon: hasCommittedAudio
                  ? Icons.check_circle_outline_rounded
                  : Icons.hourglass_top_rounded,
              iconColor: hasCommittedAudio
                  ? ProductColors.forest
                  : ProductColors.mutedInk,
              label: hasCommittedAudio
                  ? l10n.safelySavedThrough
                  : l10n.savingTheFirstAudioChunk,
              value: hasCommittedAudio
                  ? formatDuration(snapshot.committedMs)
                  : l10n.pleaseWait,
              detail: hasCommittedAudio
                  ? l10n.aboutMsBehind((snapshot.rpoMs).toString())
                  : null,
            ),
            const Divider(height: 1),
            _StatusRow(
              icon: transcriptionUnavailable
                  ? Icons.closed_caption_disabled_outlined
                  : Icons.notes_rounded,
              iconColor: transcriptionUnavailable || transcriptionDelayed
                  ? ProductColors.amber
                  : ProductColors.forest,
              label: transcriptionUnavailable
                  ? l10n.transcriptionUnavailable
                  : transcriptionDelayed
                  ? l10n.transcriptionIsSlightlyBehind
                  : l10n.transcriptionIsLive,
              value: l10n.recordingIsUnaffected,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 19, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value, textAlign: TextAlign.end),
                if (detail != null)
                  Text(
                    detail!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: ProductColors.mutedInk,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveTimeline extends StatelessWidget {
  const _LiveTimeline({required this.coordinator});

  final AppCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final items = coordinator.captureTimeline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.liveTimeline,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (items.isNotEmpty)
              Text(
                l10n.items((items.length).toString()),
                style: const TextStyle(color: ProductColors.mutedInk),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (coordinator.timelineError != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _TimelineReadError(
                onRetry: coordinator.refreshCaptureTimeline,
              ),
            ),
          )
        else if (items.isEmpty)
          Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                l10n.transcriptsPhotosNotesHighlightsAndNecessarySystem,
                style: TextStyle(color: ProductColors.mutedInk, height: 1.45),
              ),
            ),
          ),
      ],
    );
  }
}

class _TimelineReadError extends StatelessWidget {
  const _TimelineReadError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Row(
      children: [
        Expanded(child: Text(l10n.couldNotRefreshTheLiveTimelineAudio)),
        TextButton(
          onPressed: () => unawaited(onRetry()),
          child: Text(l10n.retry),
        ),
      ],
    );
  }
}

class _ThoughtSheet extends StatefulWidget {
  const _ThoughtSheet({required this.coordinator});

  final AppCoordinator coordinator;

  @override
  State<_ThoughtSheet> createState() => _ThoughtSheetState();
}

class _ThoughtSheetState extends State<_ThoughtSheet> {
  static const maximumCharacters = 4000;
  final _controller = TextEditingController();
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() => _error = null);

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final canSave = _controller.text.trim().isNotEmpty && !_saving;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.writeANote,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.theNoteWillBeAnchoredToThe(
                (formatDuration(
                  widget.coordinator.capture.committedMs,
                )).toString(),
              ),
              style: const TextStyle(color: ProductColors.mutedInk),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('product-thought-input'),
              controller: _controller,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              maxLength: maximumCharacters,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: l10n.forExampleRevisitTheKeyDecisionDiscussed,
                errorText: _error,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
                const Spacer(),
                FilledButton.icon(
                  key: const Key('save-product-thought'),
                  onPressed: canSave ? _save : null,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_saving ? l10n.saving : l10n.saveNote),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.coordinator.addThought(_controller.text);
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = l10n.theNoteWasNotSavedYourText;
      });
    }
  }
}

class _CaptureDirectingView extends StatelessWidget {
  const _CaptureDirectingView({
    required this.hasGaps,
    required this.error,
    required this.onRetry,
  });

  final bool hasGaps;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error == null)
              const CircularProgressIndicator()
            else
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: hasGaps ? ProductColors.amber : ProductColors.vermilion,
              ),
            const SizedBox(height: 18),
            Text(
              error == null
                  ? hasGaps
                        ? l10n.continuousContentIsPreservedOpeningDetails
                        : l10n.recordingSafelySavedOpeningDetails
                  : l10n.theRecordingIsSafelySavedButDetails,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('retry-open-capture-details'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l10n.tryOpeningDetailsAgain),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

int _number(Object? value) =>
    value is num ? value.round() : int.tryParse('$value') ?? 0;
