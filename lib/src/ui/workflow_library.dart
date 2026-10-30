import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/comfy_client.dart';
import '../core/comfy_workflow_service.dart';
import '../state/connection_providers.dart';

/// Lists the workflows saved on the connected instance, plus local files.
///
/// The server side is the primary source: ComfyUI already stores every workflow
/// the user saved in its own `user/default/workflows` tree, reachable through
/// `/v2/userdata`. Reading that means the client needs no import step and no
/// API-format JSON, which is the whole point of this project.
class WorkflowLibrary extends ConsumerStatefulWidget {
  const WorkflowLibrary({
    super.key,
    required this.onSelected,
    required this.onError,
  });

  final ValueChanged<PreparedWorkflow> onSelected;
  final ValueChanged<String> onError;

  @override
  ConsumerState<WorkflowLibrary> createState() => _WorkflowLibraryState();
}

class _WorkflowLibraryState extends ConsumerState<WorkflowLibrary> {
  List<Map<String, Object?>>? _files;
  bool _loading = true;
  String _filter = '';
  String? _selectedPath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(comfyClientProvider);
    if (client == null) return;
    setState(() => _loading = true);
    try {
      final files = await client.listWorkflows();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } on ComfyApiException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      widget.onError('读取工作流列表失败：$error');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      widget.onError('读取工作流列表失败：$error');
    }
  }

  Future<void> _open(String path) async {
    final service = ref.read(workflowServiceProvider);
    if (service == null) return;
    setState(() {
      _busy = true;
      _selectedPath = path;
    });
    try {
      final prepared = await service.prepareFromServer(path);
      if (!mounted) return;
      widget.onSelected(prepared);
    } on PrepareException catch (error) {
      widget.onError('无法打开 $path：${error.message}');
    } on Object catch (error) {
      widget.onError('无法打开 $path：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLocal() async {
    final service = ref.read(workflowServiceProvider);
    if (service == null) return;
    final file = await FilePicker.pickFile(
      dialogTitle: '选择 ComfyUI 工作流（画布格式 .json）',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = file?.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final prepared = await service.prepareFromFile(File(path));
      if (!mounted) return;
      widget.onSelected(prepared);
    } on PrepareException catch (error) {
      widget.onError(error.message);
    } on Object catch (error) {
      widget.onError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = _files ?? const <Map<String, Object?>>[];
    final visible = _filter.isEmpty
        ? files
        : files
            .where((file) =>
                '${file['path']}'.toLowerCase().contains(_filter.toLowerCase()))
            .toList();

    // Group by folder so a deep workflow tree stays navigable.
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final file in visible) {
      final path = '${file['path']}';
      final folder = path.contains('/')
          ? path.substring(0, path.lastIndexOf('/'))
          : '(根目录)';
      grouped.putIfAbsent(folder, () => []).add(file);
    }
    final folders = grouped.keys.toList()..sort();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text('工作流', style: theme.textTheme.titleSmall),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '打开本地工作流',
                onPressed: _busy ? null : _openLocal,
                icon: const Icon(Icons.folder_open, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            onChanged: (value) => setState(() => _filter = value),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: '搜索',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? _EmptyLibrary(onRetry: _load)
                  : ListView(
                      children: [
                        for (final folder in folders) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                            child: Text(
                              folder,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          for (final file in grouped[folder]!)
                            _WorkflowTile(
                              name: _baseName('${file['name']}'),
                              size: _humanSize(file['size']),
                              selected: _selectedPath == '${file['path']}',
                              busy: _busy && _selectedPath == '${file['path']}',
                              onTap: () => _open('${file['path']}'),
                            ),
                        ],
                      ],
                    ),
        ),
      ],
    );
  }

  static String _baseName(String name) =>
      name.toLowerCase().endsWith('.json')
          ? name.substring(0, name.length - 5)
          : name;

  static String _humanSize(Object? raw) {
    final size = raw is num ? raw.toDouble() : null;
    if (size == null) return '';
    if (size < 1024) return '${size.toInt()} B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _WorkflowTile extends StatelessWidget {
  const _WorkflowTile({
    required this.name,
    required this.size,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final String name;
  final String size;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
      leading: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      title: Text(name, overflow: TextOverflow.ellipsis),
      trailing: size.isEmpty
          ? null
          : Text(size, style: theme.textTheme.labelSmall),
      onTap: busy ? null : onTap,
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined,
                size: 32, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              '服务器上没有已保存的工作流',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '在 ComfyUI 里保存一次工作流即可出现在这里，也可以用左下角的按钮打开本地文件。',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text('重新加载')),
          ],
        ),
      ),
    );
  }
}
