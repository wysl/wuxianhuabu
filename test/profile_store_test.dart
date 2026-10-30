import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/core/auth_config.dart';
import 'package:wuxianhuabu/src/core/connection_profile.dart';
import 'package:wuxianhuabu/src/state/profile_store.dart';

void main() {
  late Directory temp;
  late ProfileStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wuxianhuabu_profiles_');
    store = ProfileStore(overridesDirectory: temp);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ConnectionProfile profile({
    String id = 'p1',
    AuthConfig auth = const NoAuth(),
  }) =>
      ConnectionProfile(
        id: id,
        name: '远程实例',
        baseUrl: Uri.parse('http://180.175.160.80:1234'),
        auth: auth,
      );

  test('saves and reloads a profile with its auth strategy', () async {
    await store.save([
      profile(
        auth: const ApiKeyAuth(header: 'X-Api-Key', token: 'sk-test-123'),
      ),
    ]);

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.name, '远程实例');
    expect(loaded.single.baseUrl.toString(), 'http://180.175.160.80:1234');
    // The concrete auth type has to survive: a reloaded profile that degrades
    // to NoAuth would silently start getting 401s.
    expect(loaded.single.auth, isA<ApiKeyAuth>());
    final auth = loaded.single.auth as ApiKeyAuth;
    expect(auth.header, 'X-Api-Key');
    expect(auth.token, 'sk-test-123');
  });

  test('round-trips every auth strategy', () async {
    await store.save([
      profile(id: 'none'),
      profile(id: 'basic', auth: const BasicAuth(username: 'u', password: 'p')),
      profile(id: 'bearer', auth: const BearerAuth('t')),
      profile(
        id: 'headers',
        auth: const CustomHeadersAuth({'CF-Access-Client-Id': 'x'}),
      ),
      profile(id: 'query', auth: const QueryTokenAuth(parameter: 'token', token: 'q')),
      profile(
        id: 'cookie',
        auth: const CookieLoginAuth(
          loginPath: '/login',
          usernameField: 'username',
          passwordField: 'password',
          username: 'u',
          password: 'p',
        ),
      ),
    ]);

    final loaded = await store.load();
    expect(loaded, hasLength(6));
    final byId = {for (final p in loaded) p.id: p.auth};
    expect(byId['none'], isA<NoAuth>());
    expect(byId['basic'], isA<BasicAuth>());
    expect(byId['bearer'], isA<BearerAuth>());
    expect(byId['headers'], isA<CustomHeadersAuth>());
    expect(byId['query'], isA<QueryTokenAuth>());
    expect(byId['cookie'], isA<CookieLoginAuth>());
  });

  test('writes directly into the resolved directory', () async {
    await store.save([profile()]);
    // Regression: an extra path segment used to separate the writer from the
    // reader, so the saved list silently came back empty on restart.
    final file = File('${temp.path}/profiles.json');
    expect(file.existsSync(), isTrue);
    expect(
      temp.listSync().whereType<File>().map((f) => f.path),
      isNot(contains(endsWith('.tmp'))),
    );
  });

  test('a missing file loads as an empty list', () async {
    expect(await store.load(), isEmpty);
  });

  test('a corrupt file loads as an empty list instead of throwing', () async {
    File('${temp.path}/profiles.json').writeAsStringSync('not json at all');
    expect(await store.load(), isEmpty);
  });

  test('save replaces the previous contents', () async {
    await store.save([profile(id: 'a')]);
    await store.save([profile(id: 'b')]);
    final loaded = await store.load();
    expect(loaded.map((p) => p.id), ['b']);
  });
}
