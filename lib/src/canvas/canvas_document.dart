import 'dart:ui';

/// The node kinds a canvas can hold.
///
/// Deliberately heterogeneous: the reference product this is modelled on puts
/// an image, a prompt and a generation config on the same surface, because the
/// user's mental model is "arrange my work", not "wire typed ports". Edges
/// express *reference*, not dataflow typing.
enum CanvasNodeKind {
  image('image', '图片', 340, 240),
  text('text', '文本', 340, 240),
  config('config', '生成配置', 340, 240),
  video('video', '视频', 420, 236),
  audio('audio', '音频', 340, 120),
  freeCard('free-card', '自由卡片', 340, 240),
  group('group', '组', 760, 480);

  const CanvasNodeKind(this.id, this.title, this.defaultWidth, this.defaultHeight);

  /// Stable string used in persisted JSON; never rename.
  final String id;
  final String title;
  final double defaultWidth;
  final double defaultHeight;

  static CanvasNodeKind? byId(String id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// Lifecycle of a node's content.
enum NodeStatus { idle, loading, success, error }

/// What the generation config is producing.
enum GenerationMode { image, text, video, audio }

/// `image` node: one picture, either imported or generated.
class MediaRef {
  const MediaRef({
    required this.filename,
    this.subfolder = '',
    this.type = 'output',
  });

  final String filename;
  final String subfolder;
  final String type;

  /// Whether `/view` can be expected to serve this (as opposed to a local file
  /// the user dropped in, which is kept separately).
  bool get isServerFile => filename.isNotEmpty;

  String get displayName {
    final base = filename.split('/').last;
    return base.length > 24 ? '${base.substring(0, 21)}…' : base;
  }

  Map<String, Object?> toJson() => {
        'filename': filename,
        'subfolder': subfolder,
        'type': type,
      };

  static MediaRef fromJson(Map<String, Object?> raw) => MediaRef(
        filename: '${raw['filename'] ?? ''}',
        subfolder: '${raw['subfolder'] ?? ''}',
        type: '${raw['type'] ?? 'output'}',
      );
}

/// One node on the canvas.
///
/// A single mutable class rather than a sealed hierarchy: the reference product
/// treats every node as "position + size + typed metadata", and a hierarchy here
/// would force every generic operation (move, resize, select, serialize) to
/// switch on type. Type-specific behaviour lives in the widgets.
class CanvasNode {
  CanvasNode({
    required this.id,
    required this.kind,
    required this.position,
    required this.size,
    this.title,
    this.content = '',
    this.media = const [],
    this.status = NodeStatus.idle,
    this.metadata = const {},
    this.zIndex = 0,
  });

  final String id;
  final CanvasNodeKind kind;
  Offset position;
  Size size;

  /// User-facing title; falls back to [kind].title.
  String? title;

  /// Text body for `text` nodes, prompt for `config` nodes.
  String content;

  /// Produced or imported files for `image`/`video`/`audio` nodes.
  List<MediaRef> media;

  NodeStatus status;

  /// Kind-specific settings; kept as a loose map so a plugin-like node can carry
  /// arbitrary fields without a schema migration.
  Map<String, Object?> metadata;

  int zIndex;

  Rect get rect => position & size;

  String get displayTitle => title?.isNotEmpty == true ? title! : kind.title;

  // -- config-node conveniences ---------------------------------------

  /// The generation prompt held by a `config` node.
  String get prompt => '${metadata['prompt'] ?? content}';

  set prompt(String value) => metadata = {...metadata, 'prompt': value};

  GenerationMode get mode {
    final raw = '${metadata['mode'] ?? ''}';
    return GenerationMode.values.firstWhere(
      (candidate) => candidate.name == raw,
      orElse: () => GenerationMode.image,
    );
  }

  set mode(GenerationMode value) =>
      metadata = {...metadata, 'mode': value.name};

  /// How many results to produce per run.
  int get count {
    final raw = metadata['count'];
    if (raw is int) return raw.clamp(1, 8);
    if (raw is num) return raw.toInt().clamp(1, 8);
    return 1;
  }

  set count(int value) => metadata = {...metadata, 'count': value.clamp(1, 8)};

  /// Which workflow to run, as a server-relative path.
  String? get workflowPath {
    final raw = metadata['workflow_path'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  set workflowPath(String? value) =>
      metadata = {...metadata, 'workflow_path': ?value};

  /// Parameter overrides for the chosen workflow, keyed like
  /// `ParameterDef.key` (`984.seed`).
  Map<String, Object?> get params {
    final raw = metadata['params'];
    if (raw is Map) {
      return {for (final entry in raw.entries) '${entry.key}': entry.value};
    }
    return const {};
  }

  set params(Map<String, Object?> value) =>
      metadata = {...metadata, 'params': value};

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.id,
        if (title != null) 'title': title,
        'x': position.dx,
        'y': position.dy,
        'width': size.width,
        'height': size.height,
        'content': content,
        'status': status.name,
        'z': zIndex,
        'media': [for (final item in media) item.toJson()],
        'metadata': metadata,
      };

  static CanvasNode fromJson(Map<String, Object?> raw) {
    final kind = CanvasNodeKind.byId('${raw['kind']}') ?? CanvasNodeKind.text;
    return CanvasNode(
      id: '${raw['id']}',
      kind: kind,
      position: Offset(
        (raw['x'] as num?)?.toDouble() ?? 0,
        (raw['y'] as num?)?.toDouble() ?? 0,
      ),
      size: Size(
        (raw['width'] as num?)?.toDouble() ?? kind.defaultWidth,
        (raw['height'] as num?)?.toDouble() ?? kind.defaultHeight,
      ),
      title: raw['title'] as String?,
      content: '${raw['content'] ?? ''}',
      media: [
        for (final entry in (raw['media'] as List?) ?? const [])
          if (entry is Map) MediaRef.fromJson(entry.cast<String, Object?>()),
      ],
      status: NodeStatus.values.firstWhere(
        (candidate) => candidate.name == '${raw['status']}',
        orElse: () => NodeStatus.idle,
      ),
      metadata: (raw['metadata'] as Map?)?.cast<String, Object?>() ?? const {},
      zIndex: (raw['z'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A directed edge: [fromNodeId] is a *resource* consumed by [toNodeId].
///
/// The reference product stores connection direction semantically ("config
/// consumes this text/image"), which is what makes a config node able to
/// collect its references without a graph walk.
class CanvasEdge {
  const CanvasEdge({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
  });

  final String id;
  final String fromNodeId;
  final String toNodeId;

  Map<String, Object?> toJson() => {
        'id': id,
        'from': fromNodeId,
        'to': toNodeId,
      };

  static CanvasEdge fromJson(Map<String, Object?> raw) => CanvasEdge(
        id: '${raw['id']}',
        fromNodeId: '${raw['from']}',
        toNodeId: '${raw['to']}',
      );
}

/// A project: nodes, edges, and the viewport.
class CanvasDocument {
  CanvasDocument({
    required this.id,
    required this.nodes,
    required this.edges,
    this.title = '无界画布',
    this.scale = 1,
    this.offset = Offset.zero,
    this.revision = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  double scale;
  Offset offset;

  /// Bumped on every mutation so the board can rebuild without comparing deep
  /// contents: the lists are mutated in place for cheap dragging.
  final int revision;

  final DateTime updatedAt;

  CanvasNode? nodeById(String? id) {
    if (id == null) return null;
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  /// Edges pointing *into* [nodeId], i.e. the resources it consumes.
  List<CanvasEdge> incomingOf(String nodeId) =>
      edges.where((edge) => edge.toNodeId == nodeId).toList();

  /// Edges leaving [nodeId], i.e. consumers of this node.
  List<CanvasEdge> outgoingOf(String nodeId) =>
      edges.where((edge) => edge.fromNodeId == nodeId).toList();

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'updated_at': updatedAt.toIso8601String(),
        'scale': scale,
        'offset_x': offset.dx,
        'offset_y': offset.dy,
        'nodes': [for (final node in nodes) node.toJson()],
        'edges': [for (final edge in edges) edge.toJson()],
      };

  static CanvasDocument fromJson(Map<String, Object?> raw) => CanvasDocument(
        id: '${raw['id']}',
        title: '${raw['title'] ?? '无界画布'}',
        updatedAt: DateTime.tryParse('${raw['updated_at']}') ?? DateTime.now(),
        scale: (raw['scale'] as num?)?.toDouble() ?? 1,
        offset: Offset(
          (raw['offset_x'] as num?)?.toDouble() ?? 0,
          (raw['offset_y'] as num?)?.toDouble() ?? 0,
        ),
        nodes: [
          for (final entry in (raw['nodes'] as List?) ?? const [])
            if (entry is Map) CanvasNode.fromJson(entry.cast<String, Object?>()),
        ],
        edges: [
          for (final entry in (raw['edges'] as List?) ?? const [])
            if (entry is Map) CanvasEdge.fromJson(entry.cast<String, Object?>()),
        ],
      );
}
