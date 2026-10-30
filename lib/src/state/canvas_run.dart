import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_document.dart';
import '../../comfy_graph.dart';
import '../core/comfy_client.dart';
import '../core/comfy_workflow_service.dart';
import 'connection_providers.dart';

/// Saved workflows available to the canvas, as server-relative paths.
final availableWorkflowsProvider =
    FutureProvider<List<String>>((ref) async {
  final service = ref.watch(workflowServiceProvider);
  if (service == null) return const [];
  final files = await service.client.listWorkflows();
  return [for (final file in files) '${file['path']}'];
});

/// A generation triggered from a config node.
class CanvasRun {
  const CanvasRun({
    required this.configNodeId,
    required this.promptId,
    this.progress,
    this.error,
    this.finished = false,
  });

  final String configNodeId;
  final String promptId;
  final ExecutionProgress? progress;
  final String? error;
  final bool finished;

  bool get isRunning => !finished && error == null;

  CanvasRun copyWith({
    ExecutionProgress? progress,
    String? error,
    bool? finished,
  }) =>
      CanvasRun(
        configNodeId: configNodeId,
        promptId: promptId,
        progress: progress ?? this.progress,
        error: error ?? this.error,
        finished: finished ?? this.finished,
      );
}

final canvasRunProvider =
    NotifierProvider<CanvasRunNotifier, CanvasRun?>(CanvasRunNotifier.new);

/// Drives one generation at a time from the canvas.
///
/// One at a time is a deliberate limitation: the reference product also runs a
/// single job per canvas, because ComfyUI executes a queue serially anyway and a
/// second concurrent submit only makes cancellation ambiguous.
class CanvasRunNotifier extends Notifier<CanvasRun?> {
  @override
  CanvasRun? build() => null;

  Future<void> generate({
    required String configNodeId,
    required String workflowPath,
    required String prompt,
    required int count,
  }) async {
    final service = ref.read(workflowServiceProvider);
    if (service == null) return;
    final canvas = ref.read(canvasControllerProvider.notifier);

    // Mark the config's downstream image nodes as loading so the canvas reacts
    // immediately, before any network round trip.
    final document = ref.read(canvasControllerProvider);
    final targets = _imageTargets(document, configNodeId, count);
    for (final id in targets) {
      canvas.updateNode(id, (node) {
        node.status = NodeStatus.loading;
        node.metadata = {...node.metadata, 'error': null};
      });
    }

    state = null;
    try {
      final prepared = await service.prepareFromServer(workflowPath);

      // The canvas prompt wins over the workflow's own text; connected text
      // nodes are appended so the graph and the canvas cannot disagree silently.
      final inputs = canvas.inputsFor(configNodeId);
      final composed = [
        if (prompt.trim().isNotEmpty) prompt.trim(),
        ...inputs.texts,
      ].join('\n\n');

      final values = <String, Object?>{};
      for (final parameter in prepared.parameters) {
        final override = _valueFor(prepared, parameter, composed);
        if (override != null) values[parameter.key] = override;
      }

      const clientId = 'wuxianhuabu-canvas';
      final run = await service.submit(
        prepared,
        values: values,
        clientId: clientId,
      );
      state = CanvasRun(configNodeId: configNodeId, promptId: run.promptId);

      await for (final update in service.watch(run)) {
        state = CanvasRun(
          configNodeId: configNodeId,
          promptId: run.promptId,
          progress: update.progress,
          error: update.error,
          finished: update.error != null || !update.cancelled && update.isDone,
        );
        if (update.error != null) {
          _failTargets(targets, update.error!);
          return;
        }
        if (update.isDone) {
          final media = update.result?.media ?? const <Map<String, String>>[];
          _applyResults(configNodeId, media);
          state = CanvasRun(
            configNodeId: configNodeId,
            promptId: run.promptId,
            finished: true,
          );
          return;
        }
      }
    } on PrepareException catch (error) {
      _failTargets(targets, error.message);
      state = CanvasRun(
        configNodeId: configNodeId,
        promptId: '',
        error: error.message,
        finished: true,
      );
    } on Object catch (error) {
      _failTargets(targets, '$error');
      state = CanvasRun(
        configNodeId: configNodeId,
        promptId: '',
        error: '$error',
        finished: true,
      );
    }
  }

  /// What to send for one parameter: the canvas prompt for text slots, the
  /// saved value for everything else.
  Object? _valueFor(
    PreparedWorkflow prepared,
    ParameterDef parameter,
    String composed,
  ) {
    if (composed.isEmpty) return null;
    final name = parameter.name.toLowerCase();
    final looksLikePrompt = parameter.type == 'STRING' &&
        (name.contains('text') ||
            name.contains('prompt') ||
            name.contains('描述') ||
            name.contains('提示'));
    return looksLikePrompt ? composed : null;
  }

  /// Image nodes that will receive this run's output, in reading order.
  List<String> _imageTargets(
    CanvasDocument? document,
    String configNodeId,
    int count,
  ) {
    final ids = <String>[];
    if (document == null) return ids;
    for (final edge in document.outgoingOf(configNodeId)) {
      final node = document.nodeById(edge.toNodeId);
      if (node?.kind == CanvasNodeKind.image) ids.add(node!.id);
    }
    // No wired image node yet: the results still need somewhere to land, so the
    // run creates them (handled by the caller via an empty list).
    return ids.take(count).toList();
  }

  void _failTargets(List<String> targets, String message) {
    final canvas = ref.read(canvasControllerProvider.notifier);
    for (final id in targets) {
      canvas.updateNode(id, (node) {
        node.status = NodeStatus.error;
        node.metadata = {...node.metadata, 'error': message};
      });
    }
  }

  /// Writes produced files onto image nodes, creating one per file when the
  /// config has no wired target.
  void _applyResults(String configNodeId, List<Map<String, String>> media) {
    final document = ref.read(canvasControllerProvider);
    if (document == null) return;
    final canvas = ref.read(canvasControllerProvider.notifier);
    final wired = _imageTargets(document, configNodeId, media.length);

    for (var i = 0; i < media.length; i++) {
      final ref0 = MediaRef(
        filename: media[i]['filename'] ?? '',
        subfolder: media[i]['subfolder'] ?? '',
        type: media[i]['type'] ?? 'output',
      );
      if (i < wired.length) {
        canvas.updateNode(wired[i], (node) {
          node.status = NodeStatus.success;
          node.media = [ref0];
          node.metadata = {...node.metadata, 'error': null};
        });
      } else {
        final config = document.nodeById(configNodeId);
        canvas.addNode(
          CanvasNodeKind.image,
          worldCenter: (config?.rect.center ?? const Offset(0, 0)) +
              Offset(0, 300.0 + i * 260),
          metadata: {'error': null},
        );
        final created = ref.read(canvasControllerProvider)!.nodes.last;
        canvas.updateNode(created.id, (node) {
          node.status = NodeStatus.success;
          node.media = [ref0];
        });
      }
    }
    // Clear the spinner on targets that received nothing.
    for (var i = media.length; i < wired.length; i++) {
      canvas.updateNode(wired[i], (node) => node.status = NodeStatus.idle);
    }
  }
}
