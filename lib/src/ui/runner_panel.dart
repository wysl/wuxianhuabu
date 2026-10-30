import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/comfy_workflow_service.dart';
import '../state/connection_providers.dart';
import '../state/generated_media.dart';
import '../state/workflow_params.dart';

/// The bottom bar: submit, watch, cancel, and show the result.
class RunnerPanel extends ConsumerStatefulWidget {
  const RunnerPanel({
    super.key,
    required this.prepared,
    required this.onError,
  });

  final PreparedWorkflow? prepared;
  final ValueChanged<String> onError;

  @override
  ConsumerState<RunnerPanel> createState() => _RunnerPanelState();
}

class _RunnerPanelState extends ConsumerState<RunnerPanel> {
  GenerationRun? _run;
  StreamSubscription<GenerationRun>? _subscription;
  Uint8List? _lastPreview;
  final _clientId = const Uuid().v4();

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    final prepared = widget.prepared;
    final service = ref.read(workflowServiceProvider);
    if (prepared == null || service == null) return;
    if (prepared.preflightProblems.isNotEmpty) {
      widget.onError(
        '提交前检查未通过，ComfyUI 会拒绝这个请求：\n'
        '${prepared.preflightProblems.take(4).join('\n')}',
      );
      return;
    }

    final params = ref.read(workflowParamsProvider(prepared));
    try {
      final run = await service.submit(
        prepared,
        values: params.changed,
        clientId: _clientId,
      );
      if (!mounted) return;
      setState(() {
        _run = run;
        _lastPreview = null;
      });
      await _subscription?.cancel();
      _subscription = service.watch(run).listen((update) {
        if (!mounted) return;
        setState(() {
          _lastPreview = update.progress?.preview ?? _lastPreview;
        });
        if (update.isDone) _onFinished(update);
      });
    } on Object catch (error) {
      widget.onError('提交失败：$error');
    }
  }

  void _onFinished(GenerationRun run) {
    if (run.error != null) {
      widget.onError(run.error!);
      return;
    }
    final media = run.result?.media ?? const <Map<String, String>>[];
    if (media.isEmpty) {
      widget.onError('任务完成但没有产出文件');
      return;
    }
    // Publish the result so the canvas can show it. This closes the loop:
    // parameters in, files out, both on the board.
    ref.read(generatedMediaProvider.notifier).add(
          GeneratedMedia(
            promptId: run.promptId,
            workflowPath: widget.prepared?.sourcePath ?? '',
            media: media,
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<void> _cancel() async {
    final run = _run;
    final service = ref.read(workflowServiceProvider);
    if (run == null || service == null) return;
    try {
      await service.cancel(run);
    } on Object catch (error) {
      widget.onError('取消失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prepared = widget.prepared;
    final run = _run;
    final media = run?.result?.media ?? const <Map<String, String>>[];
    final busy = run != null && !run.isDone;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: prepared == null || busy ? null : _submit,
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: Text(busy ? '生成中' : '生成'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: busy ? _cancel : null,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('取消'),
              ),
              const SizedBox(width: 16),
              if (busy) ...[
                Expanded(child: _ProgressBar(run: run)),
              ] else if (run?.result != null) ...[
                Icon(Icons.check_circle,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('完成 · ${media.length} 个文件',
                    style: theme.textTheme.labelMedium),
              ] else if (prepared != null)
                Text(
                  '参数改动只在点「生成」时提交',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_lastPreview != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        _lastPreview!,
                        height: 90,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                Expanded(
                  child: media.isEmpty
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            run?.error ??
                                (prepared == null
                                    ? '还没有选择工作流'
                                    : '尚未生成'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: run?.error != null
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: media.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, index) => _MediaChip(
                            media: media[index],
                            promptId: run!.promptId,
                          ),
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

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.run});

  final GenerationRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = run.fraction;
    final elapsed = DateTime.now().difference(run.startedAt);
    final label = StringBuffer();
    if (run.progress?.step != null && run.progress?.totalSteps != null) {
      label.write('第 ${run.progress!.step}/${run.progress!.totalSteps} 步');
    } else {
      label.write('执行中');
    }
    label.write(' · 已用 ${elapsed.inSeconds}s');

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              // A null value renders an indeterminate bar, which is the honest
              // state when the workflow reports no step count.
              value: fraction,
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(label.toString(), style: theme.textTheme.labelSmall),
      ],
    );
  }
}

/// One produced file, with a thumbnail fetched through the authenticated
/// `/view` endpoint (the browser version cannot do this without a proxy).
class _MediaChip extends ConsumerWidget {
  const _MediaChip({required this.media, required this.promptId});

  final Map<String, String> media;
  final String promptId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(workflowServiceProvider);
    final theme = Theme.of(context);
    final isVideo = '${media['filename']}'.toLowerCase().endsWith('.mp4') ||
        '${media['filename']}'.toLowerCase().endsWith('.webm');

    return Container(
      width: 132,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: service == null
                ? const SizedBox()
                : FutureBuilder<Uint8List>(
                    future: service.fetchMedia(media),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Text('读取失败',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.error,
                              )),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      }
                      if (isVideo) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.movie_outlined, size: 28),
                              const SizedBox(height: 4),
                              Text('视频',
                                  style: theme.textTheme.labelSmall),
                            ],
                          ),
                        );
                      }
                      return Center(
                        child: Image.memory(
                          snapshot.data!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            '${media['filename']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
