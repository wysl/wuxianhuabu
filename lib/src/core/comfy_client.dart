import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_profile.dart';

/// Raised when the remote instance answers with something the client cannot
/// use. Carries ComfyUI's own `node_errors` when present so the UI can show the
/// real reason instead of "request failed".
class ComfyApiException implements Exception {
  ComfyApiException(
    this.message, {
    this.statusCode,
    this.errorType,
    this.nodeErrors = const {},
    this.details,
  });

  final String message;
  final int? statusCode;

  /// ComfyUI's machine-readable error type, e.g. `missing_node_type`.
  final String? errorType;

  /// `{nodeId: {class_type, errors: [...]}}` from a failed `/prompt`.
  final Map<String, Object?> nodeErrors;

  final String? details;

  /// True when the failure is about credentials rather than the request.
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() {
    final buffer = StringBuffer(message);
    if (errorType != null) buffer.write(' [$errorType]');
    for (final entry in nodeErrors.entries) {
      final detail = entry.value;
      if (detail is Map) {
        final errors = detail['errors'];
        if (errors is List) {
          for (final error in errors) {
            if (error is Map) {
              buffer.write(
                '\n  node ${entry.key} (${detail['class_type']}): '
                '${error['message']}',
              );
            }
          }
        }
      }
    }
    return buffer.toString();
  }
}

/// A queue entry, as `/queue` and `/api/jobs` describe it.
class QueueState {
  const QueueState({required this.running, required this.pending});

  final List<String> running;
  final List<String> pending;

  bool get isEmpty => running.isEmpty && pending.isEmpty;
}

/// Progress reported over the WebSocket.
class ExecutionProgress {
  const ExecutionProgress({
    required this.promptId,
    this.step,
    this.totalSteps,
    this.nodeId,
    this.preview,
    this.previewFormat,
  });

  final String promptId;

  /// Current sampling step, 1-based, when known.
  final int? step;
  final int? totalSteps;

  /// Execution id of the node currently running.
  final String? nodeId;

  /// Raw preview image bytes (the sampler latent preview), when the server
  /// sends them. Requires `--preview-method latent2rgb` or `taesd`.
  final Uint8List? preview;
  final int? previewFormat;

  double? get fraction {
    final total = totalSteps;
    final current = step;
    if (total == null || current == null || total <= 0) return null;
    return (current / total).clamp(0.0, 1.0);
  }
}

/// The result of one finished prompt.
class ExecutionResult {
  const ExecutionResult({
    required this.promptId,
    required this.outputs,
    this.status,
  });

  final String promptId;

  /// ComfyUI's `history.outputs`: `{nodeId: {images: [...], gifs: [...]}}`.
  final Map<String, Object?> outputs;

  final String? status;

  /// Flattens every produced file into `{filename, subfolder, type}` records.
  List<Map<String, String>> get media {
    final found = <Map<String, String>>[];
    for (final node in outputs.values) {
      if (node is! Map) continue;
      for (final key in const ['images', 'gifs', 'videos', 'audio']) {
        final items = node[key];
        if (items is! List) continue;
        for (final item in items) {
          if (item is! Map) continue;
          final filename = item['filename'];
          if (filename is! String || filename.isEmpty) continue;
          found.add({
            'filename': filename,
            'subfolder': '${item['subfolder'] ?? ''}',
            'type': '${item['type'] ?? 'output'}',
          });
        }
      }
    }
    return found;
  }
}

/// Talks to one ComfyUI instance.
///
/// Deliberately thin: one method per endpoint, no caching, no retries beyond
/// what dio does. The caching and orchestration live above it.
class ComfyClient {
  ComfyClient(this.profile)
      : _dio = buildDio(profile),
        _httpClient = buildHttpClient(profile);

  final ConnectionProfile profile;
  final Dio _dio;
  final HttpClient _httpClient;

  /// Server facts read from `/system_stats`, cached after the first success.
  Map<String, Object?>? _systemStats;

  Map<String, Object?>? get cachedSystemStats => _systemStats;

  /// ComfyUI's own version string, when it has been read.
  String? get serverVersion {
    final system = _systemStats?['system'];
    if (system is Map) {
      final version = system['comfyui_version'];
      if (version is String) return version;
    }
    return null;
  }

  void close() {
    _dio.close(force: true);
    _httpClient.close(force: true);
  }

  // -- basics -------------------------------------------------------------

