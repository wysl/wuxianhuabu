import 'graph_expansion_error.dart';

/// A `class_type` the expander refuses to send to the server.
///
/// The remote instance answers an unknown `class_type` with
/// `missing_node_type`, so a virtual node leaking into the prompt turns into a
/// hard 400 rather than a silent no-op. These are the names the frontend owns
/// and never serialises into a prompt.
const Set<String> virtualNodeTypes = {
  'SetNode',
  'GetNode',
  'Reroute',
  'PrimitiveNode',
  'Note',
  'MarkdownNote',
  'Note Plus (mtb)',
  'Label (rgthree)',
  'Fast Groups Bypasser (rgthree)',
  'Fast Groups Muter (rgthree)',
  'Bookmark (rgthree)',
};

/// Nodes the frontend treats as a **value broadcaster**: a link leaving one of
/// these resolves to the literal value on the matching output slot instead of
/// to a node reference.
///
/// `QQ-多值输入` is the observed case. It has no server-side implementation
/// (its `/object_info` entry is a stub with no inputs and a single `*` output),
/// yet real workflows route prompt text, aspect ratio and seed through it. In
/// the prompts ComfyUI actually ran, the consumer received the *value*:
///
///     "986": {"class_type": "Text Multiline",
///             "inputs": {"text": "A continuous ultra-close ..."}}
///
/// so a link ending here must be inlined rather than turned into
/// `[node, slot]`.
const Set<String> valueBroadcastNodeTypes = {
  'QQ-多值输入',
  'QQMultiSet',
};

/// Node modes that mean "this node does not run".
const int modeNever = 2;
const int modeBypass = 4;

/// Slot types the frontend renders as an editable widget.
const Set<String> widgetKinds = {'INT', 'FLOAT', 'STRING', 'BOOLEAN', 'COMBO'};

/// Seed widgets are followed by an extra "control_after_generate" value in the
/// positional `widgets_values` array. That extra value is *not* an input, so
/// reading the array by index desynchronises every later widget unless it is
/// skipped.
const Set<String> seedWidgetNames = {'seed', 'noise_seed'};

/// Values that extra seed control can take.
const Set<String> seedControlValues = {
  'fixed',
  'increment',
  'decrement',
  'randomize',
};

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// One input or output slot of a [UiNode].
class UiSlot {
  const UiSlot({
    this.name,
    this.type,
    this.link,
    this.links = const [],
    this.widgetName,
    this.localizedName,
  });

  final String? name;
  final String? type;

  /// Link id attached to an input slot; `null` when unconnected.
  final int? link;

  /// Link ids leaving an output slot.
  final List<int> links;

  /// Present when this slot is backed by a widget (`{"name": "steps"}`).
  final String? widgetName;

  /// Localized display label, used when a subgraph input has no explicit label.
  final String? localizedName;

  static UiSlot fromJson(Object? raw) {
    if (raw is! Map) return const UiSlot();
    final widget = raw['widget'];
    final links = raw['links'];
    return UiSlot(
      name: raw['name'] is String ? raw['name'] as String : null,
      type: raw['type'] is String ? raw['type'] as String : null,
      link: asInt(raw['link']),
      links: links is List
          ? [
              for (final entry in links)
                if (asInt(entry) != null) asInt(entry)!,
            ]
          : const [],
      widgetName: widget is Map && widget['name'] is String
          ? widget['name'] as String
          : null,
      localizedName:
          raw['localized_name'] is String ? raw['localized_name'] as String : null,
    );
  }
}

/// A node inside a UI-format workflow, with the fields the expander needs.
///
/// Nothing here is guessed: `widgetsValuesNamed` is written by the frontend's
/// `serialiseWidgetValues` alongside the positional array, and the per-slot
/// `widget.name` markers are what let a value be read by name instead of by
/// position. Both are exact for the workflows this was built against.
class UiNode {
  UiNode({
    required this.id,
    required this.type,
    this.mode = 0,
    this.title,
    this.inputs = const [],
    this.outputs = const [],
    this.widgetsValues,
    this.widgetsValuesNamed,
  });

  final Object? id;
  final String type;
  final int mode;
  final String? title;
  final List<UiSlot> inputs;
  final List<UiSlot> outputs;

  /// Positional widget values, in widget order (with seed controls interleaved).
  final List<Object?>? widgetsValues;

