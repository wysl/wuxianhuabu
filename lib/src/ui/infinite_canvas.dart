import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_document.dart';
import 'canvas_node_widgets.dart';

/// The infinite canvas: pan, zoom, drag, resize, and connect.
///
/// Everything is drawn in world coordinates and transformed once with a
/// [Matrix4], so dragging stays smooth regardless of how many nodes exist, and
/// only nodes intersecting the viewport are built.
class InfiniteCanvas extends ConsumerStatefulWidget {
  const InfiniteCanvas({super.key});

  @override
  ConsumerState<InfiniteCanvas> createState() => _InfiniteCanvasState();
}

/// A connection being dragged out of a node's output handle.
class _PendingLink {
  _PendingLink({required this.fromNodeId, required this.start, required this.end});

  final String fromNodeId;
  Offset start;
  Offset end;

  /// The node under the cursor, if it can accept this link. Used both for the
  /// highlight and for the drop target.
  String? hoverTargetId;
}

class _InfiniteCanvasState extends ConsumerState<InfiniteCanvas> {
  double _scale = 1;
  Offset _offset = Offset.zero;

  String? _selectedId;
  _PendingLink? _pendingLink;

  // Drag state
  Offset? _dragStartWorld;
  Map<String, Offset> _dragOrigins = const {};
  Offset? _resizeStartWorld;
  Size? _resizeStartSize;

  // Marquee selection
  Offset? _marqueeStart;
  Offset? _marqueeEnd;

  // Panning (space held or middle mouse)
  Offset? _panStartScreen;
  Offset? _panStartOffset;
  bool _spaceDown = false;

