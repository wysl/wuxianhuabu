import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/comfy_workflow_service.dart';
import '../core/connection_profile.dart';
import '../state/connection_providers.dart';
import '../state/canvas_session.dart';
import '../state/profile_store.dart';
import 'canvas_board.dart';
import 'parameter_inspector.dart';
import 'runner_panel.dart';
import 'workflow_library.dart';

/// The main workbench: workflow library on the left, canvas in the middle,
/// parameter form and run status on the right.
///
/// The layout is intentionally three panes rather than a free-floating canvas
/// with modal dialogs: generation parameters get consulted constantly while
/// iterating, so hiding them behind a click costs more than the screen space.
class WorkbenchScreen extends ConsumerStatefulWidget {
  const WorkbenchScreen({super.key, required this.profile});

  final ConnectionProfile profile;

  @override
  ConsumerState<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends ConsumerState<WorkbenchScreen> {
  PreparedWorkflow? _prepared;
  String? _serverVersion;
  String? _loadError;
  bool _loadingVersion = true;
  double _libraryWidth = 280;
  double _inspectorWidth = 380;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final client = ref.read(comfyClientProvider);
    if (client == null) return;
    try {
      final stats = await client.systemStats(refresh: true);
      final system = stats['system'];
      final version =
          system is Map ? '${system['comfyui_version'] ?? '?'}' : null;
      if (!mounted) return;
      setState(() {
        _serverVersion = version;
        _loadingVersion = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '$error';
        _loadingVersion = false;
      });
    }
  }

  void _selectWorkflow(PreparedWorkflow prepared) {
    setState(() {
      _prepared = prepared;
      _loadError = null;
    });
    // Opening a workflow starts (or resumes) its canvas: the stored layout is
    // reused when one exists, so revisiting a workflow keeps its arrangement.
    ref
        .read(canvasSessionProvider.notifier)
        .openFor(prepared.sourcePath, prepared.name);
  }

  void _reportError(String message) {
    setState(() => _loadError = message);
  }

  void _disconnect() {
    ref.read(activeProfileProvider.notifier).profile = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            const Text('无界画布'),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.profile.baseUrl.toString(),
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_loadingVersion) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ] else if (_serverVersion != null) ...[
              const SizedBox(width: 8),
              Text(
                'ComfyUI $_serverVersion',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: '切换连接',
            onPressed: _disconnect,
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: _libraryWidth,
            child: WorkflowLibrary(
              onSelected: _selectWorkflow,
              onError: _reportError,
            ),
          ),
          _Splitter(
            onDrag: (delta) => setState(() {
              _libraryWidth = (_libraryWidth + delta).clamp(200.0, 480.0);
            }),
          ),
          Expanded(
            child: Column(
              children: [
                if (_loadError != null)
                  _ErrorStrip(
                    message: _loadError!,
                    onDismiss: () => setState(() => _loadError = null),
                  ),
                Expanded(
                  child: CanvasBoard(
                    prepared: _prepared,
                    profile: widget.profile,
                  ),
                ),
                const Divider(height: 1),
                SizedBox(
                  height: 190,
                  child: RunnerPanel(
                    prepared: _prepared,
                    onError: _reportError,
                  ),
                ),
              ],
            ),
          ),
          _Splitter(
            onDrag: (delta) => setState(() {
              _inspectorWidth = (_inspectorWidth - delta).clamp(280.0, 560.0);
            }),
          ),
          SizedBox(
            width: _inspectorWidth,
            child: ParameterInspector(prepared: _prepared),
          ),
        ],
      ),
    );
  }
}

/// A 4 px drag handle that reports horizontal deltas.
class _Splitter extends StatelessWidget {
  const _Splitter({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
          child: Container(
            width: 4,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      );
}

class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline,
              size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Exposes the profile persistence so the workbench can offer "forget this
/// server"; kept here rather than in the app bar to keep the bar declarative.
Future<void> forgetProfile(ConnectionProfile profile) async {
  final store = ProfileStore();
  final saved = await store.load();
  await store.save(
    saved.where((candidate) => candidate.id != profile.id).toList(),
  );
}
