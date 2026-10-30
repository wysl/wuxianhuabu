import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/comfy_workflow_service.dart';
import '../core/connection_profile.dart';
import '../state/connection_providers.dart';
import '../state/canvas_session.dart';
import '../state/generated_media.dart';

/// A card on the canvas.
///
/// Cards are heterogeneous by design — an image, a prompt, a run's settings —
/// which is what separates this surface from a node editor. A node editor
/// assumes typed ports and edges; an infinite canvas assumes arbitrary content
/// that the user arranges spatially.
class CanvasCard {
  CanvasCard({
    required this.id,
    required this.origin,
    required this.size,
    required this.kind,
    this.text = '',
    this.media = const [],
    this.caption = '',
  });

  final String id;
  Offset origin;
  Size size;
  final CardKind kind;

  /// Text content for [CardKind.text] / [CardKind.note].
  String text;

  /// Produced files for [CardKind.media].
  final List<Map<String, String>> media;

  final String caption;

  Rect get rect => origin & size;
}

enum CardKind { text, media, note }

/// Pan/zoom surface holding cards.
///
/// Layout is a world-space coordinate system with a [Matrix4] view transform.
/// Cards outside the viewport are skipped before building, which is what keeps
/// a canvas with hundreds of cards responsive: the cost is proportional to what
/// is on screen, not to what exists.
class CanvasBoard extends ConsumerStatefulWidget {
  const CanvasBoard({super.key, required this.prepared, required this.profile});

  final PreparedWorkflow? prepared;
  final ConnectionProfile profile;

  @override
  ConsumerState<CanvasBoard> createState() => _CanvasBoardState();
}

class _CanvasBoardState extends ConsumerState<CanvasBoard> {
  final List<CanvasCard> _cards = [];
  double _scale = 1;
  Offset _offset = Offset.zero;

  String? _selectedId;
  Offset? _dragStart;
  Map<String, Offset> _dragOrigins = {};
  Rect? _marquee;

  /// Cards created per workflow, so switching workflows does not pile every
  /// result onto one canvas.
  String? _currentWorkflowKey;

  @override
  void didUpdateWidget(covariant CanvasBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.prepared;
    if (next == null) return;
    if (_currentWorkflowKey == next.sourcePath) return;
    _currentWorkflowKey = next.sourcePath;
    _cards
      ..clear()
      ..addAll(_cardsFor(next));
    _scale = 1;
    _offset = Offset.zero;
    _selectedId = null;
    // Results produced before this canvas existed still belong on it.
    _pendingResults = ref.read(generatedMediaProvider).length;
  }

  /// Number of generated results already turned into cards, so a rebuild does
  /// not duplicate them and a new result is appended exactly once.
  int _pendingResults = 0;

  /// Appends cards for results generated since the last rebuild.
  void _syncGeneratedResults() {
    final prepared = widget.prepared;
    if (prepared == null) return;
    final results = ref
        .read(generatedMediaProvider)
        .where((entry) => entry.workflowPath == prepared.sourcePath)
        .toList();
    if (results.length <= _pendingResults) return;

    var y = _lowestCardBottom() + 24;
    for (final result in results.take(results.length - _pendingResults)) {
      _cards.add(
        CanvasCard(
          id: 'r-${result.promptId}',
          origin: Offset(80, y),
          size: const Size(300, 260),
          kind: CardKind.media,
          media: result.media,
          caption: '结果 ${result.media.length} 个文件',
        ),
      );
      y += 280;
    }
    _pendingResults = results.length;
    _persist();
  }

  /// Persists the current card list. Called after edits rather than on a timer
  /// inside the board: `CanvasAutosave` already debounces, so this is cheap.
  void _persist() {
    ref.read(canvasSessionProvider.notifier).persist(_cards);
  }

  double _lowestCardBottom() {
    if (_cards.isEmpty) return 80;
    var bottom = double.negativeInfinity;
    for (final card in _cards) {
      bottom = math.max(bottom, card.rect.bottom);
    }
    return bottom;
  }

  /// Seeds a new canvas with the workflow's own headline parameters, so the
  /// board is not empty on first open.
  List<CanvasCard> _cardsFor(PreparedWorkflow prepared) {
    final cards = <CanvasCard>[];
    var x = 80.0;
    var y = 80.0;
    for (final parameter in prepared.parameters) {
      if (!parameter.isString && !parameter.isNumeric) continue;
      if (parameter.value is! String) continue;
      final text = '${parameter.value}';
      if (text.trim().isEmpty) continue;
      cards.add(
        CanvasCard(
          id: 'p-${parameter.key}',
          origin: Offset(x, y),
          size: const Size(320, 160),
          kind: CardKind.text,
          text: text,
          caption: parameter.label,
        ),
      );
      y += 180;
      if (y > 700) {
        y = 80;
        x += 340;
      }
      if (cards.length >= 12) break;
    }
    return cards;
  }

  Offset _toWorld(Offset local) => (local - _offset) / _scale;
  Offset _toScreen(Offset world) => world * _scale + _offset;

