import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/asr/stage1_transcription_controller.dart';
import '../../core/asr/transcription_provider.dart';
import '../../core/playback/stage1_playback_controller.dart';
import '../../domain/timeline/timeline_item.dart';
import '../../poc/poc_bridge.dart';

class Stage1TimelineCard extends StatefulWidget {
  const Stage1TimelineCard({
    super.key,
    required this.controller,
    this.playbackController,
    this.playbackEnabled = true,
  });

  final Stage1TranscriptionController controller;
  final Stage1PlaybackController? playbackController;
  final bool playbackEnabled;

  @override
  State<Stage1TimelineCard> createState() => _Stage1TimelineCardState();
}

class _Stage1TimelineCardState extends State<Stage1TimelineCard> {
  static const _pageSize = 50;
  var _visibleItemCount = _pageSize;
  String? _timelineDirectory;
  var _exporting = false;
  SessionExportResult? _export;
  String? _exportError;

  @override
  void initState() {
    super.initState();
    widget.playbackController?.addListener(_playbackChanged);
  }

  @override
  void didUpdateWidget(covariant Stage1TimelineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackController != widget.playbackController) {
      oldWidget.playbackController?.removeListener(_playbackChanged);
      widget.playbackController?.addListener(_playbackChanged);
    }
  }

  @override
  void dispose() {
    widget.playbackController?.removeListener(_playbackChanged);
    super.dispose();
  }

  void _playbackChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (_timelineDirectory != controller.activeDirectory) {
      _timelineDirectory = controller.activeDirectory;
      _visibleItemCount = _pageSize;
      _export = null;
      _exportError = null;
    }
    final state = controller.workerState;
    final timeline = controller.timeline
        .where(_isVisibleTimelineItem)
        .toList(growable: false);
    final shownCount = timeline.length < _visibleItemCount
        ? timeline.length
        : _visibleItemCount;
    final playback = widget.playbackController;
    final timelineDirectory = controller.activeDirectory;
    final canOfferPlayback =
        playback != null &&
        timelineDirectory != null &&
        timelineDirectory.isNotEmpty &&
        timeline.isNotEmpty;
    final canExport =
        timelineDirectory != null &&
        timelineDirectory.isNotEmpty &&
        widget.playbackEnabled &&
        controller.activeSessionId == null &&
        !controller.recoveryCatchUpInProgress;
    return Card(
      key: const Key('stage1-transcription-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_statusIcon(state.status)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Stage 1 · 本地转写',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(_statusLabel(state.status)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              state.message ?? _statusDescription(state.status),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text('ASR 队列 ${state.pendingChunks}/4'),
                Text('已转写 ${_duration(state.lastTranscribedSample ~/ 16)}'),
                if (controller.catchUpRequired)
                  const Text(
                    '待离线补齐',
                    style: TextStyle(color: Color(0xFFC98B35)),
                  ),
                if (controller.recoveryCatchUpInProgress)
                  const Text(
                    '恢复补转写中',
                    style: TextStyle(color: Color(0xFFC98B35)),
                  ),
              ],
            ),
            if (controller.recoveryStatus != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.recoveryStatus!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (controller.partial?.text.isNotEmpty == true) ...[
              const Divider(height: 24),
              Text('实时草稿', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(controller.partial!.text),
            ],
            if (controller.error != null) ...[
              const SizedBox(height: 10),
              Text(
                controller.error!,
                style: const TextStyle(color: Color(0xFF9B3A2D)),
              ),
            ],
            if (controller.faultControlsAvailable) ...[
              const Divider(height: 24),
              _ResilienceConsole(controller: controller),
            ],
            if (canOfferPlayback) ...[
              const Divider(height: 24),
              _PlaybackControls(
                controller: playback,
                directory: timelineDirectory,
                enabled: widget.playbackEnabled,
              ),
            ],
            if (timelineDirectory != null && timelineDirectory.isNotEmpty) ...[
              const Divider(height: 24),
              _ExportControls(
                exporting: _exporting,
                enabled: canExport,
                result: _export,
                error: _exportError,
                onExport: () => _exportAndShare(timelineDirectory),
                onShare: _export == null
                    ? null
                    : () => _share(_export!.archivePath),
              ),
            ],
            if (timeline.isNotEmpty) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '原始时间线',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Text('$shownCount/${timeline.length}'),
                ],
              ),
              const SizedBox(height: 8),
              ...timeline
                  .take(shownCount)
                  .map(
                    (item) => _TimelineRow(
                      item: item,
                      selected:
                          playback?.snapshot.directory == timelineDirectory &&
                          playback?.selectedItemId == item.playbackId,
                      onPlay:
                          playback != null &&
                              timelineDirectory != null &&
                              widget.playbackEnabled &&
                              _isPlayableItem(item)
                          ? () => unawaited(
                              playback.playFrom(timelineDirectory, item),
                            )
                          : null,
                    ),
                  ),
              if (shownCount < timeline.length)
                Center(
                  child: OutlinedButton.icon(
                    key: const Key('timeline-load-more'),
                    onPressed: () => setState(() {
                      _visibleItemCount += _pageSize;
                    }),
                    icon: const Icon(Icons.expand_more),
                    label: Text('继续显示后续 ${timeline.length - shownCount} 项'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _exportAndShare(String directory) async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportError = null;
    });
    try {
      final exported = await widget.controller.bridge.exportSession(directory);
      if (!mounted) return;
      setState(() => _export = exported);
      await _share(exported.archivePath, showFailureInline: false);
    } catch (error) {
      if (mounted) setState(() => _exportError = '$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share(
    String archivePath, {
    bool showFailureInline = true,
  }) async {
    try {
      await widget.controller.bridge.shareExport(archivePath);
    } catch (error) {
      if (mounted && showFailureInline) {
        setState(() => _exportError = '分享失败：$error');
      }
      if (!showFailureInline) rethrow;
    }
  }
}

class _ExportControls extends StatelessWidget {
  const _ExportControls({
    required this.exporting,
    required this.enabled,
    required this.result,
    required this.error,
    required this.onExport,
    required this.onShare,
  });

  final bool exporting;
  final bool enabled;
  final SessionExportResult? result;
  final String? error;
  final VoidCallback onExport;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('stage1-export-controls'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.ios_share_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'S1.4 · 可移植导出',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (result != null) const Text('已生成'),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        enabled
            ? '生成 Markdown、JSON/JSONL、标准 WAV、原图和带完整性清单的 .momentai。'
            : '正常停止并等待 ASR 收尾后才能导出；导出不会修改原始事实数据。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const Key('stage1-export-session'),
            onPressed: enabled && !exporting ? onExport : null,
            icon: exporting
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.inventory_2_outlined),
            label: Text(exporting ? '正在校验并打包…' : '生成并分享 .momentai'),
          ),
          if (result != null)
            OutlinedButton.icon(
              key: const Key('stage1-share-export'),
              onPressed: exporting ? null : onShare,
              icon: const Icon(Icons.share_outlined),
              label: const Text('再次分享'),
            ),
        ],
      ),
      if (result != null) ...[
        const SizedBox(height: 8),
        Text(
          key: const Key('stage1-export-summary'),
          '${_duration(result!.durationMs)} · '
          '${result!.transcriptCount} 条转写 · ${result!.imageCount} 张图片 · '
          '${_fileSize(result!.archiveByteCount)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 2),
        Text(
          'SHA-256 ${result!.archiveSha256}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
      if (error != null) ...[
        const SizedBox(height: 8),
        Text(
          '导出失败：$error',
          key: const Key('stage1-export-error'),
          style: const TextStyle(color: Color(0xFF9B3A2D)),
        ),
      ],
    ],
  );
}

