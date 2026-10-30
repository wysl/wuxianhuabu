import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/canvas_store.dart';

/// The canvas document currently being edited.
///
/// The board mutates its own card list for smooth dragging; this notifier holds
/// the *identity* of the project (id, name, provenance) and owns the autosave, so
/// persistence survives a workflow switch.
class CanvasSession {
  const CanvasSession({
    required this.projectId,
    required this.name,
    required this.workflowPath,
    this.dirty = false,
  });

  final String projectId;
  final String name;
  final String workflowPath;
  final bool dirty;

  CanvasSession copyWith({String? name, bool? dirty}) => CanvasSession(
        projectId: projectId,
        name: name ?? this.name,
        workflowPath: workflowPath,
        dirty: dirty ?? this.dirty,
      );
}

final canvasSessionProvider =
    NotifierProvider<CanvasSessionNotifier, CanvasSession?>(
  CanvasSessionNotifier.new,
);

class CanvasSessionNotifier extends Notifier<CanvasSession?> {
  CanvasAutosave? _autosave;

  @override
  CanvasSession? build() {
    ref.onDispose(() => _autosave?.dispose());
    return null;
  }

  CanvasStore get _store {
    _autosave ??= CanvasAutosave(CanvasStore());
    return _autosave!.store;
  }

  /// Starts (or restarts) a session for a workflow, reusing the stored document
  /// when one exists so a second visit keeps the previous layout.
  Future<void> openFor(String workflowPath, String name) async {
    final id = workflowPath
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final existing = await _store.load(id);
    state = CanvasSession(
      projectId: existing?.id ?? id,
      name: existing?.name ?? name,
      workflowPath: workflowPath,
    );
  }

  /// Persists the given cards, debounced by [CanvasAutosave].
  void persist(List<dynamic> cards) {
    final session = state;
    if (session == null) return;
    final autosave = _autosave ??= CanvasAutosave(CanvasStore());
    autosave.schedule(
      CanvasProject(
        id: session.projectId,
        name: session.name,
        cards: cards.cast(),
        workflowPath: session.workflowPath,
      ),
    );
  }

  /// Forces a write, for closing the window or switching workflows.
  Future<void> flush() async => _autosave?.flush();

  // ignore: unused_element
  CanvasStore get store => _store;
}
