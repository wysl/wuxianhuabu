import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_document.dart';
import '../core/comfy_workflow_service.dart';
import '../state/connection_providers.dart';
import 'canvas_config_node.dart';

/// The kind picker shown when a link is dragged onto empty space, or on
/// right-click. Ordered the way the reference product orders it: the resources
/// first, the generation config last, because a config is what ties them
/// together and is usually created after its inputs exist.
Future<void> showCanvasCreateMenu({
  required BuildContext context,
  required Offset anchorScreen,
  required void Function(CanvasNodeKind kind) onCreate,
}) async {
  final theme = Theme.of(context);
  final kind = await showDialog<CanvasNodeKind>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => Stack(
      children: [
        Positioned(
          left: anchorScreen.dx.clamp(8, 2000),
          top: anchorScreen.dy.clamp(8, 1400),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 240,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 4, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择节点',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => Navigator.of(context).pop(),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 15,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final kind in _CreateOption.orderedKinds)
                    _CreateOption(
                      kind: kind,
                      onTap: () => Navigator.of(context).pop(kind),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
  if (kind != null) onCreate(kind);
}

class _CreateOption extends StatelessWidget {
  const _CreateOption({required this.kind, required this.onTap});

  final CanvasNodeKind kind;
  final VoidCallback onTap;

  /// Menu order follows the reference product: resources first, then the
  /// generation config, then the layout helpers. `CanvasNodeKind.values` is the
  /// storage order and deliberately differs.
  static const orderedKinds = [
    CanvasNodeKind.text,
    CanvasNodeKind.image,
    CanvasNodeKind.video,
    CanvasNodeKind.audio,
    CanvasNodeKind.config,
    CanvasNodeKind.freeCard,
    CanvasNodeKind.group,
  ];

  static const _icons = {
    CanvasNodeKind.text: Icons.notes,
    CanvasNodeKind.image: Icons.image,
    CanvasNodeKind.video: Icons.videocam,
    CanvasNodeKind.audio: Icons.graphic_eq,
    CanvasNodeKind.config: Icons.tune,
    CanvasNodeKind.freeCard: Icons.dashboard_customize,
    CanvasNodeKind.group: Icons.grid_view,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Row(
          children: [
            Icon(
              _icons[kind] ?? Icons.crop_square,
              size: 17,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Text(kind.title, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// One node on the board. Handles its own frame, selection outline, resize grip
/// and output handle; the content is delegated per kind.
class CanvasNodeView extends StatelessWidget {
  CanvasNodeView({
    super.key,
    required this.node,
    required this.selected,
    required this.onSelect,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.onLinkStart,
    required this.onLinkUpdate,
    required this.onLinkEnd,
  });

  final CanvasNode node;
  final bool selected;
  final VoidCallback onSelect;
  final void Function(Offset screenPosition) onDragStart;
  final void Function(Offset screenDelta) onDragUpdate;
  final VoidCallback onDragEnd;
  final void Function(Offset screenPosition) onResizeStart;
  final void Function(Offset screenDelta) onResizeUpdate;
  final VoidCallback onResizeEnd;
  final void Function(Offset screenPosition) onLinkStart;
  final void Function(Offset screenPosition) onLinkUpdate;
  final void Function(Offset screenPosition) onLinkEnd;

  /// Converts a global pointer position (what gesture details carry) into this
  /// node's local space.
  ///
  /// The board scales nodes with a `Transform`, so a global pixel is not a
  /// world unit; anchoring through the node's own [RenderBox] lets the caller
  /// work in node-local coordinates and keeps drag deltas correct at any zoom.
  Offset _globalToLocal(Offset global) {
    final box = _frameKey.currentContext?.findRenderObject();
    if (box is RenderBox) return box.globalToLocal(global);
    return global;
  }

  final GlobalKey _frameKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: _frameKey,
      width: node.size.width,
      height: node.size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Frame
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSelect,
              onPanStart: (details) =>
                  onDragStart(_globalToLocal(details.globalPosition)),
              onPanUpdate: (details) =>
                  onDragUpdate(details.delta),
              onPanEnd: (_) => onDragEnd(),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    width: selected ? 1.6 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.25),
                            blurRadius: 16,
                          ),
                        ]
                      : const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 10,
                            offset: Offset(0, 3),
                          ),
                        ],
                ),
                clipBehavior: Clip.antiAlias,
                child: NodeContent(node: node),
              ),
            ),
          ),
          // Output handle (start a link)
          Positioned(
            right: -7,
            top: node.size.height / 2 - 7,
            child: _Handle(
              onDragStart: (global) => onLinkStart(_globalToLocal(global)),
              onDragUpdate: (global) => onLinkUpdate(_globalToLocal(global)),
              onDragEnd: (global) => onLinkEnd(_globalToLocal(global)),
            ),
          ),
          // Resize grip
          if (selected)
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                onPanStart: (details) =>
                    onResizeStart(_globalToLocal(details.globalPosition)),
                onPanUpdate: (details) => onResizeUpdate(details.delta),
                onPanEnd: (_) => onResizeEnd(),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpLeftDownRight,
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CustomPaint(
                      painter: _GripPainter(theme.colorScheme.primary),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The little circle you drag to start a connection.
class _Handle extends StatelessWidget {
  const _Handle({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final void Function(Offset globalPosition) onDragStart;
  final void Function(Offset globalPosition) onDragUpdate;
  final void Function(Offset globalPosition) onDragEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => onDragStart(details.globalPosition),
        onPanUpdate: (details) => onDragUpdate(details.globalPosition),
        onPanEnd: (details) => onDragEnd(details.globalPosition),
        child: SizedBox(
          width: 14,
          height: 14,
          child: Center(
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surface,
                border: Border.all(
                  color: theme.colorScheme.primary,
                  width: 1.8,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GripPainter extends CustomPainter {
  _GripPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i <= 3; i++) {
      final d = size.width * i / 4;
      canvas.drawLine(Offset(d, size.height), Offset(size.width, d), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GripPainter old) => old.color != color;
}

/// Renders the node body for its kind.
class NodeContent extends ConsumerWidget {
  const NodeContent({super.key, required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (node.kind) {
      case CanvasNodeKind.text:
        return _TextNodeBody(node: node);
      case CanvasNodeKind.image:
        return _ImageNodeBody(node: node);
      case CanvasNodeKind.video:
      case CanvasNodeKind.audio:
        return _MediaNodeBody(node: node);
      case CanvasNodeKind.config:
        return ConfigNodeBody(node: node);
      case CanvasNodeKind.group:
        return _GroupNodeBody(node: node);
      case CanvasNodeKind.freeCard:
        return _FreeCardBody(node: node);
    }
  }
}

/// Text node: a caption plus an editable body. Edits commit on blur so a
/// keystroke does not trigger a board rebuild.
class _TextNodeBody extends ConsumerStatefulWidget {
  const _TextNodeBody({required this.node});

  final CanvasNode node;

  @override
  ConsumerState<_TextNodeBody> createState() => _TextNodeBodyState();
}

class _TextNodeBodyState extends ConsumerState<_TextNodeBody> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.node.content);
  final FocusNode _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void didUpdateWidget(covariant _TextNodeBody old) {
    super.didUpdateWidget(old);
    // An external change (e.g. a run writing text back) must not be clobbered
    // while the user is typing.
    if (!_editing && _controller.text != widget.node.content) {
      _controller.text = widget.node.content;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    setState(() => _editing = false);
    final text = _controller.text;
    if (text == widget.node.content) return;
    ref.read(canvasControllerProvider.notifier).updateNode(
          widget.node.id,
          (node) => node.content = text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.node.displayTitle,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Icon(
                Icons.notes_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GestureDetector(
              onDoubleTap: () {
                setState(() => _editing = true);
                _focus.requestFocus();
              },
              child: _editing
                  ? TextField(
                      controller: _controller,
                      focusNode: _focus,
                      autofocus: true,
                      maxLines: null,
                      expands: true,
                      style: theme.textTheme.bodySmall,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    )
                  : Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        widget.node.content.isEmpty
                            ? '双击编辑文本'
                            : widget.node.content,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: widget.node.content.isEmpty
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Image node: shows generated or imported media, or an empty placeholder.
class _ImageNodeBody extends ConsumerWidget {
  const _ImageNodeBody({required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final service = ref.watch(workflowServiceProvider);
    final first = node.media.isNotEmpty ? node.media.first : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _NodeMedia(
            node: node,
            media: first,
            service: service,
            placeholderIcon: Icons.image_outlined,
            placeholderLabel: '空图片节点',
          ),
        ),
        if (node.status == NodeStatus.loading)
          const LinearProgressIndicator(minHeight: 2),
        if (node.status == NodeStatus.error)
          Container(
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              '${node.metadata['error'] ?? '生成失败'}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// Shared media renderer for image/video/audio nodes.
class _NodeMedia extends StatelessWidget {
  const _NodeMedia({
    required this.node,
    required this.media,
    required this.service,
    required this.placeholderIcon,
    required this.placeholderLabel,
  });

  final CanvasNode node;
  final MediaRef? media;
  final ComfyWorkflowService? service;
  final IconData placeholderIcon;
  final String placeholderLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (node.status == NodeStatus.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 8),
            Text('生成中', style: theme.textTheme.labelSmall),
          ],
        ),
      );
    }
    if (media == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              placeholderIcon,
              size: 34,
              color: theme.colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.55),
            ),
            const SizedBox(height: 6),
            Text(
              placeholderLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return _RemoteMedia(nodeId: node.id, media: media!, service: service);
  }
}

/// Fetches bytes through the authenticated client.
///
/// A plain `Image.network` URL would 401 on any instance behind auth; `/view`
/// needs the same headers as every other call.
class _RemoteMedia extends StatefulWidget {
  const _RemoteMedia({
    required this.nodeId,
    required this.media,
    required this.service,
  });

  final String nodeId;
  final MediaRef media;
  final ComfyWorkflowService? service;

  @override
  State<_RemoteMedia> createState() => _RemoteMediaState();
}

class _RemoteMediaState extends State<_RemoteMedia> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteMedia old) {
    super.didUpdateWidget(old);
    if (old.media.filename != widget.media.filename ||
        old.service != widget.service) {
      _load();
    }
  }

  void _load() {
    final service = widget.service;
    if (service == null) return;
    _future = _fetch(service);
  }

  Future<Uint8List> _fetch(ComfyWorkflowService service) => service.fetchMedia({
        'filename': widget.media.filename,
        'subfolder': widget.media.subfolder,
        'type': widget.media.type,
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_future == null) {
      return Center(child: Text('未连接', style: theme.textTheme.labelSmall));
    }
    return FutureBuilder<Uint8List>(
      future: _future,
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
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final name = widget.media.filename.toLowerCase();
        final isImage = name.endsWith('.png') ||
            name.endsWith('.jpg') ||
            name.endsWith('.jpeg') ||
            name.endsWith('.webp') ||
            name.endsWith('.gif');
        if (!isImage) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.movie_outlined, size: 30, color: theme.colorScheme.primary),
                const SizedBox(height: 6),
                Text(widget.media.displayName, style: theme.textTheme.labelSmall),
              ],
            ),
          );
        }
        return Image.memory(
          snapshot.data!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
      },
    );
  }
}

/// Video / audio node: no inline playback in this build, a labelled card instead.
class _MediaNodeBody extends StatelessWidget {
  const _MediaNodeBody({required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVideo = node.kind == CanvasNodeKind.video;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(
            isVideo ? Icons.videocam_outlined : Icons.graphic_eq_outlined,
            size: 26,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(node.displayTitle, style: theme.textTheme.labelMedium),
                const SizedBox(height: 2),
                Text(
                  node.media.isEmpty
                      ? (isVideo ? '空视频节点' : '空音频节点')
                      : node.media.first.displayName,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Group node: a labelled region. Membership is geometric, so dragging a node
/// inside the frame is all it takes to join.
class _GroupNodeBody extends StatelessWidget {
  const _GroupNodeBody({required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(
          node.displayTitle,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Free card: a titled panel for arbitrary notes or a link.
class _FreeCardBody extends StatelessWidget {
  const _FreeCardBody({required this.node});

  final CanvasNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.dashboard_customize_outlined,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  node.displayTitle,
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Text(
              node.content,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.fade,
            ),
          ),
        ],
      ),
    );
  }
}
