
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/comfy_client.dart';
import '../core/comfy_workflow_service.dart';
import '../core/connection_profile.dart';

/// The currently selected connection, or `null` before one exists.
///
/// Kept in a single provider so that changing the server tears down every
/// dependent client rather than leaving a stale one pointing at the old host.
final activeProfileProvider =
    NotifierProvider<ActiveProfileNotifier, ConnectionProfile?>(
        ActiveProfileNotifier.new);

class ActiveProfileNotifier extends Notifier<ConnectionProfile?> {
  @override
  ConnectionProfile? build() => null;

  set profile(ConnectionProfile? value) => state = value;
}

/// The client for the active profile.
///
/// Disposed with its profile: a `ComfyClient` owns an `HttpClient` and a dio
/// instance, and leaking either keeps sockets alive after a server switch.
final comfyClientProvider = Provider<ComfyClient?>((ref) {
  final profile = ref.watch(activeProfileProvider);
  if (profile == null) return null;
  final client = ComfyClient(profile);
  ref.onDispose(client.close);
  return client;
});

/// The workflow service (expansion, submission, tracking) for the active client.
final workflowServiceProvider = Provider<ComfyWorkflowService?>((ref) {
  final client = ref.watch(comfyClientProvider);
  if (client == null) return null;
  return ComfyWorkflowService(client);
});