  /// `GET /system_stats`. Also the cheapest "is this the right URL and do the
  /// credentials work" probe.
  Future<Map<String, Object?>> systemStats({bool refresh = false}) async {
    if (!refresh && _systemStats != null) return _systemStats!;
    final data = await _getJson('/system_stats');
    _systemStats = data;
    return data;
  }

  /// `GET /object_info`. 6.7 MB of JSON on a fully loaded instance, so callers
  /// are expected to cache it to disk.
  Future<Map<String, Object?>> objectInfo() async {
    final response = await _dio.get<dynamic>(profile.resolve('/object_info').toString());
    _throwIfUnauthorized(response);
    final data = response.data;
    if (data is Map) return data.cast<String, Object?>();
    throw ComfyApiException(
      '/object_info 返回了非 JSON 内容',
      statusCode: response.statusCode,
    );
  }

  /// `GET /features`, which advertises upload limits and preview support.
  Future<Map<String, Object?>> features() => _getJson('/features');

  /// `GET /queue`.
  Future<QueueState> queue() async {
    final data = await _getJson('/queue');
    return QueueState(
      running: _ids(data['queue_running']),
      pending: _ids(data['queue_pending']),
    );
  }

  // -- workflows ----------------------------------------------------------

  /// Lists a directory of saved workflows.
  ///
  /// Uses `/v2/userdata`, which returns `{name, path, type, size, modified}`
  /// entries for the whole tree. The older `/userdata` requires the directory
  /// as a query parameter and does not recurse by default.
  Future<List<Map<String, Object?>>> listUserData({String path = ''}) async {
    final data = await _getJsonList('/v2/userdata', query: {'path': path});
    return [
      for (final entry in data)
        if (entry is Map) entry.cast<String, Object?>(),
    ];
  }

