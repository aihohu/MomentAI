import 'dart:async';

import 'package:flutter/material.dart';

import '../core/asr/stage1_transcription_controller.dart';
import '../core/playback/stage1_playback_controller.dart';
import '../features/timeline/stage1_timeline_card.dart';
import 'poc_bridge.dart';

class PoCPage extends StatefulWidget {
  const PoCPage({
    super.key,
    required this.bridge,
    this.transcriptionController,
    this.playbackController,
  });
  final PoCBridge bridge;
  final Stage1TranscriptionController? transcriptionController;
  final Stage1PlaybackController? playbackController;

  @override
  State<PoCPage> createState() => _PoCPageState();
}

class _PoCPageState extends State<PoCPage> with WidgetsBindingObserver {
  static const _maximumThoughtCharacters = 4000;

  PoCSnapshot snapshot = PoCSnapshot.idle();
  List<RecoveryCandidate> recoveryCandidates = const [];
  StreamSubscription<PoCSnapshot>? subscription;
  final Map<String, RecoveryVerification> recoveredSessions = {};
  String? message;
  bool busy = false;
  Map<Object?, Object?> compatibility = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.transcriptionController?.addListener(_transcriptionChanged);
    subscription = widget.bridge.events.listen((value) {
      if (!mounted) return;
      setState(() {
        snapshot = value;
        final nextMessage = value.error ?? eventCopy(value.event);
        if (nextMessage != null) message = nextMessage;
      });
    }, onError: (Object error) => setMessage(error.toString()));
    unawaited(refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.transcriptionController?.removeListener(_transcriptionChanged);
    subscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final next = await widget.bridge.snapshot();
      final candidates = await widget.bridge.scanRecovery();
      final nextCompatibility = await widget.bridge.compatibilityReport();
      if (!mounted) return;
      setState(() {
        snapshot = next;
        recoveryCandidates = candidates;
        compatibility = nextCompatibility;
      });
    } catch (error) {
      setMessage(error.toString());
    }
  }

  Future<void> runAction(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (error) {
      setMessage(error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void setMessage(String value) {
    if (mounted) setState(() => message = value);
  }

  void _transcriptionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final recording = snapshot.isRecording;
    final activeCapture = snapshot.isActiveCapture;
    final transitioning = snapshot.isTransitioning;
    final canToggle = !busy && (snapshot.canStart || snapshot.canStop);
    final toggleLabel = switch (snapshot.state) {
      'authorizing' => '正在请求麦克风权限…',
      'preparing' => '正在启动录音…',
      'pausing' => '正在提交尾部音频并暂停…',
      'paused' => '结束已暂停的录音并安全收口',
      'resuming' => '正在重新启动录音…',
      'finalizing' => '正在冲刷尾帧，请稍候…',
      'interrupted' => '结束中断中的录音并冲刷尾帧',
      _ when recording => '正常停止并冲刷尾帧',
      _ => '开始 Capture Alpha 录音',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('MomentAI · Capture Alpha'),
        actions: [
          IconButton(
            onPressed: busy ? null : refresh,
            tooltip: '刷新状态',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const IntroCard(),
            if (widget.transcriptionController != null) ...[
              const SizedBox(height: 12),
              Stage1TimelineCard(
                controller: widget.transcriptionController!,
                playbackController: widget.playbackController,
                playbackEnabled: !activeCapture && !transitioning,
              ),
            ],
            const SizedBox(height: 12),
            RuntimeCard(snapshot: snapshot),
            if (message != null) ...[
              const SizedBox(height: 10),
              MaterialBanner(
                content: Text(message!),
                leading: const Icon(Icons.info_outline),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => message = null),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            Text('录音与后台', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('record-toggle'),
              onPressed: !canToggle
                  ? null
                  : () => runAction(() async {
                      snapshot = snapshot.canStop
                          ? await widget.bridge.stop()
                          : await widget.bridge.start();
                      if (mounted) setState(() {});
                    }),
              icon: transitioning
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      snapshot.canStop ? Icons.stop_circle_outlined : Icons.mic,
                    ),
              label: Text(toggleLabel),
            ),
            const SizedBox(height: 8),
            Text(
              activeCapture
                  ? '现在锁屏或切到后台；一分钟后返回，确认媒体时间和 Chunk 继续增长。'
                  : '开始前检查至少 512 MB 空间；音频只写入 App 本地目录。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('recording-pause-toggle'),
              onPressed: busy || (!snapshot.canPause && !snapshot.canResume)
                  ? null
                  : () => runAction(() async {
                      snapshot = snapshot.canResume
                          ? await widget.bridge.resumeRecording()
                          : await widget.bridge.pauseRecording();
                      if (mounted) setState(() {});
                    }),
              icon: Icon(
                snapshot.canResume ? Icons.mic_rounded : Icons.pause_rounded,
              ),
              label: Text(snapshot.canResume ? '继续录音' : '暂停录音'),
            ),
            const SizedBox(height: 20),
            Text('音频中断恢复', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('inject-audio-interruption'),
              onPressed: snapshot.state != 'recording' || busy
                  ? null
                  : () => runAction(() async {
                      await widget.bridge.injectAudioInterruptionForTest();
                      message = '已注入 3 秒音频中断；录音引擎正在自动恢复，请观察状态和保存水位。';
                      if (mounted) setState(() {});
                    }),
              icon: const Icon(Icons.pause_circle_outline),
              label: const Text('测试注入：暂停音频 3 秒并恢复'),
            ),
            const SizedBox(height: 8),
            Text(
              '此入口只暂停并重建录音引擎，不会退出 App。电话或 Siri 的真实系统中断仍需另行真机验收。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            S15AcceptanceCard(
              snapshot: snapshot,
              compatibility: compatibility,
              busy: busy,
              onRunInterruptions: snapshot.state != 'recording' || busy
                  ? null
                  : () => runAction(() async {
                      final result = await widget.bridge
                          .runInterruptionStressTest();
                      snapshot = await widget.bridge.snapshot();
                      message =
                          '100 次中断压力完成：${result['completed_count']}/${result['target_count']}，'
                          '最大恢复尝试 ${result['maximum_restart_attempts']} 次。请继续录音 10 秒后正常停止。';
                      if (mounted) setState(() {});
                    }),
              onInjectLowStorage: snapshot.state != 'recording' || busy
                  ? null
                  : confirmLowStorage,
              onRefreshCompatibility: busy
                  ? null
                  : () => runAction(() async {
                      compatibility = await widget.bridge.compatibilityReport();
                      if (mounted) setState(() {});
                    }),
            ),
            const SizedBox(height: 20),
            Text('ASR 隔离故障注入', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'normal', label: Text('正常')),
                ButtonSegment(value: 'slow', label: Text('慢')),
                ButtonSegment(value: 'failed', label: Text('失败')),
                ButtonSegment(value: 'disabled', label: Text('关闭')),
              ],
              selected: {snapshot.asrMode},
              onSelectionChanged: !recording || busy
                  ? null
                  : (value) => runAction(() async {
                      await widget.bridge.setASRMode(value.first);
                      snapshot = await widget.bridge.snapshot();
                      if (mounted) setState(() {});
                    }),
            ),
            const SizedBox(height: 8),
            Text(
              '“慢”会让容量为 4 的 ASR 队列溢出并丢弃 ASR 帧；录音 Chunk 与保存水位必须继续增长。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Text(
              'S1.2A · 图片 + Bookmark 原子锚点',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('capture-image'),
              onPressed: !recording || busy
                  ? null
                  : () => runAction(() async {
                      final before = snapshot.committedMs;
                      final result = await widget.bridge.openCamera();
                      await Future<void>.delayed(
                        const Duration(milliseconds: 1200),
                      );
                      snapshot = await widget.bridge.snapshot();
                      await widget.transcriptionController?.refreshTimeline(
                        snapshot.directory,
                      );
                      message =
                          '已保存 ${result['photoCount']} 张；锚点 ${result['firstMediaMs']}–${result['lastMediaMs']} ms；'
                          '保存水位推进 ${snapshot.committedMs - before} ms。';
                      if (mounted) setState(() {});
                    }),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('打开相机（本轮最多 10 张）'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('capture-bookmark'),
              onPressed: !recording || busy
                  ? null
                  : () => runAction(() async {
                      final result = await widget.bridge.addBookmark();
                      await widget.transcriptionController?.refreshTimeline(
                        snapshot.directory,
                      );
                      message = 'Bookmark 已原子提交到 ${result['atMs']} ms。';
                      if (mounted) setState(() {});
                    }),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('标记当前重点'),
            ),
            const SizedBox(height: 8),
            Text(
              '快门与 Bookmark 都从音频持久化串行域取得 sample_offset；图片只有在文件落盘后才会从 pending 原子切换为 committed。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Text(
              'S1.2B · 文字随想原子锚点',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('capture-thought'),
              onPressed: !recording || busy
                  ? null
                  : () => unawaited(captureTextThought()),
              icon: const Icon(Icons.edit_note_outlined),
              label: const Text('添加文字随想'),
            ),
            const SizedBox(height: 8),
            Text(
              '提交时先冲刷当前音频尾帧，再把用户原文与 sample_offset 一次性写入 SQLite；关闭输入框或空文本不会产生事件。本阶段不包含语音随想。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Text('崩溃与恢复', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: !recording || busy ? null : confirmTerminate,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('故障注入：立即终止进程'),
            ),
            const SizedBox(height: 8),
            Text(
              '仅用于真机 PoC。重新打开 App 后，恢复会校验哈希、隔离 .part 并计算 RPO。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            RecoveryList(
              candidates: recoveryCandidates,
              onRecover: recoverCandidate,
            ),
            if (recoveredSessions.isNotEmpty) ...[
              const SizedBox(height: 12),
              RecoveredSessionList(
                sessions: recoveredSessions.values.toList(growable: false),
                onVerifyAgain: recoverCandidate,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> confirmTerminate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('立即终止 MomentAI？'),
        content: const Text('这是故障注入，不会执行正常停止。重新打开 App 后验证恢复与 RPO。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('终止进程'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.bridge.terminateForRecoveryTest();
  }

  Future<void> confirmLowStorage() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('模拟仅剩 64 MB？'),
        content: const Text(
          '不会占满或删除真机文件；它会触发与真实低存储相同的受控停止路径，冲刷音频尾帧并结束当前 Session。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('注入并安全停止'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await runAction(() async {
      snapshot = await widget.bridge.injectLowStorageForTest();
      message = '低存储受控停止完成；请确认状态 completed_with_gaps、RPO ≤ 2 秒且 ASR 已收尾。';
      if (mounted) setState(() {});
    });
  }

  Future<void> captureTextThought() async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          const _TextThoughtSheet(maximumCharacters: _maximumThoughtCharacters),
    );
    if (text == null || text.isEmpty || !mounted) return;

    await runAction(() async {
      final result = await widget.bridge.addThought(text);
      await widget.transcriptionController?.refreshTimeline(snapshot.directory);
      message = '文字随想已原子提交到 ${result['atMs']} ms。';
      if (mounted) setState(() {});
    });
  }

  Future<void> recoverCandidate(RecoveryCandidate candidate) =>
      runAction(() async {
        final result = await widget.bridge.recover(candidate.directory);
        RecoveryTranscriptionResult? transcription;
        String? transcriptionError;
        final controller = widget.transcriptionController;
        if (controller != null) {
          try {
            transcription = await controller.recoverSessionTranscription(
              sessionId: candidate.sessionId,
              directory: candidate.directory,
            );
          } catch (error) {
            transcriptionError = '$error';
          }
        }
        final attempt =
            (recoveredSessions[candidate.directory]?.attempt ?? 0) + 1;
        final verification = RecoveryVerification(
          candidate: candidate,
          attempt: attempt,
          state: result['state']?.toString() ?? 'completed',
          rpoMs: numberValue(result['rpoMs']),
          rpoPass: result['rpoPass'] == true,
          transcription: transcription,
          transcriptionError: transcriptionError,
        );
        final summary = verification.summary;
        if (!mounted) return;
        setState(() {
          recoveryCandidates = recoveryCandidates
              .where((item) => item.directory != candidate.directory)
              .toList(growable: false);
          recoveredSessions[candidate.directory] = verification;
          message = summary;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(summary),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
      });
}

class _TextThoughtSheet extends StatefulWidget {
  const _TextThoughtSheet({required this.maximumCharacters});

  final int maximumCharacters;

  @override
  State<_TextThoughtSheet> createState() => _TextThoughtSheetState();
}

class _TextThoughtSheetState extends State<_TextThoughtSheet> {
  final controller = TextEditingController();
  var canSubmit = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      20,
      16,
      20,
      16 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('记下此刻的想法', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('点击提交时关联当前录音位置；你的原文会与讲者转写分开显示。'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('thought-input'),
          controller: controller,
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          maxLength: widget.maximumCharacters,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '输入一条只属于你的随想…',
          ),
          onChanged: (value) {
            final next = value.trim().isNotEmpty;
            if (next != canSubmit) setState(() => canSubmit = next);
          },
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const Key('thought-submit'),
              onPressed: canSubmit
                  ? () => Navigator.pop(context, controller.text.trim())
                  : null,
              icon: const Icon(Icons.link),
              label: const Text('提交并关联当前时刻'),
            ),
          ],
        ),
      ],
    ),
  );
}