  // Node ids selected as a group
  final Set<String> _multiSelection = {};

  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _focus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      setState(() => _spaceDown = event is! KeyUpEvent);
      return true;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace)) {
      _deleteSelection();
      return true;
    }
    return false;
  }

  void _deleteSelection() {
    final controller = ref.read(canvasControllerProvider.notifier);
    final ids = {..._multiSelection, ?_selectedId};
    if (ids.isEmpty) return;
    for (final id in ids) {
      controller.removeNode(id);
    }
    setState(() {
      _multiSelection.clear();
      _selectedId = null;
    });
  }

  Offset _toWorld(Offset screen) => (screen - _offset) / _scale;
  Offset _toScreen(Offset world) => world * _scale + _offset;

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(canvasControllerProvider);
    final theme = Theme.of(context);
    if (document == null) {
      return Center(
        child: Text('正在打开画布…', style: theme.textTheme.bodyMedium),
      );
    }
    // The viewport is owned locally for smooth interaction, then persisted.
    _scale = document.scale;
    _offset = document.offset;

    return Focus(
      focusNode: _focus,
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewRect = Rect.fromLTWH(
            -_offset.dx / _scale,
            -_offset.dy / _scale,
            constraints.maxWidth / _scale,
            constraints.maxHeight / _scale,
          );
          // Cull: a board with hundreds of nodes must not build off-screen ones.
          final visible = [
            for (final node in document.nodes)
              if (node.rect.overlaps(viewRect)) node,
          ];

          return Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) _zoomAt(event);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                _focus.requestFocus();
                if (_pendingLink != null) {
                  setState(() => _pendingLink = null);
                  return;
                }
                _handleCanvasTap(details.localPosition);
              },
              onPanStart: (details) => _handleCanvasPanStart(details),
              onPanUpdate: (details) => _handleCanvasPanUpdate(details),
              onPanEnd: (_) => _handleCanvasPanEnd(),
              onSecondaryTapDown: (details) =>
                  _showCanvasMenu(context, details.localPosition),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CanvasPainter(
                        scale: _scale,
                        offset: _offset,
                        gridColor: theme.colorScheme.outlineVariant
                            .withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  // Edges under nodes.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _EdgePainter(
                          document: document,
                          scale: _scale,
                          offset: _offset,
                          pending: _pendingLink,
                          highlightColor: theme.colorScheme.primary,
                          baseColor: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  ),
                  for (final node in visible)
                    Positioned(
                      left: _toScreen(node.position).dx,
                      top: _toScreen(node.position).dy,
                      child: Transform.scale(
                        scale: _scale,
                        alignment: Alignment.topLeft,
                        child: CanvasNodeView(
                          key: ValueKey(node.id),
                          node: node,
                          selected: node.id == _selectedId ||
                              _multiSelection.contains(node.id),
                          onSelect: () => _select(node),
                          onDragStart: (screenPosition) =>
                              _beginNodeDrag(node, screenPosition),
                          onDragUpdate: (delta) => _dragNode(node, delta),
                          onDragEnd: () => _endNodeDrag(),
                          onResizeStart: (screenPosition) =>
                              _beginResize(node, screenPosition),
                          onResizeUpdate: (delta) => _resizeNode(node, delta),
                          onResizeEnd: () => _endResize(),
                          onLinkStart: (screenPosition) =>
                              _startLink(node, screenPosition),
                          onLinkUpdate: (screenPosition) =>
                              _updateLink(screenPosition),
                          onLinkEnd: (screenPosition) =>
                              _endLink(screenPosition),
                        ),
                      ),
                    ),
                  if (_marqueeStart != null && _marqueeEnd != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _MarqueePainter(
                            rect: Rect.fromPoints(
                              _toScreen(_marqueeStart!),
                              _toScreen(_marqueeEnd!),
                            ),
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _ZoomControls(
                      scale: _scale,
                      onZoomIn: () => _zoomBy(1.2),
                      onZoomOut: () => _zoomBy(1 / 1.2),
                      onReset: () => _resetView(constraints.biggest),
                      onFit: () =>
                          _fitToContent(constraints.biggest, document),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -- interaction ----------------------------------------------------

  void _select(CanvasNode node) {
    setState(() {
      _selectedId = node.id;
      _multiSelection.clear();
    });
  }

  void _handleCanvasTap(Offset screen) {
    setState(() {
      _selectedId = null;
      _multiSelection.clear();
    });
  }

  void _zoomAt(PointerScrollEvent event) {
    final factor = event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1;
    final worldBefore = _toWorld(event.localPosition);
    final nextScale = (_scale * factor).clamp(0.15, 4.0);
    setState(() {
      _scale = nextScale;
      _offset = event.localPosition - worldBefore * nextScale;
    });
    _persistViewport();
  }

  void _zoomBy(double factor) {
    final size = context.size;
    final center = size == null
        ? Offset.zero
        : Offset(size.width / 2, size.height / 2);
    final worldBefore = _toWorld(center);
    final nextScale = (_scale * factor).clamp(0.15, 4.0);
    setState(() {
      _scale = nextScale;
      _offset = center - worldBefore * nextScale;
    });
    _persistViewport();
  }

  void _resetView(Size viewport) {
    setState(() {
      _scale = 1;
      _offset = Offset.zero;
    });
    _persistViewport();
  }

  /// Fits every node into view, with padding. The single most useful control on
  /// an infinite canvas: it is how you recover after panning into empty space.
  void _fitToContent(Size viewport, CanvasDocument document) {
    if (document.nodes.isEmpty) {
      _resetView(viewport);
      return;
    }
    var bounds = document.nodes.first.rect;
    for (final node in document.nodes) {
      bounds = bounds.expandToInclude(node.rect);
    }
    const padding = 80.0;
    final scaleX = (viewport.width - padding * 2) / bounds.width;
    final scaleY = (viewport.height - padding * 2) / bounds.height;
    final scale = math.min(scaleX, scaleY).clamp(0.15, 1.5);
    setState(() {
      _scale = scale;
      _offset = Offset(
        viewport.width / 2 - bounds.center.dx * scale,
        viewport.height / 2 - bounds.center.dy * scale,
      );
    });
    _persistViewport();
  }

  void _persistViewport() {
    ref.read(canvasControllerProvider.notifier).setViewport(_offset, _scale);
  }

  // -- panning --------------------------------------------------------

  void _handleCanvasPanStart(DragStartDetails details) {
    final middleButton = HardwareKeyboard.instance.isAltPressed;
    if (_spaceDown || middleButton) {
      _panStartScreen = details.localPosition;
      _panStartOffset = _offset;
      return;
    }
    // Dragging empty space is a marquee selection.
    final world = _toWorld(details.localPosition);
    setState(() {
      _marqueeStart = world;
      _marqueeEnd = world;
      _selectedId = null;
      _multiSelection.clear();
    });
  }

  void _handleCanvasPanUpdate(DragUpdateDetails details) {
    if (_panStartScreen != null && _panStartOffset != null) {
      setState(() {
        _offset = _panStartOffset! +
            (details.localPosition - _panStartScreen!);
      });
      return;
    }
    if (_marqueeStart != null) {
      setState(() => _marqueeEnd = _toWorld(details.localPosition));
    }
  }

  void _handleCanvasPanEnd() {
    if (_panStartScreen != null) {
      _panStartScreen = null;
      _panStartOffset = null;
      _persistViewport();
      return;
    }
    final start = _marqueeStart;
    final end = _marqueeEnd;
    if (start != null && end != null) {
      final rect = Rect.fromPoints(start, end);
      final document = ref.read(canvasControllerProvider);
      setState(() {
        _multiSelection.clear();
        if (document != null && rect.width > 4 && rect.height > 4) {
          for (final node in document.nodes) {
            if (rect.overlaps(node.rect)) _multiSelection.add(node.id);
          }
        }
        _marqueeStart = null;
        _marqueeEnd = null;
      });
    }
  }

  // -- node drag ------------------------------------------------------

  void _beginNodeDrag(CanvasNode node, Offset screenPosition) {
    final document = ref.read(canvasControllerProvider);
    if (document == null) return;
    if (!_multiSelection.contains(node.id)) {
      setState(() {
        _selectedId = node.id;
        _multiSelection.clear();
      });
    }
    _dragStartWorld = _toWorld(screenPosition);
    final moving = {..._multiSelection, node.id};
    _dragOrigins = {
      for (final member in document.nodes)
        if (moving.contains(member.id)) member.id: member.position,
    };
  }

  void _dragNode(CanvasNode node, Offset screenDelta) {
    final start = _dragStartWorld;
    if (start == null) return;
    final worldDelta = screenDelta / _scale;
    for (final entry in _dragOrigins.entries) {
      ref
          .read(canvasControllerProvider.notifier)
          .moveNode(entry.key, entry.value + worldDelta);
    }
  }

  void _endNodeDrag() {
    _dragStartWorld = null;
    _dragOrigins = const {};
  }

  // -- resize ---------------------------------------------------------

  void _beginResize(CanvasNode node, Offset screenPosition) {
    setState(() {});
    _resizeStartWorld = _toWorld(screenPosition);
    _resizeStartSize = node.size;
  }

  void _resizeNode(CanvasNode node, Offset screenDelta) {
    final startWorld = _resizeStartWorld;
    final startSize = _resizeStartSize;
    if (startWorld == null || startSize == null) return;
    final worldDelta = screenDelta / _scale;
    ref.read(canvasControllerProvider.notifier).resizeNode(
          node.id,
          Size(startSize.width + worldDelta.dx, startSize.height + worldDelta.dy),
        );
  }

  void _endResize() {
    _resizeStartWorld = null;
    _resizeStartSize = null;
  }

  // -- linking --------------------------------------------------------

  void _startLink(CanvasNode node, Offset screenPosition) {
    final world = _toWorld(screenPosition);
    setState(() {
      _pendingLink = _PendingLink(
        fromNodeId: node.id,
        start: node.rect.centerRight,
        end: world,
      );
    });
  }

  void _updateLink(Offset screenPosition) {
    final pending = _pendingLink;
    if (pending == null) return;
    final world = _toWorld(screenPosition);
    final document = ref.read(canvasControllerProvider);
    String? target;
    if (document != null) {
      for (final node in document.nodes.reversed) {
        if (node.id == pending.fromNodeId) continue;
        if (node.rect.contains(world) &&
            ref.read(canvasControllerProvider.notifier).canConnect(
                  pending.fromNodeId,
                  node.id,
                )) {
          target = node.id;
          break;
        }
      }
    }
    setState(() {
      pending.end = world;
      pending.hoverTargetId = target;
    });
  }

  void _endLink(Offset screenPosition) {
    final pending = _pendingLink;
    if (pending == null) return;
    final world = _toWorld(screenPosition);
    final controller = ref.read(canvasControllerProvider.notifier);
    final document = ref.read(canvasControllerProvider);

    String? target = pending.hoverTargetId;
    if (target == null && document != null) {
      for (final node in document.nodes.reversed) {
        if (node.id == pending.fromNodeId) continue;
        if (node.rect.contains(world) &&
            controller.canConnect(pending.fromNodeId, node.id)) {
          target = node.id;
          break;
        }
      }
    }

    setState(() => _pendingLink = null);
    if (target != null) {
      controller.connect(pending.fromNodeId, target);
      return;
    }
    // Released on empty space: offer to create a node already connected.
    if (document != null && !_nodeAt(world, document)) {
      _showCreateMenuForLink(context, screenPosition, pending.fromNodeId);
    }
  }

  bool _nodeAt(Offset world, CanvasDocument document) =>
      document.nodes.any((node) => node.rect.contains(world));

  void _showCreateMenuForLink(
    BuildContext context,
    Offset screenPosition,
    String fromNodeId,
  ) {
    final world = _toWorld(screenPosition);
    showCanvasCreateMenu(
      context: context,
      anchorScreen: screenPosition,
      onCreate: (kind) {
        final node = ref.read(canvasControllerProvider.notifier).addNode(
              kind,
              worldCenter: world,
            );
        if (kind == CanvasNodeKind.config) {
          ref
              .read(canvasControllerProvider.notifier)
              .connect(fromNodeId, node.id);
        } else {
          // A newly created resource flows into whatever config it was dragged
          // from, but only a config consumes; the controller rejects the rest.
          ref
              .read(canvasControllerProvider.notifier)
              .connect(node.id, fromNodeId);
        }
        setState(() => _selectedId = node.id);
      },
    );
  }

  void _showCanvasMenu(BuildContext context, Offset screenPosition) {
    _showCreateMenuForLink(context, screenPosition, '');
  }
}

/// Zoom / fit controls.
class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.onFit,
  });

  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '缩小',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${(scale * 100).round()}%',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ),
          IconButton(
            tooltip: '放大',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onZoomIn,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: '适应内容',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onFit,
            icon: const Icon(Icons.fit_screen_outlined),
          ),
          IconButton(
            tooltip: '重置视图',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onReset,
            icon: const Icon(Icons.center_focus_weak),
          ),
        ],
      ),
    );
  }
}

