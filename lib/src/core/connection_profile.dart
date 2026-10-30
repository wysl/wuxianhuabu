import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'auth_config.dart';

/// A ComfyUI endpoint plus the credentials needed to reach it.
///
/// Local and remote instances are the same thing to the client: only the URL
/// and the auth strategy differ. That is deliberate — every code path below is
/// exercised against a remote instance during development, so the local case
/// cannot rot.
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.auth = const NoAuth(),
    this.allowSelfSignedTls = false,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 120),
  });

  final String id;
  final String name;

  /// Base HTTP URL, e.g. `http://127.0.0.1:8188`.
  final Uri baseUrl;

  final AuthConfig auth;

  /// Accept a self-signed certificate. Off by default: turning it on should be
  /// a deliberate act, not something a misconfiguration silently does.
  final bool allowSelfSignedTls;

  final Duration connectTimeout;
  final Duration receiveTimeout;

  bool get isLoopback =>
      baseUrl.host == '127.0.0.1' ||
      baseUrl.host == 'localhost' ||
      baseUrl.host == '::1';

  /// The `ws(s)://` URL the progress stream is read from.
  ///
  /// ComfyUI expects `/ws?clientId=...`; the client id has to match the
  /// `client_id` sent with `POST /prompt` or no progress arrives.
  Uri webSocketUrl(String clientId) => baseUrl.replace(
        scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
        path: '${_trimmedPath()}/ws',
        queryParameters: {'clientId': clientId},
      );

  String _trimmedPath() {
    final path = baseUrl.path;
    if (path.isEmpty || path == '/') return '';
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  /// Resolves an API path against this base URL, preserving any reverse-proxy
  /// path prefix (e.g. `https://host/comfy`).
  Uri resolve(String path) {
    final suffix = path.startsWith('/') ? path : '/$path';
    return baseUrl.replace(path: '${_trimmedPath()}$suffix');
  }

  ConnectionProfile copyWith({
    String? id,
    String? name,
    Uri? baseUrl,
    AuthConfig? auth,
    bool? allowSelfSignedTls,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) =>
      ConnectionProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        auth: auth ?? this.auth,
        allowSelfSignedTls: allowSelfSignedTls ?? this.allowSelfSignedTls,
        connectTimeout: connectTimeout ?? this.connectTimeout,
        receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'base_url': baseUrl.toString(),
        'auth': auth.toJson(),
        'allow_self_signed_tls': allowSelfSignedTls,
      };

  static ConnectionProfile fromJson(Map<String, Object?> raw) => ConnectionProfile(
        id: '${raw['id']}',
        name: '${raw['name'] ?? raw['id']}',
        baseUrl: Uri.parse('${raw['base_url']}'),
        auth: AuthConfig.fromJson(
          (raw['auth'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
        allowSelfSignedTls: raw['allow_self_signed_tls'] == true,
      );
}

/// Applies a [AuthConfig] to outgoing HTTP requests and WebSocket handshakes.
///
/// One place for both transports matters: an instance behind a token rejects
/// the *WebSocket* handshake too, and a client that only authenticates HTTP
/// silently loses progress reporting while still generating fine. That failure
/// is hard to notice, so it is handled here rather than per-call-site.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this.config);

  final AuthConfig config;

  /// Headers to attach to an HTTP request.
  Map<String, String> get headers => switch (config) {
        NoAuth() => const {},
        ApiKeyAuth(:final header, :final token) =>
          token.isEmpty ? const {} : {header: token},
        BasicAuth(:final username, :final password) => {
            'Authorization':
                'Basic ${base64Encode(utf8.encode('$username:$password'))}',
          },
        BearerAuth(:final token) =>
          token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
        CustomHeadersAuth(:final headers) => headers,
        QueryTokenAuth() => const {},
        CookieLoginAuth() => const {},
      };

  /// Query parameters to attach, for strategies that ride in the URL.
  Map<String, String> get queryParameters => switch (config) {
        QueryTokenAuth(:final parameter, :final token) =>
          token.isEmpty ? const {} : {parameter: token},
        _ => const {},
      };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.addAll(headers);
    if (queryParameters.isNotEmpty) {
      options.queryParameters.addAll(queryParameters);
    }
    handler.next(options);
  }
}

/// Builds the `HttpClient` used by both dio and the WebSocket handshake.
///
/// The same instance semantics are needed on both transports because a
/// self-signed certificate has to be accepted (or refused) consistently;
/// otherwise HTTP works while the WebSocket quietly fails and the UI shows no
/// progress with no error.
HttpClient buildHttpClient(ConnectionProfile profile) {
  final client = HttpClient()
    ..connectionTimeout = profile.connectTimeout
    ..userAgent = 'wuxianhuabu/0.1';
  if (profile.allowSelfSignedTls) {
    client.badCertificateCallback = (cert, host, port) => true;
  }
  return client;
}

/// A dio instance wired for [profile].
Dio buildDio(ConnectionProfile profile) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: profile.connectTimeout,
      receiveTimeout: profile.receiveTimeout,
      // ComfyUI answers with 4xx JSON bodies that carry actionable
      // `node_errors`; those must be readable, not thrown away.
      validateStatus: (status) => status != null && status < 500,
      responseType: ResponseType.json,
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => buildHttpClient(profile),
  );
  dio.interceptors.add(AuthInterceptor(profile.auth));
  return dio;
}
