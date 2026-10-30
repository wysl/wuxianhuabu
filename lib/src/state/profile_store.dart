import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/auth_config.dart';
import '../core/connection_profile.dart';

/// Persists connection profiles.
///
/// Tokens go into `flutter_secure_storage` (Windows Credential Manager + AES-GCM
/// file, macOS Keychain) and everything else into a plain JSON file. That split
/// matters: a config file that is easy to share or back up must not be the
/// thing that carries an API key.
class ProfileStore {
  ProfileStore({this.overridesDirectory});

  /// Test hook: point storage at a temp directory.
  final Directory? overridesDirectory;

  static const _fileName = 'profiles.json';

  Future<Directory> _directory() async {
    final override = overridesDirectory;
    if (override != null) return override;
    // `getApplicationSupportDirectory` already resolves to an app-specific
    // directory (`%APPDATA%/<org>/<app>` on Windows,
    // `~/Library/Application Support/<bundle-id>` on macOS). Appending another
    // folder here used to bury the file one level deeper than the code that
    // read it, so the saved list silently came back empty.
    final base = await getApplicationSupportDirectory();
    if (!base.existsSync()) base.createSync(recursive: true);
    return base;
  }

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  /// Loads every saved profile. A corrupt file yields an empty list rather than
  /// an exception: being unable to read settings must not prevent the app from
  /// starting.
  Future<List<ConnectionProfile>> load() async {
    final file = await _file();
    if (!file.existsSync()) return const [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return const [];
      return [
        for (final entry in raw)
          if (entry is Map)
            ConnectionProfile.fromJson(entry.cast<String, Object?>()),
      ];
    } on Object {
      return const [];
    }
  }

  /// Writes the profile list, replacing the file atomically so a crash cannot
  /// leave a half-written config behind.
  Future<void> save(List<ConnectionProfile> profiles) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert([
        for (final profile in profiles) profile.toJson(),
      ]),
      flush: true,
    );
    if (file.existsSync()) await file.delete();
    await temp.rename(file.path);
  }

  /// Whether a profile needs a secret the store cannot persist in plain JSON.
  static bool carriesSecret(ConnectionProfile profile) =>
      profile.auth is! NoAuth;
}
