import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../graph/node_definition.dart';
import '../graph/parameter.dart';
import '../graph/prompt_patcher.dart';
import '../graph/ui_workflow.dart';
import '../graph/workflow_expander.dart';
import 'comfy_client.dart';

/// A workflow as the UI needs it: the graph, the expanded prompt, and the
/// parameters that can be edited.
class PreparedWorkflow {
  PreparedWorkflow({
    required this.sourcePath,
    required this.name,
    required this.workflow,
    required this.expanded,
    required this.parameters,
    required this.preflightProblems,
  });

  /// Path inside the server's user directory, or a local file path.
  final String sourcePath;
  final String name;
  final UiWorkflow workflow;
  final ExpandedWorkflow expanded;

  /// Promoted and widget parameters, enriched with the server's option lists.
  final List<ParameterDef> parameters;

  /// Problems that will make `/prompt` reject this as-is: stale model names,
  /// missing custom nodes. Surfaced before submitting rather than after.
  final List<String> preflightProblems;

  int get nodeCount => expanded.prompt.length;

  List<String> get warnings => expanded.warnings;
}

/// State of one in-flight generation.
class GenerationRun {
  GenerationRun({
    required this.promptId,
    required this.clientId,
    required this.startedAt,
  });

  final String promptId;
  final String clientId;
  final DateTime startedAt;

  ExecutionProgress? progress;
  ExecutionResult? result;
  String? error;
  bool cancelled = false;

  bool get isDone => result != null || error != null || cancelled;

  double? get fraction => progress?.fraction;
}

/// What happens when something goes wrong while preparing a workflow.
enum PrepareFailure {
  notUiWorkflow,
  expandFailed,
  emptyPrompt,
  unreadable,
}

class PrepareException implements Exception {
  PrepareException(this.failure, this.message);

  final PrepareFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// Orchestrates the workflow lifecycle against one instance:
///
///   list → read → expand → enrich → validate → submit → track → collect
///
/// The client below stays deliberately stateless about *projects*; the canvas
/// owns persistence. What it owns is the expensive, shareable part: the
/// `/object_info` registry.
class ComfyWorkflowService {
  ComfyWorkflowService(this.client);

  final ComfyClient client;

  NodeDefinitionRegistry _definitions = NodeDefinitionRegistry.empty;
  Future<NodeDefinitionRegistry>? _definitionsInFlight;

  NodeDefinitionRegistry get definitions => _definitions;

  /// Loads `/object_info` once and reuses it. It is ~6.7 MB on a fully loaded
  /// instance and never changes without a restart, so re-fetching per edit
  /// would be wasteful.
  Future<NodeDefinitionRegistry> ensureDefinitions({bool refresh = false}) {
    if (!refresh && _definitions.length > 0) {
      return Future.value(_definitions);
    }
    return _definitionsInFlight ??= _loadDefinitions().whenComplete(() {
      _definitionsInFlight = null;
    });
  }

  Future<NodeDefinitionRegistry> _loadDefinitions() async {
    final raw = await client.objectInfo();
    _definitions = NodeDefinitionRegistry.fromJson(raw);
    return _definitions;
  }

  /// Reads and prepares a workflow stored on the server.
  Future<PreparedWorkflow> prepareFromServer(
    String relativePath, {
    String? name,
  }) async {
    final Map<String, Object?> raw;
    try {
      raw = await client.readUserData(relativePath);
    } on ComfyApiException catch (error) {
      throw PrepareException(PrepareFailure.unreadable, '$error');
    }
    return prepare(
      raw,
      sourcePath: relativePath,
      name: name ?? _baseName(relativePath),
    );
  }

  /// Reads and prepares a workflow from a local file.
  Future<PreparedWorkflow> prepareFromFile(File file) async {
    try {
      final text = await file.readAsString();
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (error) {
        throw PrepareException(
          PrepareFailure.unreadable,
          'JSON 解析失败：${error.message}',
        );
      }
      if (decoded is! Map) {
        throw PrepareException(
          PrepareFailure.notUiWorkflow,
          '文件顶层不是 JSON 对象',
        );
      }
      return await prepare(
        decoded.cast<String, Object?>(),
        sourcePath: file.path,
        name: _baseName(file.path),
      );
    } on FileSystemException catch (error) {
      throw PrepareException(PrepareFailure.unreadable, '读取文件失败：${error.message}');
    }
  }

