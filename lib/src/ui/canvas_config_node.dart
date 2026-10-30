import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_document.dart';
import '../state/connection_providers.dart';
import '../state/canvas_run.dart';

/// The generation config node: the canvas's "make something" button.
///
/// It holds the prompt, the workflow to run, and the count; its *inputs* are
/// whatever the user connected to it (text nodes contribute to the prompt, image
/// nodes become references). That is the whole model — no typed ports, no API
/// JSON.
class ConfigNodeBody extends ConsumerStatefulWidget {
  const ConfigNodeBody({super.key, required this.node});

  final CanvasNode node;

  @override
  ConsumerState<ConfigNodeBody> createState() => _ConfigNodeBodyState();
}

class _ConfigNodeBodyState extends ConsumerState<ConfigNodeBody> {
  late final TextEditingController _prompt =
      TextEditingController(text: widget.node.prompt);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitPrompt();
    });
  }

  @override
  void didUpdateWidget(covariant ConfigNodeBody old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _prompt.text != widget.node.prompt) {
      _prompt.text = widget.node.prompt;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _commitPrompt() {
    final text = _prompt.text;
    if (text == widget.node.prompt) return;
    ref.read(canvasControllerProvider.notifier).updateNode(
          widget.node.id,
          (node) => node.prompt = text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ref.read(canvasControllerProvider.notifier);
    final inputs = controller.inputsFor(widget.node.id);
    final run = ref.watch(canvasRunProvider);
    final running = run?.configNodeId == widget.node.id && run!.isRunning;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.tune_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '生成配置',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (inputs.texts.isNotEmpty || inputs.images.isNotEmpty)
                Text(
                  [
                    if (inputs.texts.isNotEmpty) '文本 ${inputs.texts.length}',
                    if (inputs.images.isNotEmpty) '参考 ${inputs.images.length}',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: TextField(
              controller: _prompt,
              focusNode: _focus,
              maxLines: null,
              expands: true,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: '描述你想要生成的画面…',
                hintStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _WorkflowPicker(node: widget.node)),
              const SizedBox(width: 6),
              _CountPicker(node: widget.node),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: FilledButton.icon(
              onPressed: running ? null : () => _generate(context),
              icon: running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 15),
              label: Text(
                running ? '生成中' : '生成',
                style: theme.textTheme.labelMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generate(BuildContext context) async {
    _commitPrompt();
    final workflowPath = widget.node.workflowPath;
    if (workflowPath == null || workflowPath.isEmpty) {
      _toast('先在配置里选择一个工作流');
      return;
    }
    final service = ref.read(workflowServiceProvider);
    if (service == null) {
      _toast('未连接 ComfyUI');
      return;
    }
    await ref.read(canvasRunProvider.notifier).generate(
          configNodeId: widget.node.id,
          workflowPath: workflowPath,
          prompt: widget.node.prompt,
          count: widget.node.count,
        );
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Chooses which saved workflow the config runs.
class _WorkflowPicker extends ConsumerWidget {
  const _WorkflowPicker({required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final workflows = ref.watch(availableWorkflowsProvider);
    final current = node.workflowPath;

    return PopupMenuButton<String>(
      tooltip: '选择工作流',
      onSelected: (path) {
        ref.read(canvasControllerProvider.notifier).updateNode(
              node.id,
              (node) => node.workflowPath = path,
            );
      },
      itemBuilder: (context) {
        final entries = workflows.value ?? const <String>[];
        if (entries.isEmpty) {
          return [
            const PopupMenuItem(
              value: '',
              enabled: false,
              child: Text('没有可用工作流'),
            ),
          ];
        }
        return [
          for (final path in entries)
            PopupMenuItem(
              value: path,
              child: Text(
                path.split('/').last,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ];
      },
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                current == null || current.isEmpty
                    ? '选择工作流'
                    : current.split('/').last,
                style: theme.textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _CountPicker extends ConsumerWidget {
  const _CountPicker({required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return PopupMenuButton<int>(
      tooltip: '生成数量',
      onSelected: (count) {
        ref.read(canvasControllerProvider.notifier).updateNode(
              node.id,
              (node) => node.count = count,
            );
      },
      itemBuilder: (context) => [
        for (final count in [1, 2, 3, 4])
          PopupMenuItem(value: count, child: Text('$count 张')),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Text('${node.count} 张', style: theme.textTheme.labelSmall),
            Icon(
              Icons.expand_more,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
