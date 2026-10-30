import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../canvas/canvas_document.dart';
import '../canvas/canvas_repository.dart';

const _uuid = Uuid();

final canvasRepositoryProvider = Provider<CanvasRepository>((ref) {
  final repository = CanvasRepository();
  ref.onDispose(() {});
  return repository;
});

/// The canvas being edited.
///
/// The board renders from this; every mutation goes through a method here so
/// autosave has a single choke point and the undo-able operations stay explicit.
class CanvasController extends Notifier<CanvasDocument?> {
  CanvasAutosave? _autosave;
  bool _loading = false;

  bool get isLoading => _loading;

  @override
  CanvasDocument? build() {
    final repository = ref.watch(canvasRepositoryProvider);
    _autosave = CanvasAutosave(repository);
    ref.onDispose(() {
      // A pending debounce must not be lost when the provider goes away.
      _autosave?.flush();
      _autosave?.dispose();
    });
    return null;
  }

  CanvasAutosave get _saver => _autosave!;

  // -- lifecycle ------------------------------------------------------

  /// Opens the most recent canvas, or starts a fresh one when there is none.
  Future<void> restoreOrCreate() async {
    if (state != null || _loading) return;
    _loading = true;
    try {
      final stored = await ref.read(canvasRepositoryProvider).list();
      if (stored.isNotEmpty) {
        state = stored.first;
      } else {
        state = _blank();
      }
    } finally {
      _loading = false;
    }
    await _saver.flush();
  }

  Future<void> open(String id) async {
    final document = await ref.read(canvasRepositoryProvider).load(id);
    if (document == null) return;
    await _saver.flush();
    state = document;
  }

  Future<void> createNew({String name = '无界画布'}) async {
    await _saver.flush();
    state = _blank(name: name);
    await _saver.flush();
  }

  CanvasDocument _blank({String name = '无界画布'}) => CanvasDocument(
        id: 'canvas-${DateTime.now().millisecondsSinceEpoch}',
        nodes: [],
        edges: [],
        title: name,
      );

  void _changed() {
    final document = state;
    if (document == null) return;
    // `state` is the same instance; Riverpod needs a distinct value to rebuild,
    // so mutations bump a revision the UI can watch cheaply.
    state = CanvasDocument(
      id: document.id,
      title: document.title,
      nodes: document.nodes,
      edges: document.edges,
      scale: document.scale,
      offset: document.offset,
      revision: document.revision + 1,
      updatedAt: DateTime.now(),
    );
    _saver.schedule(state!);
  }

  Future<void> flush() => _saver.flush();

  // -- viewport -------------------------------------------------------

  void setViewport(Offset offset, double scale) {
    final document = state;
    if (document == null) return;
    document.offset = offset;
    document.scale = scale;
    // Viewport is saved, but a pan is not worth a rebuild of the whole board.
    _saver.schedule(document);
  }

  // -- nodes ----------------------------------------------------------

  /// Adds a node of [kind] centred in the visible area.
  CanvasNode addNode(
    CanvasNodeKind kind, {
    required Offset worldCenter,
    Offset? position,
    Map<String, Object?> metadata = const {},
    String content = '',
  }) {
    final document = state ?? (_blank());
    final origin = position ??
        Offset(
          worldCenter.dx - kind.defaultWidth / 2,
          worldCenter.dy - kind.defaultHeight / 2,
        );
    final node = CanvasNode(
      id: _uuid.v4(),
      kind: kind,
      position: origin,
      size: Size(kind.defaultWidth, kind.defaultHeight),
      content: content,
      metadata: metadata,
      zIndex: document.nodes.length,
    );
    document.nodes.add(node);
    if (state == null) {
      state = document;
    }
    _changed();
    return node;
  }

  void moveNode(String id, Offset position) {
    final node = state?.nodeById(id);
    if (node == null) return;
    node.position = position;
    _changed();
  }

  void resizeNode(String id, Size size) {
    final node = state?.nodeById(id);
    if (node == null) return;
    node.size = Size(max(160, size.width), max(100, size.height));
    _changed();
  }

  void updateNode(String id, void Function(CanvasNode node) mutate) {
    final node = state?.nodeById(id);
    if (node == null) return;
    mutate(node);
    _changed();
  }

  void removeNode(String id) {
    final document = state;
    if (document == null) return;
    document.nodes.removeWhere((node) => node.id == id);
    // A dangling edge would render to nowhere and break the config's inputs.
    document.edges.removeWhere(
      (edge) => edge.fromNodeId == id || edge.toNodeId == id,
    );
    _changed();
  }

  // -- edges ----------------------------------------------------------

  bool canConnect(String fromNodeId, String toNodeId) {
    if (fromNodeId == toNodeId) return false;
    final document = state;
    if (document == null) return false;
    final from = document.nodeById(fromNodeId);
    final to = document.nodeById(toNodeId);
    if (from == null || to == null) return false;
    // Only a generation config consumes resources, and it cannot consume another
    // config: that would create an ambiguous run.
    if (to.kind != CanvasNodeKind.config) return false;
    if (from.kind == CanvasNodeKind.config) return false;
    // No duplicates.
    return !document.edges.any(
      (edge) => edge.fromNodeId == fromNodeId && edge.toNodeId == toNodeId,
    );
  }

  CanvasEdge? connect(String fromNodeId, String toNodeId) {
    if (!canConnect(fromNodeId, toNodeId)) return null;
    final edge = CanvasEdge(
      id: _uuid.v4(),
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
    );
    state!.edges.add(edge);
    _changed();
    return edge;
  }

  void disconnect(String edgeId) {
    state?.edges.removeWhere((edge) => edge.id == edgeId);
    _changed();
  }

  // -- generation inputs ----------------------------------------------

  /// The resources a config node consumes, in stable order.
  ///
  /// This is the canvas's answer to "what should be sent to ComfyUI": the
  /// prompt from the config itself plus every connected text and image, which is
  /// exactly the reference product's model.
  ({String prompt, List<String> texts, List<MediaRef> images}) inputsFor(
    String configNodeId,
  ) {
    final document = state;
    if (document == null) {
      return (prompt: '', texts: const [], images: const []);
    }
    final config = document.nodeById(configNodeId);
    final texts = <String>[];
    final images = <MediaRef>[];
    for (final edge in document.incomingOf(configNodeId)) {
      final source = document.nodeById(edge.fromNodeId);
      if (source == null) continue;
      switch (source.kind) {
        case CanvasNodeKind.text:
          if (source.content.trim().isNotEmpty) texts.add(source.content);
        case CanvasNodeKind.image:
          images.addAll(source.media);
        case CanvasNodeKind.group:
          // A group contributes everything inside it.
          for (final member in document.nodes) {
            if (member.id == source.id) continue;
            if (!source.rect.contains(member.rect.center)) continue;
            if (member.kind == CanvasNodeKind.text &&
                member.content.trim().isNotEmpty) {
              texts.add(member.content);
            } else if (member.kind == CanvasNodeKind.image) {
              images.addAll(member.media);
            }
          }
        case _:
          break;
      }
    }
    return (prompt: config?.prompt ?? '', texts: texts, images: images);
  }
}

final canvasControllerProvider =
    NotifierProvider<CanvasController, CanvasDocument?>(CanvasController.new);
