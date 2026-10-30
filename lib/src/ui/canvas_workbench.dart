import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_document.dart';
import '../state/canvas_run.dart';
import '../state/connection_providers.dart';
import '../state/profile_store.dart';
import 'connection_screen.dart';
import 'infinite_canvas.dart';

/// Canvas-first shell.
///
/// The reference product puts the canvas at the centre and everything else in a
/// thin strip: a top bar for document identity and connection status, a side
/// sheet for the workflow library, and nothing between the user and the board.
/// The previous three-pane layout made the canvas a viewer; this one makes it the
/// workspace.
class CanvasWorkbench extends ConsumerStatefulWidget {
  const CanvasWorkbench({super.key});

  @override
  ConsumerState<CanvasWorkbench> createState() => _CanvasWorkbenchState();
}

class _CanvasWorkbenchState extends ConsumerState<CanvasWorkbench> {
  bool _libraryOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(canvasControllerProvider.notifier).restoreOrCreate();
    });
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(canvasControllerProvider);
    final profile = ref.watch(activeProfileProvider);

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            document: document,
            baseUrl: profile?.baseUrl.toString() ?? '未连接',
            onOpenLibrary: () => setState(() => _libraryOpen = !_libraryOpen),
            onNewCanvas: () =>
                ref.read(canvasControllerProvider.notifier).createNew(),
            onDisconnect: _disconnect,
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                if (_libraryOpen) ...[
                  SizedBox(
                    width: 300,
                    child: _WorkflowSideSheet(
                      onClose: () => setState(() => _libraryOpen = false),
                      onCreateConfig: _createConfigFor,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                const Expanded(child: InfiniteCanvas()),
              ],
            ),
          ),
          _StatusStrip(),
        ],
      ),
    );
  }

  /// Drops a generation config onto the board with [path] already selected.
  void _createConfigFor(String path) {
    final controller = ref.read(canvasControllerProvider.notifier);
    final node = controller.addNode(
      CanvasNodeKind.config,
      worldCenter: const Offset(420, 260),
      metadata: {'workflow_path': path},
    );
    controller.updateNode(node.id, (created) {
      created.title = path.split('/').last.replaceAll('.json', '');
    });
    setState(() => _libraryOpen = false);
  }

  Future<void> _disconnect() async {
    await ref.read(canvasControllerProvider.notifier).flush();
    ref.read(activeProfileProvider.notifier).profile = null;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.document,
    required this.baseUrl,
    required this.onOpenLibrary,
    required this.onNewCanvas,
    required this.onDisconnect,
  });

  final CanvasDocument? document;
  final String baseUrl;
  final VoidCallback onOpenLibrary;
  final VoidCallback onNewCanvas;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome_mosaic_outlined,
            size: 19,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            document?.title ?? '无界画布',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: '工作流库',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onOpenLibrary,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: '新建画布',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onNewCanvas,
            icon: const Icon(Icons.add_box_outlined),
          ),
          const Spacer(),
          _ConnectionChip(url: baseUrl),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '切换连接',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onDisconnect,
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Text(url, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// Workflow library as a side sheet rather than a permanent pane: the canvas is
/// the primary surface, so the list only takes space while you are choosing.
class _WorkflowSideSheet extends ConsumerWidget {
  const _WorkflowSideSheet({
    required this.onClose,
    required this.onCreateConfig,
  });

  final VoidCallback onClose;
  final void Function(String path) onCreateConfig;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final workflows = ref.watch(availableWorkflowsProvider);

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text('工作流库', style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: '刷新',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => ref.invalidate(availableWorkflowsProvider),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: '关闭',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '选中一个工作流，会在画布上放一个生成配置节点',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: workflows.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  '读取工作流失败：$error',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
              data: (paths) {
                if (paths.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '服务器上没有已保存的工作流',
                      style: theme.textTheme.labelSmall,
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  itemCount: paths.length,
                  itemBuilder: (context, index) {
                    final path = paths[index];
                    final name = path.split('/').last.replaceAll('.json', '');
                    final folder = path.split('/').length > 2
                        ? path.split('/')[1]
                        : '';
                    return ListTile(
                      dense: true,
                      title: Text(name, style: theme.textTheme.bodySmall),
                      subtitle: folder.isEmpty
                          ? null
                          : Text(folder, style: theme.textTheme.labelSmall),
                      trailing: const Icon(Icons.add, size: 15),
                      onTap: () => onCreateConfig(path),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom strip for run state: progress, or the last error.
class _StatusStrip extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final run = ref.watch(canvasRunProvider);
    final String text;
    final Color color;
    if (run == null) {
      text = '在画布上放置节点，连线后点“生成”';
      color = theme.colorScheme.onSurfaceVariant;
    } else if (run.error != null) {
      text = '失败：${run.error}';
      color = theme.colorScheme.error;
    } else if (run.isRunning) {
      final progress = run.progress;
      text = progress?.step == null
          ? '已提交，等待服务器…'
          : '执行中 ${progress!.step}/${progress.totalSteps ?? '?'}';
      color = theme.colorScheme.primary;
    } else {
      text = '完成';
      color = theme.colorScheme.onSurfaceVariant;
    }

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          if (run?.isRunning == true)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            'v0.1',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Routes between setup and the canvas.
///
/// Restores the last profile on launch so a desktop tool does not ask for the
/// same server address on every start.
class CanvasRoot extends ConsumerStatefulWidget {
  const CanvasRoot({super.key});

  @override
  ConsumerState<CanvasRoot> createState() => _CanvasRootState();
}

class _CanvasRootState extends ConsumerState<CanvasRoot> {
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = await ProfileStore().load();
      if (saved.isNotEmpty && mounted) {
        ref.read(activeProfileProvider.notifier).profile = saved.last;
      }
    } on Object {
      // A config that cannot be read is not fatal; setup is still reachable.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final profile = ref.watch(activeProfileProvider);
    if (profile == null) return const ConnectionScreen();
    return const CanvasWorkbench();
  }
}