class _ResilienceConsole extends StatelessWidget {
  const _ResilienceConsole({required this.controller});

  final Stage1TranscriptionController controller;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.canInjectFault;
    final modelFaultActive = controller.modelFaultActive;
    final delayActive = controller.forcedProcessingDelayMs != 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.science_outlined, size: 20),
            const SizedBox(width: 8),
            Text(
              'ASR 韧性测试 · Profile Only',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '只终止或拖慢真实 sherpa Worker；录音持久化不会等待这些操作。请为三项测试分别新建 Session。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('stage1-kill-worker'),
              onPressed: enabled && !modelFaultActive
                  ? () => _run(context, controller.injectWorkerCrashForTest)
                  : null,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('终止真实 Worker'),
            ),
            OutlinedButton.icon(
              key: const Key('stage1-missing-model'),
              onPressed: enabled && !modelFaultActive
                  ? () => _run(context, controller.injectMissingModelForTest)
                  : null,
              icon: const Icon(Icons.folder_off_outlined),
              label: const Text('缺失模型重启'),
            ),
            OutlinedButton.icon(
              key: const Key('stage1-restore-model'),
              onPressed: enabled && modelFaultActive
                  ? () => _run(context, controller.restoreModelForTest)
                  : null,
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('恢复真实模型'),
            ),
            OutlinedButton.icon(
              key: const Key('stage1-toggle-delay'),
              onPressed: enabled && !modelFaultActive
                  ? () => _run(context, controller.toggleForcedOverflowForTest)
                  : null,
              icon: Icon(delayActive ? Icons.speed : Icons.hourglass_bottom),
              label: Text(delayActive ? '恢复正常速度' : '强制延迟 2.5 秒'),
            ),
          ],
        ),
        if (controller.faultStatus != null) ...[
          const SizedBox(height: 8),
          Text(
            controller.faultStatus!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (controller.activeSessionId == null) ...[
          const SizedBox(height: 8),
          const Text('先开始录音，按钮才会启用。'),
        ],
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ASR 韧性操作失败：$error')));
    }
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.item, required this.selected, this.onPlay});

  final TimelineItem item;
  final bool selected;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onPlay != null,
    label: onPlay == null ? null : '从 ${_duration(item.atMs)} 开始播放',
    child: Padding(
      key: ValueKey('timeline-${item.playbackId}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              _duration(item.atMs),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('play-${item.playbackId}'),
                onTap: onPlay,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: item.isTranscript
                        ? const Color(0xFFFFFDF8)
                        : item.isThought
                        ? const Color(0xFFF1E3BD)
                        : const Color(0xFFE9E3D7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0xFFD7D0C2),
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _TimelineContent(item: item)),
                      if (onPlay != null) ...[
                        const SizedBox(width: 8),
                        Icon(
                          selected
                              ? Icons.graphic_eq
                              : Icons.play_circle_outline,
                          size: 20,
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlaybackControls extends StatefulWidget {
  const _PlaybackControls({
    required this.controller,
    required this.directory,
    required this.enabled,
  });

  final Stage1PlaybackController controller;
  final String directory;
  final bool enabled;

  @override
  State<_PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<_PlaybackControls> {
  double? dragSample;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final prepared =
        snapshot.directory == widget.directory && snapshot.isPrepared;
    final durationSamples = prepared ? snapshot.durationSamples : 0;
    final displayedSample = dragSample ?? snapshot.positionSample.toDouble();
    final positionMs = prepared
        ? (displayedSample * 1000 / snapshot.sampleRate).round()
        : 0;
    return Column(
      key: const Key('stage1-playback-controls'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.headphones_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'S1.3 · 原始音频播放',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (prepared) Text(_playbackStateLabel(snapshot.state)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          widget.enabled
              ? prepared
                    ? '已选中 ${snapshot.anchorType} 锚点；拖动进度条以 sample clock 精确跳转。'
                    : '点击任一转写、文字随想、图片或 Bookmark，从其事实锚点开始播放。'
              : '录音进行中不启动回放；正常停止后可点击时间线。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (prepared) ...[
          const SizedBox(height: 8),
          Text(
            key: const Key('playback-output-route'),
            '输出：${_playbackOutputLabel(snapshot.outputPortType, snapshot.outputPortName)}'
            ' · 系统音量 ${(snapshot.outputVolume * 100).round()}%'
            ' · 响度增强 +${snapshot.signalGainDb.toStringAsFixed(1)} dB',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton.filledTonal(
                key: const Key('playback-toggle'),
                onPressed: widget.enabled && !controller.operationInProgress
                    ? () => unawaited(controller.toggle())
                    : null,
                icon: Icon(snapshot.isPlaying ? Icons.pause : Icons.play_arrow),
                tooltip: snapshot.isPlaying ? '暂停' : '播放',
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Slider(
                  key: const Key('playback-slider'),
                  min: 0,
                  max: durationSamples.toDouble(),
                  value: displayedSample.clamp(0, durationSamples.toDouble()),
                  onChangeStart:
                      widget.enabled && !controller.operationInProgress
                      ? (value) => setState(() => dragSample = value)
                      : null,
                  onChanged: widget.enabled && !controller.operationInProgress
                      ? (value) => setState(() => dragSample = value)
                      : null,
                  onChangeEnd: widget.enabled && !controller.operationInProgress
                      ? (value) {
                          setState(() => dragSample = null);
                          unawaited(controller.seek(value.round()));
                        }
                      : null,
                ),
              ),
              IconButton(
                key: const Key('playback-stop'),
                onPressed: !controller.operationInProgress
                    ? () => unawaited(controller.stop())
                    : null,
                icon: const Icon(Icons.stop),
                tooltip: '停止播放',
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_duration(positionMs)),
              Text(_duration(snapshot.durationMs)),
            ],
          ),
        ],
        if (controller.error != null) ...[
          const SizedBox(height: 6),
          Text(
            '播放失败：${controller.error}',
            style: const TextStyle(color: Color(0xFF9B3A2D)),
          ),
        ],
      ],
    );
  }
}

class _TimelineContent extends StatelessWidget {
  const _TimelineContent({required this.item});

  final TimelineItem item;

  @override
  Widget build(BuildContext context) {
    if (item.isTranscript) return Text(item.text);
    final imageExists =
        item.isImage &&
        item.isCommitted &&
        item.assetPath.isNotEmpty &&
        File(item.assetPath).existsSync();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (imageExists) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image.file(
              File(item.assetPath),
              width: 64,
              height: 64,
              cacheWidth: 192,
              cacheHeight: 192,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.square(
                dimension: 64,
                child: Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ] else if (item.isImage || item.isBookmark || item.isThought) ...[
          Icon(
            item.isBookmark
                ? Icons.bookmark
                : item.isThought
                ? Icons.edit_note_outlined
                : Icons.image_outlined,
            size: 20,
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_eventLabel(item.type)),
              if (item.isThought && item.text.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(item.text),
              ],
              if (item.isCaptureEvent) ...[
                const SizedBox(height: 2),
                Text(
                  _captureStateLabel(item),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

bool _isVisibleTimelineItem(TimelineItem item) =>
    item.isTranscript ||
    (item.isCaptureEvent &&
        const {'image', 'bookmark', 'thought'}.contains(item.type)) ||
    const {
      'photo',
      'audio_interruption_began',
      'audio_interruption_ended',
      'user_pause_began',
      'user_pause_ended',
      'session_recovered',
      'asr_worker_crash_injected',
      'asr_worker_crashed',
      'asr_worker_restarted',
      'asr_model_missing_injected',
      'asr_model_unavailable',
      'asr_model_restored',
      'asr_queue_overflow',
      'asr_catchup_started',
      'asr_catchup_completed',
      'asr_recovery_catchup_started',
      'asr_recovery_catchup_completed',
    }.contains(item.type);

bool _isPlayableItem(TimelineItem item) =>
    item.isTranscript || !item.isCaptureEvent || item.isCommitted;

String _playbackStateLabel(String state) => switch (state) {
  'playing' => '播放中',
  'paused' => '已暂停',
  'completed' => '已播完',
  'failed' => '播放失败',
  _ => '待播放',
};

String _playbackOutputLabel(String portType, String portName) {
  final normalized = portType.toLowerCase();
  if (normalized.contains('speaker')) return '扬声器';
  if (normalized.contains('receiver')) return '听筒';
  if (normalized.contains('headphone') || normalized.contains('headset')) {
    return '耳机${portName.isEmpty ? '' : '（$portName）'}';
  }
  if (normalized.contains('bluetooth')) {
    return '蓝牙${portName.isEmpty ? '' : '（$portName）'}';
  }
  if (normalized.contains('airplay')) {
    return 'AirPlay${portName.isEmpty ? '' : '（$portName）'}';
  }
  return portName.isNotEmpty
      ? portName
      : (portType.isNotEmpty ? portType : '检测中');
}

String _statusLabel(TranscriptionWorkerStatus status) => switch (status) {
  TranscriptionWorkerStatus.uninitialized => '未初始化',
  TranscriptionWorkerStatus.loadingModel => '加载模型',
  TranscriptionWorkerStatus.ready => '已就绪',
  TranscriptionWorkerStatus.transcribing => '转写中',
  TranscriptionWorkerStatus.catchUpRequired => '待补齐',
  TranscriptionWorkerStatus.failed => '转写失败',
  TranscriptionWorkerStatus.disposed => '已关闭',
};

String _statusDescription(TranscriptionWorkerStatus status) => switch (status) {
  TranscriptionWorkerStatus.uninitialized => '正在启动独立 ASR Worker。',
  TranscriptionWorkerStatus.loadingModel => '首次启动会复制并加载本地普通话模型。',
  TranscriptionWorkerStatus.ready => '本地普通话模型已就绪，录音不会等待 ASR。',
  TranscriptionWorkerStatus.transcribing => '正在消费已提交 Chunk，录音持久化保持独立。',
  TranscriptionWorkerStatus.catchUpRequired => '实时队列有缺口，音频安全，停止后需要补转写。',
  TranscriptionWorkerStatus.failed => '本地转写不可用，录音与保存不受影响。',
  TranscriptionWorkerStatus.disposed => 'ASR Worker 已释放。',
};

IconData _statusIcon(TranscriptionWorkerStatus status) => switch (status) {
  TranscriptionWorkerStatus.ready ||
  TranscriptionWorkerStatus.transcribing => Icons.subtitles_outlined,
  TranscriptionWorkerStatus.failed => Icons.error_outline,
  TranscriptionWorkerStatus.catchUpRequired => Icons.pending_actions_outlined,
  _ => Icons.downloading_outlined,
};

String _eventLabel(String type) => switch (type) {
  'photo' => '拍摄照片',
  'image' => '图片锚点',
  'bookmark' => '重点 Bookmark',
  'thought' => '我的随想 · 用户原文',
  'audio_interruption_began' => '系统音频中断开始',
  'audio_interruption_ended' => '系统音频中断结束',
  'user_pause_began' => '用户暂停录音',
  'user_pause_ended' => '用户继续或结束录音',
  'session_recovered' => '应用恢复 Session',
  'asr_worker_crash_injected' => '测试：终止真实 ASR Worker',
  'asr_worker_crashed' => '真实 ASR Worker 已退出',
  'asr_worker_restarted' => '真实 ASR Worker 已重建',
  'asr_model_missing_injected' => '测试：注入缺失模型',
  'asr_model_unavailable' => '真实模型初始化失败',
  'asr_model_restored' => '真实模型已恢复',
  'asr_queue_overflow' => '真实 ASR 队列已满',
  'asr_catchup_started' => 'ASR 补转写开始',
  'asr_catchup_completed' => 'ASR 补转写完成',
  'asr_recovery_catchup_started' => '恢复 Session：ASR 补转写开始',
  'asr_recovery_catchup_completed' => '恢复 Session：ASR 补转写完成',
  _ => type,
};

String _captureStateLabel(TimelineItem item) => switch (item.captureState) {
  'committed' =>
    item.isImage
        ? '图片与锚点已原子提交'
        : item.isThought
        ? '文字与锚点已原子提交'
        : '锚点已提交',
  'pending' => '正在持久化',
  'failed' => '提交失败 · ${item.assetState.isEmpty ? '无有效资产' : item.assetState}',
  'tombstoned' => '已删除',
  _ => item.captureState,
};

String _duration(int milliseconds) {
  final value = Duration(milliseconds: milliseconds);
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _fileSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}