  void _zoomAt(Offset focal, double factor) {
    final next = (_scale * factor).clamp(0.15, 4.0);
    if (next == _scale) return;
    final world = _toWorld(focal);
    setState(() {
      _scale = next;
      _offset = focal - world * _scale;
    });
  }

  void _fitToContent(Size viewport) {
    if (_cards.isEmpty) return;
    var bounds = _cards.first.rect;
    for (final card in _cards.skip(1)) {
      bounds = bounds.expandToInclude(card.rect);
    }
    const padding = 48.0;
    final scaleX = (viewport.width - padding * 2) / bounds.width;
    final scaleY = (viewport.height - padding * 2) / bounds.height;
    final scale = math.min(scaleX, scaleY).clamp(0.15, 1.6);
    setState(() {
      _scale = scale;
      _offset = Offset(
        (viewport.width - bounds.width * scale) / 2 - bounds.left * scale,
        (viewport.height - bounds.height * scale) / 2 - bounds.top * scale,
      );
    });
  }

  void _addTextCard(Offset world) {
    setState(() {
      _cards.add(
        CanvasCard(
          id: 'c-${DateTime.now().microsecondsSinceEpoch}',
          origin: world,
          size: const Size(240, 120),
          kind: CardKind.text,
          text: '',
          caption: '文本框',
        ),
      );
    });
    _persist();
  }

