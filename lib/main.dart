import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/connection_profile.dart';
import 'src/state/connection_providers.dart';
import 'src/state/profile_store.dart';
import 'src/ui/connection_screen.dart';
import 'src/ui/workbench_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: WuxianhuabuApp()));
}

class WuxianhuabuApp extends StatelessWidget {
  const WuxianhuabuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '无界画布',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4C6EF5),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const _Root(),
    );
  }
}

/// Restores the last connection on launch, otherwise shows setup.
///
/// Re-entering a server address and token on every launch is the kind of
/// friction that makes a desktop tool feel like a web page. The saved profile is
/// verified in the background: if it stopped working, the workbench says so and
/// offers a way back to setup rather than failing silently.
class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> {
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = await ProfileStore().load();
      if (saved.isNotEmpty && mounted) {
        // The most recently saved profile is the one to resume.
        ref.read(activeProfileProvider.notifier).profile = saved.last;
      }
    } on Object {
      // A config that cannot be read is not fatal; setup is still reachable.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final profile = ref.watch(activeProfileProvider);
    if (profile == null) {
      return const ConnectionScreen();
    }
    return WorkbenchScreen(profile: profile);
  }
}

/// Convenience used by the connection screen when a profile is saved.
extension ActiveProfileWrite on WidgetRef {
  void connect(ConnectionProfile profile) =>
      read(activeProfileProvider.notifier).profile = profile;
}
