import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth_config.dart';
import '../core/comfy_client.dart';
import '../core/connection_profile.dart';
import '../state/connection_providers.dart';
import '../state/profile_store.dart';

/// Connection setup: pick a server, prove it answers, and remember it.
///
/// The "test" button is not decoration. The two failures that actually happen
/// here — a wrong token and a path-prefixed reverse proxy — both produce a
/// working-looking URL that fails on the first real request, so the editor
/// refuses to move on without a successful probe.
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key, this.onConnected});

  final ValueChanged<ConnectionProfile>? onConnected;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _urlController = TextEditingController(text: 'http://127.0.0.1:8188');
  final _nameController = TextEditingController(text: '本地 ComfyUI');
  final _tokenController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  AuthKind _authKind = AuthKind.apiKey;
  bool _busy = false;
  String? _error;
  String? _success;
  List<ConnectionProfile> _saved = const [];

  final _store = ProfileStore();

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final saved = await _store.load();
    if (!mounted) return;
    setState(() => _saved = saved);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _tokenController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  AuthConfig _buildAuth() => switch (_authKind) {
        AuthKind.none => const NoAuth(),
        AuthKind.apiKey => ApiKeyAuth(
            // Tokens travel in a header, and `HttpClient` throws on any
            // non-ASCII byte. Trimming and stripping those here keeps a bad
            // paste from surfacing as an unintelligible transport error.
            header: 'X-Api-Key',
            token: _sanitiseToken(_tokenController.text),
          ),
        AuthKind.bearer => BearerAuth(_sanitiseToken(_tokenController.text)),
        AuthKind.basic => BasicAuth(
            username: _userController.text,
            password: _passwordController.text,
          ),
      };

  /// Removes whitespace and anything outside visible ASCII.
  static String _sanitiseToken(String raw) =>
      raw.replaceAll(RegExp(r'[^\x21-\x7E]'), '');

  Future<ConnectionProfile?> _connect({required bool persist}) async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    ComfyClient? client;
    try {
      final url = _urlController.text.trim();
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        throw const FormatException('地址无效，应为 http://主机:端口');
      }
      final profile = ConnectionProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: _nameController.text.trim().isEmpty
            ? uri.host
            : _nameController.text.trim(),
        baseUrl: uri,
        auth: _buildAuth(),
      );
      client = ComfyClient(profile);
      final stats = await client.systemStats(refresh: true);
      final system = stats['system'];
      final version = system is Map ? '${system['comfyui_version'] ?? '?'}' : '?';
      if (mounted) {
        setState(() => _success = '连接成功 · ComfyUI $version');
      }
      if (persist) {
        final saved = [..._saved.where((p) => p.baseUrl != profile.baseUrl), profile];
        await _store.save(saved);
        if (mounted) setState(() => _saved = saved);
      }
      if (mounted) {
        ref.read(activeProfileProvider.notifier).profile = profile;
        widget.onConnected?.call(profile);
      }
      return profile;
    } on ComfyApiException catch (error) {
      // Wrong token, wrong path prefix, or a reachable host that is not a
      // ComfyUI instance. The exception carries the server's own reason.
      if (mounted) setState(() => _error = error.toString());
      return null;
    } on SocketException catch (error) {
      if (mounted) {
        setState(() => _error = '无法连接：${error.message}\n'
            '检查地址、端口，以及 ComfyUI 是否以 --listen 启动');
      }
      return null;
    } on Object catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
      return null;
    } finally {
      client?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Turns a transport-level failure into something a user can act on.
  ///
  /// `DioException` prints as `[unknown]: null` with a nested `FormatException`
  /// when a header contains characters HTTP forbids, which is what happens when
  /// a token is pasted with a stray non-ASCII character. Showing the raw
  /// exception hides the one thing worth knowing: the credential itself is
  /// malformed, so no server was even contacted.
  static String _friendlyError(Object error) {
    final text = '$error';
    if (text.contains('Invalid HTTP header field value') ||
        text.contains('FormatException')) {
      return '认证信息包含 HTTP 不允许的字符（例如全角标点或中文）。'
          '请重新粘贴 Token，确保只包含字母、数字和 - _ 等 ASCII 字符。';
    }
    if (text.contains('Timeout') || text.contains('timeout')) {
      return '连接超时。检查网络是否可达，以及端口是否正确。';
    }
    if (text.contains('HandshakeException')) {
      return 'TLS 握手失败。如果是自签名证书，请在配置里允许自签名。';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('无界画布', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text(
                  '连接一个 ComfyUI 实例（本地或远程）',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: '地址',
                    hintText: 'http://127.0.0.1:8188',
                    border: OutlineInputBorder(),
                    helperText: '支持反向代理路径前缀，例如 https://host/comfy',
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<AuthKind>(
                  initialValue: _authKind,
                  decoration: const InputDecoration(
                    labelText: '认证方式',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final kind in AuthKind.values)
                      DropdownMenuItem(value: kind, child: Text(kind.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _authKind = value);
                  },
                ),
                const SizedBox(height: 12),
                if (_authKind == AuthKind.apiKey ||
                    _authKind == AuthKind.bearer)
                  TextField(
                    controller: _tokenController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _authKind == AuthKind.apiKey
                          ? 'X-Api-Key'
                          : 'Bearer Token',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                if (_authKind == AuthKind.basic) ...[
                  TextField(
                    controller: _userController,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_authKind == AuthKind.none)
                  Text(
                    'ComfyUI 本身不提供认证。仅在本机或可信内网下使用此选项。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : () => _connect(persist: true),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('连接并保存'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _connect(persist: false),
                      child: const Text('仅测试'),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _Banner(
                    icon: Icons.error_outline,
                    color: theme.colorScheme.error,
                    text: _error!,
                  ),
                ],
                if (_success != null) ...[
                  const SizedBox(height: 16),
                  _Banner(
                    icon: Icons.check_circle_outline,
                    color: theme.colorScheme.primary,
                    text: _success!,
                  ),
                ],
                if (_saved.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text('已保存', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final profile in _saved)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(profile.name),
                      subtitle: Text(profile.baseUrl.toString()),
                      trailing: Text(profile.auth.label),
                      onTap: () {
                        setState(() {
                          _urlController.text = profile.baseUrl.toString();
                          _nameController.text = profile.name;
                          _success = '已载入配置，点「连接并保存」验证';
                          _error = null;
                        });
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The authentication strategies offered in the UI.
///
/// `CookieLoginAuth` and `CustomHeadersAuth` exist in the model because the
/// transport supports them, but they are configured through settings JSON
/// rather than this form: a login form with configurable field names is not
/// worth the screen space for something ComfyUI-Login is the only user of.
enum AuthKind {
  none('无认证'),
  apiKey('API Key（X-Api-Key）'),
  bearer('Bearer Token'),
  basic('HTTP Basic');

  const AuthKind(this.label);

  final String label;
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(text)),
          ],
        ),
      );
}