  /// Expands [raw] and enriches the parameters with server-side metadata.
  Future<PreparedWorkflow> prepare(
    Map<String, Object?> raw, {
    required String sourcePath,
    required String name,
  }) async {
    if (!UiWorkflow.looksLikeUiWorkflow(raw)) {
      throw PrepareException(
        PrepareFailure.notUiWorkflow,
        '这不是 ComfyUI 的 UI 工作流（缺少 nodes/links）。'
        '本项目直接读取画布工作流，不需要 API 格式的流水线 JSON。',
      );
    }

    final UiWorkflow workflow;
    try {
      workflow = UiWorkflow.fromJson(raw);
    } on Object catch (error) {
      throw PrepareException(PrepareFailure.expandFailed, '工作流结构无效：$error');
    }

    final ExpandedWorkflow expanded;
    try {
      expanded = WorkflowExpander(workflow).expand();
    } on Object catch (error) {
      throw PrepareException(PrepareFailure.expandFailed, '展开失败：$error');
    }
    if (expanded.prompt.isEmpty) {
      throw PrepareException(
        PrepareFailure.emptyPrompt,
        '展开后没有任何可执行节点（全部被静音或旁路？）',
      );
    }

    // Enrichment needs the registry; a failure here must not block the editor,
    // so it degrades to un-enriched parameters.
    var parameters = expanded.parameters;
    var problems = const <String>[];
    try {
      final registry = await ensureDefinitions();
      parameters = registry.enrich(
        parameters,
        classTypesByExecId: {
          for (final entry in expanded.prompt.entries)
            entry.key: entry.value.classType,
        },
      );
      problems = registry.validatePrompt(expanded.toPromptJson());
    } on ComfyApiException {
      // Offline-ish states (403, timeout) still allow editing.
    }

    return PreparedWorkflow(
      sourcePath: sourcePath,
      name: name,
      workflow: workflow,
      expanded: expanded,
      parameters: parameters,
      preflightProblems: problems,
    );
  }

  /// Applies [values] to a prepared workflow and submits it.
  ///
  /// Returns the prompt id and a [GenerationRun] that the caller drives with
  /// [watch].
  Future<GenerationRun> submit(
    PreparedWorkflow prepared, {
    required Map<String, Object?> values,
    required String clientId,
  }) async {
    final patched = const PromptPatcher().apply(
      prepared.expanded.prompt,
      prepared.parameters,
      values,
    );
    final promptJson = <String, Object?>{
      for (final entry in patched.prompt.entries) entry.key: entry.value.toJson(),
    };
    final promptId = await client.submitPrompt(promptJson, clientId: clientId);
    return GenerationRun(
      promptId: promptId,
      clientId: clientId,
      startedAt: DateTime.now(),
    );
  }

  /// Follows a run to completion, reporting progress as it arrives.
  ///
  /// The WebSocket is a *signal*, not the source of truth: completion and
  /// failure are decided by polling `/history`, because a reverse proxy
  /// without WebSocket support is common and must not stall generation.
  Stream<GenerationRun> watch(
    GenerationRun run, {
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 30),
  }) async* {
    WebSocketChannel? channel;
    StreamSubscription<ExecutionProgress>? subscription;
    final done = Completer<void>();

    try {
      channel = await client.openWebSocket(run.clientId);
      subscription = client.progressStream(channel, promptId: run.promptId).listen(
        (progress) {
          run.progress = progress;
        },
        onError: (Object _) {
          // The socket dropping is not fatal; polling still reaches a result.
        },
        cancelOnError: false,
      );
    } on Object {
      // No WebSocket (blocked upgrade, auth on the upgrade path, ...). Progress
      // falls back to polling; the run itself is unaffected.
      channel = null;
    }

    final deadline = DateTime.now().add(timeout);
    try {
      while (!done.isCompleted) {
        if (run.cancelled) return;
        if (DateTime.now().isAfter(deadline)) {
          run.error = '超时：${timeout.inMinutes} 分钟内未完成';
          yield run;
          return;
        }

        yield run;

        final result = await client.pollResult(run.promptId);
        if (result != null) {
          final status = result.status ?? '';
          if (status == 'error') {
            run.error = '执行失败（ComfyUI 报告 error）';
          } else {
            run.result = result;
          }
          yield run;
          return;
        }

        await Future<void>.delayed(pollInterval);
      }
    } finally {
      await subscription?.cancel();
      await channel?.sink.close();
    }
  }

  /// Cancels a run: interrupts it if running, removes it from the queue if it
  /// has not started yet.
  Future<void> cancel(GenerationRun run) async {
    run.cancelled = true;
    final queue = await client.queue();
    if (queue.pending.contains(run.promptId)) {
      await client.cancelQueued([run.promptId]);
      return;
    }
    if (queue.running.contains(run.promptId)) {
      await client.interrupt();
    }
  }

  /// Uploads bytes and returns the name to write into a media parameter.
  Future<String> upload(Uint8List bytes, String filename) =>
      client.uploadImage(bytes, filename: filename);

  /// Fetches one produced file.
  Future<Uint8List> fetchMedia(Map<String, String> media) => client.view(
        filename: media['filename'] ?? '',
        subfolder: media['subfolder'] ?? '',
        type: media['type'] ?? 'output',
      );

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.split('/').last;
    return name.toLowerCase().endsWith('.json')
        ? name.substring(0, name.length - 5)
        : name;
  }
}

/// Uploads a local file's bytes into a media parameter.
extension MediaUpload on ComfyWorkflowService {
  Future<String> uploadFile(File file) async {
    final bytes = await file.readAsBytes();
    return upload(bytes, file.uri.pathSegments.last);
  }
}
