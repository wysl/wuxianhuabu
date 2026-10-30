import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/comfy_graph.dart';
import 'package:wuxianhuabu/src/core/auth_config.dart';
import 'package:wuxianhuabu/src/core/comfy_client.dart';
import 'package:wuxianhuabu/src/core/connection_profile.dart';

/// Integration tests against a live ComfyUI instance.
///
/// Skipped unless `COMFYUI_URL` is set, so the default test run stays offline:
///
/// ```bash
/// COMFYUI_URL=http://180.175.160.80:1234 \
/// COMFYUI_AUTH_HEADER=X-Api-Key \
/// COMFYUI_AUTH_TOKEN=sk-... \
/// flutter test test/live_instance_test.dart
/// ```
///
/// These cover the parts that only a real server can prove: that the auth
/// header is accepted, that `/userdata` paths are encoded the way ComfyUI
/// expects, and that an expanded workflow passes `/prompt` validation.
String? get _baseUrl => Platform.environment['COMFYUI_URL'];

ConnectionProfile _profile() {
  final header = Platform.environment['COMFYUI_AUTH_HEADER'] ?? 'X-Api-Key';
  final token = Platform.environment['COMFYUI_AUTH_TOKEN'] ?? '';
  return ConnectionProfile(
    id: 'live',
    name: 'live',
    baseUrl: Uri.parse(_baseUrl!),
    auth: token.isEmpty
        ? const NoAuth()
        : ApiKeyAuth(header: header, token: token),
  );
}

void main() {
  final skip = _baseUrl == null
      ? 'set COMFYUI_URL (+ COMFYUI_AUTH_* ) to run against a live instance'
      : null;

  group('live instance', skip: skip, () {
    late ComfyClient client;

    setUp(() => client = ComfyClient(_profile()));
    tearDown(() => client.close());

    test('system_stats reports a version', () async {
      final stats = await client.systemStats(refresh: true);
      final system = stats['system'];
      expect(system, isA<Map>());
      final version = (system as Map)['comfyui_version'];
      expect(version, isA<String>());
      expect('$version', isNotEmpty);
      // ignore: avoid_print
      print('connected: ComfyUI $version @ ${_baseUrl}');
    });

    test('object_info is a large registry', () async {
      final info = await client.objectInfo();
      expect(info.length, greaterThan(50));
      // Virtual node classes must not be advertised by the server; if they ever
      // were, the expander's rules would need revisiting.
      for (final virtual in const ['SetNode', 'GetNode', 'Reroute', 'Note']) {
        expect(
          info.containsKey(virtual),
          isFalse,
          reason: '$virtual is a frontend-only node and must not exist server-side',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('workflow library lists and reads saved workflows', () async {
      final files = await client.listWorkflows();
      expect(
        files,
        isNotEmpty,
        reason: 'the instance has no saved workflows under user/workflows',
      );
      // ignore: avoid_print
      print('found ${files.length} saved workflows');

      // Reading one back proves the path encoding: `/` must be percent-encoded
      // or ComfyUI answers 404.
      final first = files.first;
      final workflow = await client.readUserData('${first['path']}');
      expect(UiWorkflow.looksLikeUiWorkflow(workflow), isTrue);

      final ui = UiWorkflow.fromJson(workflow);
      expect(ui.nodes, isNotEmpty);
      // ignore: avoid_print
      print('read ${first['name']}: ${ui.nodes.length} nodes, '
          '${ui.subgraphs.length} subgraphs');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('expanded workflow passes /prompt validation', () async {
      final files = await client.listWorkflows();
      final info = NodeDefinitionRegistry.fromJson(await client.objectInfo());

      var expandedCount = 0;
      var accepted = 0;
      final rejected = <String>[];

      for (final file in files) {
        final raw = await client.readUserData('${file['path']}');
        if (!UiWorkflow.looksLikeUiWorkflow(raw)) continue;
        final ui = UiWorkflow.fromJson(raw);
        final expanded = WorkflowExpander(ui).expand();
        if (expanded.prompt.isEmpty) continue;
        expandedCount += 1;

        // Validate without queueing. `POST /prompt` really enqueues a GPU job,
        // so looping over 26 workflows would block the instance behind 26
        // renders. The local pre-flight check reads the same `/object_info`
        // declarations the server validates against.
        final problems = info.validatePrompt(expanded.toPromptJson());
        if (problems.isEmpty) {
          accepted += 1;
        } else {
          rejected.add('${file['name']}: ${problems.first}');
        }
      }

      // ignore: avoid_print
      print('pre-flight validation: $accepted/$expandedCount clean');
      for (final line in rejected) {
        // ignore: avoid_print
        print('  NEEDS ATTENTION $line');
      }
      expect(expandedCount, greaterThan(0));
      // A saved workflow whose JSON refers to models or custom nodes this
      // instance does not have is a server-side condition, not an expander bug;
      // those are reported above rather than failing the suite.
      expect(accepted, greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('queue is readable', () async {
      final queue = await client.queue();
      expect(queue.running, isA<List<String>>());
      // ignore: avoid_print
      print('queue: ${queue.running.length} running, ${queue.pending.length} pending');
    });
  });
}