  CanvasCard? _hitTest(Offset world) {
    for (final card in _cards.reversed) {
      if (card.rect.contains(world)) return card;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Runs finish asynchronously; fold any new result into the board before
    // laying out so its card appears on the next frame.
    _syncGeneratedResults();
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          // Pointer signals, not gestures, so zooming does not fight the
          // pan/drag gesture arena.
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              // Ctrl+wheel zooms, plain wheel pans vertically: matching what
              // design tools do, and what a trackpad two-finger scroll expects.
              if (HardwareKeyboard.instance.isControlPressed) {
                _zoomAt(event.localPosition, event.scrollDelta.dy > 0 ? 0.9 : 1.1);
              } else {
                setState(() => _offset -= event.scrollDelta);
              }
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              final world = _toWorld(details.localPosition);
              final hit = _hitTest(world);
              if (hit != null) {
                setState(() {
                  _selectedId = hit.id;
                  _dragStart = world;
                  _dragOrigins = {for (final card in _cards) card.id: card.origin};
                });
              } else {
                setState(() {
                  _selectedId = null;
                  _dragStart = world;
                  _marquee = Rect.fromPoints(world, world);
                });
              }
            },
            onPanUpdate: (details) {
              final world = _toWorld(details.localPosition);
              final start = _dragStart;
              if (start == null) return;
              if (_marquee != null) {
                setState(() => _marquee = Rect.fromPoints(start, world));
                return;
              }
              final moved = world - start;
              setState(() {
                for (final card in _cards) {
                  final origin = _dragOrigins[card.id];
                  if (origin == null) continue;
                  card.origin = origin + moved;
                }
              });
            },
            onPanEnd: (_) {
              final marquee = _marquee;
              if (marquee != null) {
                setState(() {
                  for (final card in _cards) {
                    if (marquee.overlaps(card.rect)) {
                      _selectedId = card.id;
                    }
                  }
                  _marquee = null;
                  _dragStart = null;
                  _dragOrigins = {};
                });
              } else {
                setState(() {
                  _dragStart = null;
                  _dragOrigins = {};
                });
                _persist();
              }
            },
            onDoubleTapDown: (details) =>
                _addTextCard(_toWorld(details.localPosition)),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GridPainter(scale: _scale, offset: _offset),
                  ),
                ),
                for (final card in _visibleCards(viewport))
                  Positioned(
                    left: _toScreen(card.origin).dx,
                    top: _toScreen(card.origin).dy,
                    width: card.size.width * _scale,
                    height: card.size.height * _scale,
                    child: _CardWidget(
                      card: card,
                      scale: _scale,
                      selected: card.id == _selectedId,
                      onEdit: (text) {
                        setState(() => card.text = text);
                        _persist();
                      },
                    ),
                  ),
                if (_marquee != null)
                  Positioned.fromRect(
                    rect: Rect.fromPoints(
                      _toScreen(_marquee!.topLeft),
                      _toScreen(_marquee!.bottomRight),
                    ),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.08),
                          border: Border.all(
                            color: theme.colorScheme.primary,
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: _ZoomControls(
                    scale: _scale,
                    onZoomIn: () => _zoomAt(
                      Offset(viewport.width / 2, viewport.height / 2),
                      1.25,
                    ),
                    onZoomOut: () => _zoomAt(
                      Offset(viewport.width / 2, viewport.height / 2),
                      0.8,
                    ),
                    onReset: () => _zoomAt(
                      Offset(viewport.width / 2, viewport.height / 2),
                      1 / _scale,
                    ),
                    onFit: () => _fitToContent(viewport),
                  ),
                ),
                if (widget.prepared == null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Text(
                          '选择一个工作流开始',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Only cards overlapping the viewport are built. Culling here, before widget
  /// construction, is what keeps large canvases cheap.
  Iterable<CanvasCard> _visibleCards(Size viewport) {
    final worldViewport = Rect.fromPoints(
      _toWorld(Offset.zero),
      _toWorld(Offset(viewport.width, viewport.height)),
    ).inflate(120 / _scale);
    return _cards.where((card) => worldViewport.overlaps(card.rect));
  }
}

class _CardWidget extends StatefulWidget {
  const _CardWidget({
    required this.card,
    required this.scale,
    required this.selected,
    required this.onEdit,
  });

  final CanvasCard card;
  final double scale;
  final bool selected;
  final ValueChanged<String> onEdit;

  @override
  State<_CardWidget> createState() => _CardWidgetState();
}

class _CardWidgetState extends State<_CardWidget> {
  bool _editing = false;
  late final TextEditingController _controller =
      TextEditingController(text: widget.card.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: widget.selected ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.card.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 10 * widget.scale.clamp(0.8, 1.6),
                    ),
                  ),
                ),
                if (!_editing)
                  InkWell(
                    onTap: () => setState(() => _editing = true),
                    child: Icon(
                      Icons.edit_outlined,
                      size: 12 * widget.scale.clamp(0.8, 1.6),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: widget.card.kind == CardKind.media
                  ? _MediaCardBody(
                      media: widget.card.media,
                      scale: widget.scale,
                    )
                  : _editing
                      ? TextField(
                          controller: _controller,
                          autofocus: true,
                          maxLines: null,
                          expands: true,
                          style: TextStyle(
                            fontSize: 12 * widget.scale.clamp(0.8, 1.6),
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          onChanged: widget.onEdit,
                          onTapOutside: (_) =>
                              setState(() => _editing = false),
                        )
                      : Text(
                          widget.card.text.isEmpty ? '双击编辑' : widget.card.text,
                          overflow: TextOverflow.fade,
                          style: TextStyle(
                            fontSize: 12 * widget.scale.clamp(0.8, 1.6),
                            color: widget.card.text.isEmpty
                                ? theme.colorScheme.onSurfaceVariant
                                : null,
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the dot grid that makes pan/zoom legible.
class _GridPainter extends CustomPainter {
  const _GridPainter({required this.scale, required this.offset});

  final double scale;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    // Grid spacing adapts to zoom so the dots neither vanish nor turn into
    // noise at the extremes.
    var spacing = 40.0 * scale;
    while (spacing < 16) {
      spacing *= 4;
    }
    while (spacing > 160) {
      spacing /= 2;
    }
    final paint = Paint()
      ..color = const Color(0xFF3A3F4B)
      ..style = PaintingStyle.fill;

    final startX = offset.dx % spacing;
    final startY = offset.dy % spacing;
    for (var x = startX; x < size.width; x += spacing) {
      for (var y = startY; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.scale != scale || oldDelegate.offset != offset;
}

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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '缩小',
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove, size: 16),
            visualDensity: VisualDensity.compact,
          ),
          InkWell(
            onTap: onReset,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '${(scale * 100).round()}%',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
          IconButton(
            tooltip: '放大',
            onPressed: onZoomIn,
            icon: const Icon(Icons.add, size: 16),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: '适应内容',
            onPressed: onFit,
            icon: const Icon(Icons.fit_screen_outlined, size: 16),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Renders a generated result: an image thumbnail, or a labelled placeholder
/// for video/audio, fetched through the authenticated `/view` endpoint.
///
/// The fetch goes through the client rather than an `Image.network` URL because
/// `/view` needs the same auth header as everything else; a plain URL would 401.
class _MediaCardBody extends ConsumerWidget {
  const _MediaCardBody({required this.media, required this.scale});

  final List<Map<String, String>> media;
  final double scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (media.isEmpty) {
      return Center(
        child: Text('无文件', style: theme.textTheme.labelSmall),
      );
    }
    final service = ref.watch(workflowServiceProvider);
    final first = media.first;
    final name = '${first['filename']}'.toLowerCase();
    final isImage = name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.webp') ||
        name.endsWith('.gif');
    final isVideo = name.endsWith('.mp4') ||
        name.endsWith('.webm') ||
        name.endsWith('.mov');

    if (service == null) {
      return Center(child: Text('未连接', style: theme.textTheme.labelSmall));
    }
    if (!isImage) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo ? Icons.movie_outlined : Icons.audiotrack_outlined,
              size: 28 * scale.clamp(0.8, 1.6),
            ),
            const SizedBox(height: 4),
            Text(
              isVideo ? '视频' : '文件',
              style: theme.textTheme.labelSmall,
            ),
            if (media.length > 1)
              Text(
                '共 ${media.length} 个',
                style: theme.textTheme.labelSmall,
              ),
          ],
        ),
      );
    }
    return FutureBuilder<Uint8List>(
      future: service.fetchMedia(first),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              '读取失败',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return Center(
          child: Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}