/// Dot grid that scales with the canvas.
class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.scale,
    required this.offset,
    required this.gridColor,
  });

  final double scale;
  final Offset offset;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 28.0;
    final step = spacing * scale;
    if (step < 6) return; // too dense to be useful
    final paint = Paint()..color = gridColor;
    final startX = offset.dx % step;
    final startY = offset.dy % step;
    for (var x = startX; x < size.width; x += step) {
      for (var y = startY; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), scale < 0.5 ? 0.7 : 1.0, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.scale != scale || old.offset != offset || old.gridColor != gridColor;
}

/// Edges between nodes, plus the rubber-band link being dragged.
class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.document,
    required this.scale,
    required this.offset,
    required this.pending,
    required this.highlightColor,
    required this.baseColor,
  });

  final CanvasDocument document;
  final double scale;
  final Offset offset;
  final _PendingLink? pending;
  final Color highlightColor;
  final Color baseColor;

  Offset _screen(Offset world) => world * scale + offset;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = baseColor;

    for (final edge in document.edges) {
      final from = document.nodeById(edge.fromNodeId);
      final to = document.nodeById(edge.toNodeId);
      if (from == null || to == null) continue;
      final start = _screen(from.rect.centerRight);
      final end = _screen(to.rect.centerLeft);
      _drawCurve(canvas, start, end, paint);
    }

    final active = pending;
    if (active != null) {
      final paintActive = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = highlightColor;
      final startWorld = document.nodeById(active.fromNodeId)?.rect.centerRight ??
          active.start;
      _drawCurve(canvas, _screen(startWorld), _screen(active.end), paintActive);
      canvas.drawCircle(_screen(active.end), 4, Paint()..color = highlightColor);
    }
  }

  /// A horizontal-tangent bezier reads as "reference" rather than "dataflow".
  void _drawCurve(Canvas canvas, Offset start, Offset end, Paint paint) {
    final dx = (end.dx - start.dx).abs().clamp(40.0, 220.0);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        start.dx + dx,
        start.dy,
        end.dx - dx,
        end.dy,
        end.dx,
        end.dy,
      );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) => true;
}

class _MarqueePainter extends CustomPainter {
  _MarqueePainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()..color = color.withValues(alpha: 0.12),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter old) =>
      old.rect != rect || old.color != color;
}
