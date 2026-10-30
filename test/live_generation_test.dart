import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/core/auth_config.dart';
import 'package:wuxianhuabu/src/core/comfy_client.dart';
import 'package:wuxianhuabu/src/core/comfy_workflow_service.dart';
import 'package:wuxianhuabu/src/core/connection_profile.dart';

/// Full round trip against a live instance: read a saved workflow, expand it,
/// edit a parameter, submit it, watch it, and download the produced image.
///
/// Opt-in, because it really runs a GPU job:
///
/// ```bash
/// COMFYUI_URL=http://host:1234 COMFYUI_AUTH_TOKEN=... \
/// COMFYUI_GENERATE=1 flutter test test/live_generation_test.dart
/// ```
///
/// Without `COMFYUI_GENERATE` the suite is skipped entirely: generating costs
/// minutes of GPU time and should never happen as a side effect of `flutter
/// test`.
String? get _baseUrl => Platform.environment['COMFYUI_URL'];
bool get _enabled => Platform.environment['COMFYUI_GENERATE'] == '1';

void main() {
  final skip = (_baseUrl == null || !_enabled)
      ? 'set COMFYUI_URL + COMFYUI_AUTH_TOKEN + COMFYUI_GENERATE=1 to run'
      : null;

  group('live generation', skip: skip, () {
    late ComfyClient client;
    late ComfyWorkflowService service;

    setUp(() {
      final token = Platform.environment['COMFYUI_AUTH_TOKEN'] ?? '';
      final header = Platform.environment['COMFYUI_AUTH_HEADER'] ?? 'X-Api-Key';
      client = ComfyClient(ConnectionProfile(
        id: 'live',
        name: 'live',
        baseUrl: Uri.parse(_baseUrl!),
        auth: token.isEmpty
            ? const NoAuth()
            : ApiKeyAuth(header: header, token: token),
      ));
      service = ComfyWorkflowService(client);
    });

    tearDown(() => client.close());

    test('expand, submit, track and download', () async {
      // Pick the first saved workflow that passes pre-flight, so the test does
      // not fail on an instance whose JSON happens to reference missing models.
      final files = await client.listWorkflows();
      PreparedWorkflow? chosen;
      for (final file in files) {
        try {
          final prepared =
              await service.prepareFromServer('${file['path']}');
          if (prepared.preflightProblems.isEmpty) {
            chosen = prepared;
            break;
          }
        } on PrepareException {
          continue;
        }
      }
      expect(
        chosen,
        isNotNull,
        reason: 'no saved workflow on this instance passes pre-flight',
      );
      final prepared = chosen!;
      // ignore: avoid_print
      print('using ${prepared.name}: ${prepared.nodeCount} nodes, '
          '${prepared.parameters.length} parameters');

      // A seed parameter is the safest thing to change: it is present on almost
      // every workflow and cannot invalidate a model name.
      final values = <String, Object?>{};
      for (final parameter in prepared.parameters) {
        if (parameter.name == 'seed' || parameter.name == 'noise_seed') {
          values[parameter.key] = 424242;
          break;
        }
      }

      final run = await service.submit(
        prepared,
        values: values,
        clientId: 'wuxianhuabu-live-generation',
      );
      // ignore: avoid_print
      print('submitted ${run.promptId}');

      GenerationRun? last;
      await for (final update in service.watch(
        run,
        pollInterval: const Duration(seconds: 2),
      )) {
        last = update;
      }

      expect(last, isNotNull);
      expect(last!.error, isNull, reason: 'run failed: ${last.error}');
      expect(last.result, isNotNull, reason: 'run produced no result');

      final media = last.result!.media;
      expect(media, isNotEmpty, reason: 'workflow produced no output files');
      // ignore: avoid_print
      print('produced ${media.length} file(s): ${media.first['filename']}');

      final bytes = await service.fetchMedia(media.first);
      expect(bytes.length, greaterThan(1024), reason: 'downloaded file is empty');
      // ignore: avoid_print
      print('downloaded ${bytes.length} bytes');
    }, timeout: const Timeout(Duration(minutes: 30)));
  });
}