  /// `{widgetName: value}` as written by the current frontend.
  final Map<String, Object?>? widgetsValuesNamed;

  bool get isActive => mode != modeNever && mode != modeBypass;
  bool get isMuted => mode == modeNever;
  bool get isBypassed => mode == modeBypass;

  /// Widget names in serialization order, taken from this node's own slots.
  List<String> get widgetNames => [
        for (final slot in inputs)
          if (slot.widgetName != null) slot.widgetName!,
      ];

  static UiNode fromJson(Object? raw, {String where = 'node'}) {
    if (raw is! Map) {
      throw GraphExpansionError('$where is not an object');
    }
    final type = raw['type'];
    if (type is! String || type.isEmpty) {
      throw GraphExpansionError('$where has no type', details: {'id': raw['id']});
    }
    final title = raw['title'];
    final values = raw['widgets_values'];
    final named = raw['widgets_values_named'];
    return UiNode(
      id: raw['id'],
      type: type,
      mode: asInt(raw['mode']) ?? 0,
      title: title is String ? title : null,
      inputs: _slots(raw['inputs']),
      outputs: _slots(raw['outputs']),
      widgetsValues: values is List ? List<Object?>.from(values) : null,
      widgetsValuesNamed: named is Map
          ? {for (final entry in named.entries) '${entry.key}': entry.value}
          : null,
    );
  }

  static List<UiSlot> _slots(Object? raw) {
    if (raw is! List) return const [];
    return [for (final entry in raw) UiSlot.fromJson(entry)];
  }

  /// `{widgetName: value}`, skipping the seed control value that follows a
  /// seed widget in the positional array.
  ///
  /// Widgets the node never exposes as a named input have no name to key them
  /// by and are omitted; callers that need them fall back to the raw array.
  Map<String, Object?> widgetValuesByName() {
    final named = widgetsValuesNamed;
    final raw = widgetsValues;
    final names = widgetNames;

    if (named != null && named.isNotEmpty) {
      // The current frontend writes this map; it is authoritative and needs no
      // seed-control special case because controls are not widgets.
      final values = <String, Object?>{};
      for (final name in names) {
        if (named.containsKey(name)) values[name] = named[name];
      }
      // A named map can also carry widgets this node has no slot marker for.
      // Keep them: they are still real inputs.
      for (final entry in named.entries) {
        values.putIfAbsent(entry.key, () => entry.value);
      }
      return values;
    }

    if (raw == null) return const {};
    final values = <String, Object?>{};
    var cursor = 0;
    for (final name in names) {
      if (cursor >= raw.length) break;
      values[name] = raw[cursor];
      cursor += 1;
      final control = cursor < raw.length ? raw[cursor] : null;
      if (seedWidgetNames.contains(name) &&
          control is String &&
          seedControlValues.contains(control)) {
        cursor += 1;
      }
    }
    return values;
  }

  @override
  String toString() => 'UiNode($id, $type)';
}

/// One link of a UI-format graph, normalised from both shapes the frontend has
/// used over time:
///
/// * object: `{id, origin_id, origin_slot, target_id, target_slot, type}`
/// * legacy array: `[id, origin_id, origin_slot, target_id, target_slot, type]`
class UiLink {
  const UiLink({
    required this.id,
    required this.originId,
    required this.originSlot,
    required this.targetId,
    required this.targetSlot,
    this.type,
  });

  final int id;
  final Object? originId;
  final int originSlot;
  final Object? targetId;
  final int targetSlot;
  final String? type;

  static UiLink? fromJson(Object? raw) {
    if (raw is Map) {
      final id = asInt(raw['id']);
      if (id == null) return null;
      return UiLink(
        id: id,
        originId: raw['origin_id'],
        originSlot: asInt(raw['origin_slot']) ?? 0,
        targetId: raw['target_id'],
        targetSlot: asInt(raw['target_slot']) ?? 0,
        type: raw['type'] is String ? raw['type'] as String : null,
      );
    }
    if (raw is List && raw.length >= 5) {
      final id = asInt(raw[0]);
      if (id == null) return null;
      return UiLink(
        id: id,
        originId: raw[1],
        originSlot: asInt(raw[2]) ?? 0,
        targetId: raw[3],
        targetSlot: asInt(raw[4]) ?? 0,
        type: raw.length > 5 && raw[5] is String ? raw[5] as String : null,
      );
    }
    return null;
  }
}