class IntroCard extends StatelessWidget {
  const IntroCard({super.key});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Stage 1 Capture Alpha',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text('目标：可信录音、真实本地转写、原始时间线，以及可追溯的媒体样本锚点。'),
        ],
      ),
    ),
  );
}

class S15AcceptanceCard extends StatelessWidget {
  const S15AcceptanceCard({
    super.key,
    required this.snapshot,
    required this.compatibility,
    required this.busy,
    required this.onRunInterruptions,
    required this.onInjectLowStorage,
    required this.onRefreshCompatibility,
  });

  final PoCSnapshot snapshot;
  final Map<Object?, Object?> compatibility;
  final bool busy;
  final VoidCallback? onRunInterruptions;
  final VoidCallback? onInjectLowStorage;
  final VoidCallback? onRefreshCompatibility;

  @override
  Widget build(BuildContext context) {
    final targetMs = snapshot.s15TargetMs <= 0
        ? 10800000
        : snapshot.s15TargetMs;
    final progress = (snapshot.s15ElapsedMs / targetMs).clamp(0.0, 1.0);
    final stressRunning = snapshot.interruptionStressStatus == 'running';
    final hardware = compatibility['hardware_identifier']?.toString() ?? '—';
    final system = compatibility['system_version']?.toString() ?? '—';
    final appVersion = compatibility['app_version']?.toString() ?? '—';
    final appBuild = compatibility['app_build']?.toString() ?? '—';
    final storageBytes = numberValue(compatibility['available_storage_bytes']);
    final storageGiB = storageBytes <= 0
        ? '—'
        : '${(storageBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
    return Card(
      key: const Key('s1-5-acceptance-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'S1.5 · 耐久与兼容性',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text(
              '独立运行 ${durationText(snapshot.s15ElapsedMs)} / 03:00:00 · '
              '后台 ${snapshot.s15BackgroundCount} 次 · '
              '锁屏证据 ${snapshot.s15ProtectedDataUnavailableCount} 次',
            ),
            const SizedBox(height: 10),
            Text(
              '$hardware · iOS $system · App $appVersion ($appBuild) · 可用 $storageGiB',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('s1-5-compatibility-refresh'),
              onPressed: onRefreshCompatibility,
              icon: const Icon(Icons.devices_other),
              label: const Text('刷新本机兼容性报告'),
            ),
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
              key: const Key('s1-5-run-100-interruptions'),
              onPressed: onRunInterruptions,
              icon: stressRunning
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.repeat),
              label: Text(
                stressRunning
                    ? '中断 ${snapshot.interruptionStressCompleted}/${snapshot.interruptionStressTarget}'
                    : '运行 100 次音频引擎中断',
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('s1-5-low-storage'),
              onPressed: onInjectLowStorage,
              icon: const Icon(Icons.sd_storage_outlined),
              label: const Text('模拟低存储并受控停止'),
            ),
            const SizedBox(height: 8),
            Text(
              '100 次中断约需 75 秒。低存储注入不会写满磁盘，但会结束当前 Session；3 小时验收需锁屏并保持 App 独立运行。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class RuntimeCard extends StatelessWidget {
  const RuntimeCard({super.key, required this.snapshot});
  final PoCSnapshot snapshot;

  @override
  Widget build(BuildContext context) => Card(
    color: snapshot.rpoPass ? const Color(0xFFE5F1E9) : const Color(0xFFFFE9E4),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                snapshot.isUserPaused
                    ? Icons.pause_circle_outline_rounded
                    : snapshot.isActiveCapture
                    ? Icons.fiber_manual_record
                    : Icons.archive_outlined,
                color: snapshot.isUserPaused
                    ? Colors.green
                    : snapshot.isActiveCapture
                    ? Colors.red
                    : null,
              ),
              const SizedBox(width: 8),
              Text(
                snapshot.state,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              Text(
                snapshot.rpoPass ? 'RPO PASS' : 'RPO FAIL',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Divider(height: 24),
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              Metric(label: '采集', value: durationText(snapshot.capturedMs)),
              Metric(label: '已提交', value: durationText(snapshot.committedMs)),
              Metric(label: '当前 RPO', value: '${snapshot.rpoMs} ms'),
              Metric(label: 'Chunk', value: '${snapshot.chunkCount}'),
              Metric(label: 'ASR 队列', value: '${snapshot.asrQueueDepth}/4'),
              Metric(label: 'ASR 丢包', value: '${snapshot.asrDroppedBuffers}'),
              Metric(
                label: 'ASR 丢失',
                value: durationText(snapshot.asrDroppedSamples ~/ 16),
              ),
              Metric(
                label: 'ASR 失败',
                value: durationText(snapshot.asrFailedSamples ~/ 16),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class Metric extends StatelessWidget {
  const Metric({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class RecoveryList extends StatelessWidget {
  const RecoveryList({
    super.key,
    required this.candidates,
    required this.onRecover,
  });
  final List<RecoveryCandidate> candidates;
  final ValueChanged<RecoveryCandidate> onRecover;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.check_circle_outline),
          title: Text('没有待恢复 Session'),
        ),
      );
    }
    return Column(
      children: candidates
          .map(
            (candidate) => Card(
              child: ListTile(
                title: Text(candidate.sessionId),
                subtitle: Text(
                  '已提交 ${durationText(candidate.committedMs)} · 预计 RPO ${candidate.rpoMs} ms\n'
                  '可连续点击三次“恢复”验证幂等；完成后点右上角刷新清除。',
                ),
                trailing: FilledButton(
                  key: ValueKey('recover-${candidate.sessionId}'),
                  onPressed: () => onRecover(candidate),
                  child: const Text('恢复'),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class RecoveryVerification {
  const RecoveryVerification({
    required this.candidate,
    required this.attempt,
    required this.state,
    required this.rpoMs,
    required this.rpoPass,
    this.transcription,
    this.transcriptionError,
  });

  final RecoveryCandidate candidate;
  final int attempt;
  final String state;
  final int rpoMs;
  final bool rpoPass;
  final RecoveryTranscriptionResult? transcription;
  final String? transcriptionError;

  bool get transcriptionPass => transcriptionError == null;

  String get summary {
    final prefix = attempt == 1
        ? (rpoPass ? '恢复成功' : '恢复完成，RPO 未通过')
        : '幂等验证 $attempt/3 完成';
    final recovery =
        '$prefix · $state · RPO $rpoMs ms · ${rpoPass ? '通过' : '失败'}';
    if (transcriptionError != null) {
      return '$recovery · 音频恢复安全，ASR 补转写失败：$transcriptionError';
    }
    if (transcription != null) return '$recovery · ${transcription!.summary}';
    return recovery;
  }
}

class RecoveredSessionList extends StatelessWidget {
  const RecoveredSessionList({
    super.key,
    required this.sessions,
    required this.onVerifyAgain,
  });

  final List<RecoveryVerification> sessions;
  final ValueChanged<RecoveryCandidate> onVerifyAgain;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('恢复结果', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      ...sessions.map(
        (verification) => Card(
          key: ValueKey('recovered-${verification.candidate.sessionId}'),
          color: verification.rpoPass && verification.transcriptionPass
              ? const Color(0xFFE5F1E9)
              : const Color(0xFFFFE9E4),
          child: ListTile(
            leading: Icon(
              verification.rpoPass && verification.transcriptionPass
                  ? Icons.check_circle
                  : Icons.warning_amber_rounded,
            ),
            title: Text(
              verification.rpoPass && verification.transcriptionPass
                  ? '恢复成功'
                  : verification.rpoPass
                  ? '音频恢复成功，ASR 待处理'
                  : '恢复完成，RPO 未通过',
            ),
            subtitle: Text(
              '${verification.candidate.sessionId}\n'
              '${verification.state} · RPO ${verification.rpoMs} ms · '
              '幂等验证 ${verification.attempt}/3\n'
              '${verification.transcriptionError != null ? 'ASR 补转写失败' : verification.transcription?.summary ?? '未连接 ASR 控制器'}',
            ),
            trailing: verification.attempt >= 3
                ? const Text('3/3 ✓')
                : FilledButton.tonal(
                    key: ValueKey(
                      'reverify-${verification.candidate.sessionId}',
                    ),
                    onPressed: () => onVerifyAgain(verification.candidate),
                    child: Text('再次验证 ${verification.attempt + 1}/3'),
                  ),
          ),
        ),
      ),
    ],
  );
}

String durationText(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String? eventCopy(String? event) => switch (event) {
  'photo' => '照片已写入 Session，录音持续。',
  'image_pending' => '已冻结图片媒体时钟，正在持久化。',
  'image' => '图片文件与锚点已原子提交，录音持续。',
  'image_failed' => '图片提交失败，失败状态已记录，录音持续。',
  'bookmark' => 'Bookmark 已按媒体样本时钟提交。',
  'interruption_began' => '系统音频中断，最后安全水位已保留。',
  'interruption_ended' => '音频输入已恢复，中断缺口已写入事件表。',
  'interruption_restart_retry' => '音频输入恢复失败，正在自动重试。',
  'finalizing' || 'finalizing_after_error' => '正在安全冲刷尾帧，请稍候。',
  'audio_interruption_recovery_failed' => '音频输入无法恢复；尾帧已冲刷，会话已安全结束。',
  'audio_persistence_failed' => '音频持久化失败；会话已安全结束，请检查存储空间。',
  'session_stopped' => '录音已停止，尾帧已安全写入。',
  'route_changed' => '音频路由发生变化，事件已记录。',
  'asr_mode_changed' => 'ASR 故障注入模式已切换。',
  'interruption_stress_started' => '100 次中断压力已启动。',
  'interruption_stress_progress' => '中断压力进行中，录音引擎已恢复。',
  'interruption_stress_completed' => '100 次音频引擎中断全部恢复。',
  'storage_pressure_controlled_stop' => '低存储阈值已触发；尾帧已冲刷，Session 已受控结束。',
  's1_5_application_background' => 'S1.5 已记录进入后台。',
  's1_5_application_foreground' => 'S1.5 已记录回到前台。',
  's1_5_protected_data_unavailable' => 'S1.5 已记录锁屏数据保护状态。',
  's1_5_protected_data_available' => 'S1.5 已记录解锁数据保护状态。',
  _ => null,
};
