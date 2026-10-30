/// How to authenticate against a ComfyUI instance.
///
/// ComfyUI itself ships no authentication (`server.py` has no auth middleware),
/// so every deployment that is not on localhost puts something in front of it.
/// The shapes below cover what those layers actually use:
///
///  * nothing — the default local install
///  * `X-Api-Key` — the gateway in front of the instance this was built against
///  * HTTP Basic — nginx `auth_basic`
///  * Bearer — `ComfyUI-Login`, assorted gateways
///  * custom headers — Cloudflare Access (`CF-Access-Client-Id/Secret`) and
///    similar edge proxies
///  * query token — `ComfyUI-Login`'s `?token=` fallback
///  * cookie session — `ComfyUI-Login`'s `POST /login` form flow
library;

/// Base type for the authentication strategies.
sealed class AuthConfig {
  const AuthConfig();

  /// Human label for the settings UI.
  String get label;

  /// True when this strategy needs an interactive login step before use.
  bool get requiresLogin => false;

  Map<String, Object?> toJson();

  static AuthConfig fromJson(Map<String, Object?> raw) {
    final kind = '${raw['kind'] ?? 'none'}';
    return switch (kind) {
      'api_key' => ApiKeyAuth(
          header: '${raw['header'] ?? 'X-Api-Key'}',
          token: '${raw['token'] ?? ''}',
        ),
      'basic' => BasicAuth(
          username: '${raw['username'] ?? ''}',
          password: '${raw['password'] ?? ''}',
        ),
      'bearer' => BearerAuth('${raw['token'] ?? ''}'),
      'headers' => CustomHeadersAuth({
          for (final entry in ((raw['headers'] as Map?) ?? const {}).entries)
            '${entry.key}': '${entry.value}',
        }),
      'query' => QueryTokenAuth(
          parameter: '${raw['parameter'] ?? 'token'}',
          token: '${raw['token'] ?? ''}',
        ),
      'cookie' => CookieLoginAuth(
          loginPath: '${raw['login_path'] ?? '/login'}',
          usernameField: '${raw['username_field'] ?? 'username'}',
          passwordField: '${raw['password_field'] ?? 'password'}',
          username: '${raw['username'] ?? ''}',
          password: '${raw['password'] ?? ''}',
        ),
      _ => const NoAuth(),
    };
  }
}

/// No authentication; the default for a local install.
class NoAuth extends AuthConfig {
  const NoAuth();

  @override
  String get label => '无认证';

  @override
  Map<String, Object?> toJson() => {'kind': 'none'};
}

/// A single fixed header carrying a token.
///
/// This is the shape used by the instance this project was developed against:
/// `X-Api-Key: sk-...`. Requests without it get 401.
class ApiKeyAuth extends AuthConfig {
  const ApiKeyAuth({required this.header, required this.token});

  final String header;
  final String token;

  @override
  String get label => 'API Key（$header）';

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'api_key', 'header': header, 'token': token};
}

/// HTTP Basic, as nginx `auth_basic` expects.
class BasicAuth extends AuthConfig {
  const BasicAuth({required this.username, required this.password});

  final String username;
  final String password;

  @override
  String get label => 'HTTP Basic';

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'basic', 'username': username, 'password': password};
}

/// `Authorization: Bearer <token>`.
class BearerAuth extends AuthConfig {
  const BearerAuth(this.token);

  final String token;

  @override
  String get label => 'Bearer Token';

  @override
  Map<String, Object?> toJson() => {'kind': 'bearer', 'token': token};
}

/// Arbitrary headers, for edge proxies such as Cloudflare Access.
class CustomHeadersAuth extends AuthConfig {
  const CustomHeadersAuth(this.headers);

  final Map<String, String> headers;

  @override
  String get label => '自定义请求头';

  @override
  Map<String, Object?> toJson() => {'kind': 'headers', 'headers': headers};
}

/// A token passed as a query parameter (`?token=...`).
///
/// ComfyUI-Login accepts this as a fallback when an `Authorization` header is
/// unavailable, which matters for WebSocket clients that cannot set headers.
class QueryTokenAuth extends AuthConfig {
  const QueryTokenAuth({required this.parameter, required this.token});

  final String parameter;
  final String token;

  @override
  String get label => '查询参数 Token';

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'query', 'parameter': parameter, 'token': token};
}

/// Form login producing a session cookie.
class CookieLoginAuth extends AuthConfig {
  const CookieLoginAuth({
    required this.loginPath,
    required this.usernameField,
    required this.passwordField,
    required this.username,
    required this.password,
  });

  final String loginPath;
  final String usernameField;
  final String passwordField;
  final String username;
  final String password;

  @override
  String get label => 'Cookie 会话登录';

  @override
  bool get requiresLogin => true;

  @override
  Map<String, Object?> toJson() => {
        'kind': 'cookie',
        'login_path': loginPath,
        'username_field': usernameField,
        'password_field': passwordField,
        'username': username,
        'password': password,
      };
}
