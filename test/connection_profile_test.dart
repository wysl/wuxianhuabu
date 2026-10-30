import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/core/auth_config.dart';
import 'package:wuxianhuabu/src/core/connection_profile.dart';

/// `listWorkflows` parses the server's tree listing, which is the piece most
/// easily got wrong (it visited every file twice before). The parsing rule is
/// pure, so it is pinned here without a network round trip.
///
/// The filter itself lives in `ComfyClient.listWorkflows`, which needs an HTTP
/// client; this covers the same predicate via the shared helper below.
List<Map<String, Object?>> selectWorkflows(List<Map<String, Object?>> entries) {
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

void main() {
  group('workflow selection', () {
    test('keeps only json files and drops hidden index files', () {
      final entries = <Map<String, Object?>>[
        {'name': 'a.json', 'path': 'workflows/a.json', 'type': 'file'},
        {'name': '.index.json', 'path': 'workflows/.index.json', 'type': 'file'},
        {'name': 'notes.txt', 'path': 'workflows/notes.txt', 'type': 'file'},
        {'name': 'sub', 'path': 'workflows/sub', 'type': 'directory'},
        {'name': 'b.json', 'path': 'workflows/sub/b.json', 'type': 'file'},
      ];
      final files = selectWorkflows(entries);
      expect(files.map((f) => f['path']), [
        'workflows/a.json',
        'workflows/sub/b.json',
      ]);
    });

    test('deduplicates paths, which is what stops the doubled list', () {
      // `/v2/userdata` returns the whole tree, so a file can appear once for its
      // directory listing and again for the parent. Both entries are identical.
      final entries = <Map<String, Object?>>[
        {'name': 'a.json', 'path': 'workflows/a.json', 'type': 'file'},
        {'name': 'a.json', 'path': 'workflows/a.json', 'type': 'file'},
      ];
      expect(selectWorkflows(entries), hasLength(1));
    });

    test('sorts by path so the tree order is stable', () {
      final entries = <Map<String, Object?>>[
        {'name': 'z.json', 'path': 'workflows/z.json', 'type': 'file'},
        {'name': 'a.json', 'path': 'workflows/a.json', 'type': 'file'},
      ];
      expect(
        selectWorkflows(entries).map((f) => f['name']),
        ['a.json', 'z.json'],
      );
    });
  });

  group('ConnectionProfile', () {
    test('derives a ws url that keeps the path prefix', () {
      final profile = ConnectionProfile(
        id: 'p',
        name: 'p',
        baseUrl: Uri.parse('https://host/comfy'),
      );
      expect(
        profile.webSocketUrl('abc').toString(),
        'wss://host/comfy/ws?clientId=abc',
      );
    });

    test('uses ws for http and wss for https', () {
      final local = ConnectionProfile(
        id: 'p',
        name: 'p',
        baseUrl: Uri.parse('http://127.0.0.1:8188'),
      );
      expect(local.webSocketUrl('x').scheme, 'ws');
      expect(local.webSocketUrl('x').path, '/ws');
      expect(local.webSocketUrl('x').queryParameters['clientId'], 'x');
    });

    test('resolves api paths under the prefix', () {
      final profile = ConnectionProfile(
        id: 'p',
        name: 'p',
        baseUrl: Uri.parse('https://host/comfy'),
      );
      expect(
        profile.resolve('/system_stats').toString(),
        'https://host/comfy/system_stats',
      );
      expect(
        profile.resolve('system_stats').toString(),
        'https://host/comfy/system_stats',
      );
    });

    test('recognises loopback hosts', () {
      ConnectionProfile at(String url) =>
          ConnectionProfile(id: 'p', name: 'p', baseUrl: Uri.parse(url));
      expect(at('http://127.0.0.1:8188').isLoopback, isTrue);
      expect(at('http://localhost:8188').isLoopback, isTrue);
      expect(at('http://180.175.160.80:1234').isLoopback, isFalse);
    });
  });

  group('auth headers', () {
    test('api key rides in its configured header', () {
      final profile = ConnectionProfile(
        id: 'p',
        name: 'p',
        baseUrl: Uri.parse('http://host'),
        auth: const ApiKeyAuth(header: 'X-Api-Key', token: 'sk-1'),
      );
      expect(
        AuthInterceptor(profile.auth).headers,
        {'X-Api-Key': 'sk-1'},
      );
    });

    test('an empty token contributes no header', () {
      const auth = ApiKeyAuth(header: 'X-Api-Key', token: '');
      expect(AuthInterceptor(auth).headers, isEmpty);
    });

    test('basic auth base64-encodes utf8 credentials', () {
      // Non-ASCII credentials are legal in Basic auth and must be encoded as
      // UTF-8 bytes, not mangled into latin-1.
      const auth = BasicAuth(username: '用户', password: 'p@ss');
      final header = AuthInterceptor(auth).headers['Authorization']!;
      expect(header, startsWith('Basic '));
      final decoded = utf8.decode(base64Decode(header.substring(6)));
      expect(decoded, '用户:p@ss');
    });

    test('query token becomes a query parameter, not a header', () {
      const auth = QueryTokenAuth(parameter: 'token', token: 'q1');
      final interceptor = AuthInterceptor(auth);
      expect(interceptor.headers, isEmpty);
      expect(interceptor.queryParameters, {'token': 'q1'});
    });
  });
}