  /// Reads one saved file from the user directory.
  ///
  /// ComfyUI routes this as a single path segment, so every `/` in the relative
  /// path has to be percent-encoded. Leaving them literal yields a 404, which is
  /// why `Uri` is not allowed to decide the encoding here.
  Future<Map<String, Object?>> readUserData(String relativePath) async {
    final encoded = Uri.encodeComponent(relativePath);
    final response = await _dio.get<dynamic>(
      profile.resolve('/userdata/$encoded').toString(),
    );
    _throwIfUnauthorized(response);
    if (response.statusCode == 404) {
      throw ComfyApiException(
        '找不到工作流文件: $relativePath',
        statusCode: 404,
      );
    }
    final data = response.data;
    if (data is Map) return data.cast<String, Object?>();
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return decoded.cast<String, Object?>();
    }
    throw ComfyApiException('工作流文件不是 JSON 对象: $relativePath');
  }

  /// Convenience: every `.json` workflow under `workflows/`, recursively.
  ///
  /// `/v2/userdata` already returns the **whole tree** for the requested path,
  /// directories and their files alike. Recursing into each returned directory
  /// as well therefore visits every file twice, which is exactly the duplicate
  /// entries this used to show. Deduplicating by path is the cheap guard: it
  /// keeps the call correct whether or not a given ComfyUI version recurses.
  Future<List<Map<String, Object?>>> listWorkflows() async {
    final entries = await listUserData(path: 'workflows');
    final seen = <String>{};
    final files = <Map<String, Object?>>[];
    for (final entry in entries) {
      if ('${entry['type']}' != 'file') continue;
      final name = '${entry['name']}';
      if (!name.toLowerCase().endsWith('.json') || name.startsWith('.')) {
        continue;
      }
      final path = '${entry['path']}';
      if (!seen.add(path)) continue;
      files.add(entry);
    }
    files.sort((a, b) => '${a['path']}'.compareTo('${b['path']}'));
    return files;
  }

  // -- execution ----------------------------------------------------------

  /// `POST /prompt`.
  ///
  /// Returns the prompt id the server assigned. A client-supplied
  /// `client_id` is required for progress to arrive on the matching WebSocket.
  Future<String> submitPrompt(
    Map<String, Object?> prompt, {
    required String clientId,
    String? promptId,
    int? number,
  }) async {
    final response = await _dio.post<dynamic>(
      profile.resolve('/prompt').toString(),
      data: {
        'prompt': prompt,
        'client_id': clientId,
        ?promptId: promptId,
        ?number: number,
      },
    );
    _throwIfUnauthorized(response);

    final data = response.data;
    if (response.statusCode != null &&
        response.statusCode! >= 400 &&
        data is Map) {
      final error = data['error'];
      final nodeErrors = data['node_errors'];
      throw ComfyApiException(
        error is Map ? '${error['message'] ?? '提交失败'}' : '提交失败',
        statusCode: response.statusCode,
        errorType: error is Map ? '${error['type']}' : null,
        details: error is Map ? '${error['details']}' : null,
        nodeErrors: nodeErrors is Map
            ? {for (final e in nodeErrors.entries) '${e.key}': e.value}
            : const {},
      );
    }
    if (data is Map && data['prompt_id'] is String) {
      return data['prompt_id'] as String;
    }
    throw ComfyApiException('提交成功但没有返回 prompt_id', statusCode: response.statusCode);
  }

  /// `GET /history/{promptId}`. Empty until the prompt finishes.
  Future<Map<String, Object?>?> historyEntry(String promptId) async {
    final data = await _getJson('/history/$promptId');
    final entry = data[promptId];
    if (entry is Map) return entry.cast<String, Object?>();
    return null;
  }

  /// Turns a finished history entry into an [ExecutionResult].
  Future<ExecutionResult?> pollResult(String promptId) async {
    final entry = await historyEntry(promptId);
    if (entry == null) return null;
    final outputs = entry['outputs'];
    final status = entry['status'];
    return ExecutionResult(
      promptId: promptId,
      outputs: outputs is Map ? outputs.cast<String, Object?>() : const {},
      status: status is Map ? '${status['status_str'] ?? ''}' : null,
    );
  }

  /// `GET /api/jobs/{id}`, which works for queued *and* finished jobs and is
  /// cheaper than `/history` when polling.
  Future<Map<String, Object?>?> job(String id) async {
    final response = await _dio.get<dynamic>(profile.resolve('/api/jobs/$id').toString());
    if (response.statusCode == 404) return null;
    final data = response.data;
    return data is Map ? data.cast<String, Object?>() : null;
  }

  /// `POST /interrupt`, cancelling whatever is running.
  Future<void> interrupt() async {
    await _dio.post<dynamic>(profile.resolve('/interrupt').toString());
  }

  /// Deletes queued items by prompt id.
  Future<void> cancelQueued(List<String> promptIds) async {
    await _dio.post<dynamic>(
      profile.resolve('/queue').toString(),
      data: {'delete': promptIds},
    );
  }

  /// `POST /free`, unloading models and releasing VRAM.
  Future<void> freeMemory({bool unloadModels = true, bool freeMemory = true}) async {
    await _dio.post<dynamic>(
      profile.resolve('/free').toString(),
      data: {'unload_models': unloadModels, 'free_memory': freeMemory},
    );
  }

  // -- media --------------------------------------------------------------

  /// `POST /upload/image`, returning the stored file name.
  ///
  /// The returned name may be rewritten by the server (deduplication), so the
  /// response must be used rather than the name that was sent.
  Future<String> uploadImage(
    Uint8List bytes, {
    required String filename,
    String subfolder = '',
    bool overwrite = false,
  }) async {
    final form = FormData.fromMap({
      'image': MultipartFile.fromBytes(bytes, filename: filename),
      'subfolder': subfolder,
      if (overwrite) 'overwrite': 'true',
    });
    final response = await _dio.post<dynamic>(
      profile.resolve('/upload/image').toString(),
      data: form,
    );
    _throwIfUnauthorized(response);
    final data = response.data;
    if (data is Map) {
      final name = data['name'];
      if (name is String) {
        final folder = data['subfolder'];
        return folder is String && folder.isNotEmpty ? '$folder/$name' : name;
      }
      final error = data['error'];
      throw ComfyApiException(
        error is String ? error : '上传失败',
        statusCode: response.statusCode,
      );
    }
    throw ComfyApiException('上传返回了非 JSON 内容');
  }

  /// `GET /view`, returning raw bytes.
  Future<Uint8List> view({
    required String filename,
    String subfolder = '',
    String type = 'output',
  }) async {
    final response = await _dio.get<List<int>>(
      profile.resolve('/view').toString(),
      queryParameters: {
        'filename': filename,
        if (subfolder.isNotEmpty) 'subfolder': subfolder,
        'type': type,
      },
      options: Options(responseType: ResponseType.bytes),
    );
    _throwIfUnauthorized(response);
    final data = response.data;
    if (data == null) throw ComfyApiException('下载为空: $filename');
    return Uint8List.fromList(data);
  }

  // -- websocket ----------------------------------------------------------

  /// Opens the progress stream.
  ///
  /// The handshake carries the same credentials as HTTP. That is not optional:
  /// an instance behind a token rejects the upgrade, and the only symptom is a
  /// client that generates fine but never reports progress.
  Future<WebSocketChannel> openWebSocket(String clientId) async {
    final url = profile.webSocketUrl(clientId);
    final headers = <String, dynamic>{
      ...AuthInterceptor(profile.auth).headers,
    };
    final socket = await WebSocket.connect(
      url.toString(),
      headers: headers,
      customClient: _httpClient,
    );
    final channel = IOWebSocketChannel(socket);

    // The server only sends sampler preview frames after receiving this
    // handshake; without it the stream carries progress but no images.
    channel.sink.add(jsonEncode({'type': 'feature_flags', 'data': {}}));
    return channel;
  }

  /// Reads progress events until [shouldStop] returns true or [timeout] hits.
  Stream<ExecutionProgress> progressStream(
    WebSocketChannel channel, {
    required String promptId,
  }) =>
      channel.stream
          .map((message) => _decodeProgress(message, promptId))
          .where((event) => event != null)
          .cast<ExecutionProgress>();

  ExecutionProgress? _decodeProgress(Object? message, String promptId) {
    // Binary frames carry sampler previews: a 4-byte big-endian event type,
    // then (for PREVIEW_IMAGE) a 4-byte format followed by image bytes.
    if (message is List<int>) {
      if (message.length < 8) return null;
      final view = ByteData.sublistView(Uint8List.fromList(message));
      final event = view.getUint32(0, Endian.big);
      if (event != 1) return null; // PREVIEW_IMAGE
      final format = view.getUint32(4, Endian.big);
      return ExecutionProgress(
        promptId: promptId,
        preview: Uint8List.fromList(message.sublist(8)),
        previewFormat: format,
      );
    }
    if (message is! String) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final type = '${decoded['type']}';
    final data = decoded['data'];
    if (data is! Map) return null;

    switch (type) {
      case 'progress':
        return ExecutionProgress(
          promptId: promptId,
          step: _asInt(data['value']),
          totalSteps: _asInt(data['max']),
          nodeId: data['node'] == null ? null : '${data['node']}',
        );
      case 'executing':
        final node = data['node'];
        return ExecutionProgress(
          promptId: promptId,
          nodeId: node == null ? null : '$node',
        );
      case 'progress_state':
        final nodes = data['nodes'];
        if (nodes is Map) {
          for (final entry in nodes.entries) {
            final node = entry.value;
            if (node is Map && node['state'] == 'running') {
              return ExecutionProgress(
                promptId: promptId,
                step: _asInt(node['value']),
                totalSteps: _asInt(node['max']),
                nodeId: '${entry.key}',
              );
            }
          }
        }
        return null;
      default:
        return null;
    }
  }

  // -- internals ----------------------------------------------------------

  Future<Map<String, Object?>> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _dio.get<dynamic>(
      profile.resolve(path).toString(),
      queryParameters: query,
    );
    _throwIfUnauthorized(response);
    final data = response.data;
    if (data is Map) return data.cast<String, Object?>();
    throw ComfyApiException('$path 返回了非 JSON 内容', statusCode: response.statusCode);
  }

  Future<List<Object?>> _getJsonList(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _dio.get<dynamic>(
      profile.resolve(path).toString(),
      queryParameters: query,
    );
    _throwIfUnauthorized(response);
    final data = response.data;
    if (data is List) return data;
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is List) return decoded;
    }
    throw ComfyApiException('$path 返回了非数组内容', statusCode: response.statusCode);
  }

  void _throwIfUnauthorized(Response<dynamic> response) {
    final status = response.statusCode;
    if (status == 401 || status == 403) {
      throw ComfyApiException(
        status == 401 ? '认证失败（401）：检查 API Key / Token' : '权限不足（403）',
        statusCode: status,
      );
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static List<String> _ids(Object? raw) {
    if (raw is! List) return const [];
    final ids = <String>[];
    for (final entry in raw) {
      if (entry is List && entry.length > 1) {
        ids.add('${entry[1]}');
      } else if (entry is String) {
        ids.add(entry);
      }
    }
    return ids;
  }
}