/// A subgraph definition referenced by nodes whose `type` is its `id`.
class SubgraphDefinition {
  SubgraphDefinition({
    required this.id,
    required this.inputNodeId,
    required this.outputNodeId,
    required this.inputs,
    required this.outputs,
    required this.nodes,
    required this.links,
  });

  final String id;
  final Object? inputNodeId;
  final Object? outputNodeId;

  /// Promoted inputs, each `{name, type, label?}`.
  final List<Map<String, Object?>> inputs;

  /// Promoted outputs, each `{name, type, linkIds?}`.
  final List<Map<String, Object?>> outputs;

  final List<UiNode> nodes;
  final List<UiLink> links;

  /// Boundary node ids. The frontend uses `-10`/`-20` but a definition may
  /// declare its own, so both are honoured.
  static const Object defaultInputNodeId = -10;
  static const Object defaultOutputNodeId = -20;

  static SubgraphDefinition fromJson(Object? raw) {    if (raw is! Map) {
      throw GraphExpansionError('subgraph definition is not an object');
    }
    final id = raw['id'];
    if (id == null) {
      throw GraphExpansionError('subgraph definition has no id');
    }
    final inputNode = raw['inputNode'];
    final outputNode = raw['outputNode'];
    return SubgraphDefinition(
      id: '$id',
      inputNodeId: inputNode is Map ? inputNode['id'] : defaultInputNodeId,
      outputNodeId: outputNode is Map ? outputNode['id'] : defaultOutputNodeId,
      inputs: _maps(raw['inputs']),
      outputs: _maps(raw['outputs']),
      nodes: [
        for (final node in (raw['nodes'] is List ? raw['nodes'] as List : const <Object?>[]))
          if (node is Map) UiNode.fromJson(node, where: 'subgraph node'),
      ],
      links: [
        for (final link in (raw['links'] is List ? raw['links'] as List : const <Object?>[]))
          if (UiLink.fromJson(link) != null) UiLink.fromJson(link)!,
      ],
    );
  }

  static List<Map<String, Object?>> _maps(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          <String, Object?>{for (final e in entry.entries) '${e.key}': e.value},
    ];
  }
}

/// A UI-format workflow: the shape the ComfyUI frontend saves.
class UiWorkflow {
  UiWorkflow({
    required this.nodes,
    required this.links,
    required this.subgraphs,
    this.id,
    this.extra,
  });

  final List<UiNode> nodes;
  final List<UiLink> links;
  final Map<String, SubgraphDefinition> subgraphs;
  final String? id;

  /// Free-form `extra` bag the frontend uses (ds, rgthree, ...).
  final Map<String, Object?>? extra;

  bool get hasSubgraphs => subgraphs.isNotEmpty;

  static UiWorkflow fromJson(Map<String, Object?> raw) {
    final nodes = raw['nodes'];
    if (nodes is! List) {
      throw GraphExpansionError(
        'not a UI workflow: `nodes` is missing. '
        'An API-format workflow is a flat map of node ids instead.',
      );
    }
    final definitions = raw['definitions'];
    final subgraphList = definitions is Map && definitions['subgraphs'] is List
        ? definitions['subgraphs'] as List
        : const <Object?>[];
    final subgraphs = <String, SubgraphDefinition>{};
    for (final entry in subgraphList) {
      final definition = SubgraphDefinition.fromJson(entry);
      subgraphs[definition.id] = definition;
    }
    return UiWorkflow(
      id: raw['id'] is String ? raw['id'] as String : null,
      nodes: [
        for (final node in nodes)
          if (node is Map) UiNode.fromJson(node, where: 'workflow node'),
      ],
      links: [
        for (final link in (raw['links'] is List ? raw['links'] as List : const <Object?>[]))
          if (UiLink.fromJson(link) != null) UiLink.fromJson(link)!,
      ],
      subgraphs: subgraphs,
      extra: raw['extra'] is Map
          ? <String, Object?>{
              for (final e in (raw['extra'] as Map).entries) '${e.key}': e.value,
            }
          : null,
    );
  }

  /// True when [raw] looks like a UI workflow rather than an API prompt.
  static bool looksLikeUiWorkflow(Object? raw) {
    if (raw is! Map) return false;
    return raw['nodes'] is List;
  }
}
