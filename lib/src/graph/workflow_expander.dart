import 'api_prompt.dart';
import 'parameter.dart';
import 'parameter_extractor.dart';
import 'ui_workflow.dart';

/// Expands a UI-format workflow into the API prompt that `POST /prompt`
/// accepts, and reports the editable parameters along the way.
///
/// ## Why this exists
///
/// `POST /prompt` only accepts the *API* shape: a flat map of
/// `node_id -> {class_type, inputs}` where each input is a literal or a
/// `[node_id, slot]` link. The official frontend builds that map in the
/// browser through `app.graphToPrompt()`, including the expansion of every
/// subgraph instance. A desktop client owns no graph, so the expansion has to
/// happen here.
///
/// ## What the remote instance proved
///
/// * An unknown `class_type` is a hard 400 (`missing_node_type`), so virtual
///   nodes must never reach the prompt.
/// * `SetNode`, `GetNode`, `Reroute` and `PrimitiveNode` are **absent** from
///   `/object_info` (4073 node types on a fully loaded instance): they are
///   frontend-only constructs and must be resolved, not forwarded.
///
/// ## Execution ids
///
/// Following the frontend convention of colon-separated node ids, e.g. `64:27`
/// for node 27 inside subgraph instance 64.
class WorkflowExpander {
  WorkflowExpander(this.workflow);

  final UiWorkflow workflow;

  final Map<String, ApiNode> _prompt = {};
  final List<ParameterDef> _parameters = [];
  final List<String> _warnings = [];

  /// `execId -> UiNode`, kept so the parameter extractor can read slot types
  /// and node titles without re-walking the graph.
  final Map<String, UiNode> _uiNodesByExecId = {};

  /// Execution ids of nodes that exist but do not run, so a link pointing at
  /// one can be spliced through instead of reported as broken.
  final Set<String> _bypassedNodes = {};

  /// Namespaces visible while walking, innermost last.
  ///
  /// A `GetNode` looks up its `Constant` name here. ComfyUI resolves these per
  /// graph scope, so a nested definition only sees its own SetNodes plus the
  /// ones of enclosing graphs.
  final List<Map<String, _SetBinding>> _scopes = [];

  ExpandedWorkflow expand({ParameterExtractorOptions? extractorOptions}) {
    _walk(_GraphScope.root(workflow), '', const {});

    // Promotions come first because they carry an authored label, then the
    // raw widget inputs fill the rest. Most real workflows declare no
    // subgraph at all, so without the second pass the form would be empty.
    final promoted = List<ParameterDef>.from(_parameters);
    final widgetParameters = ParameterExtractor(
      options: extractorOptions ?? const ParameterExtractorOptions(),
    ).fromWidgets(
      prompt: _prompt,
      nodesById: _uiNodesByExecId,
      existing: promoted,
    );

    return ExpandedWorkflow(
      prompt: Map.unmodifiable(_prompt),
      parameters: List.unmodifiable([...promoted, ...widgetParameters]),
      warnings: List.unmodifiable(_warnings),
    );
  }

  // -- traversal ----------------------------------------------------------

  void _walk(
    _GraphScope scope,
    String prefix,
    Map<int, _ResolvedLink> promoted,
  ) {
    final definition = scope.definition;
    _scopes.add(_collectSetBindings(scope, prefix));
    try {
      final links = {for (final link in scope.links) link.id: link};
      final nodes = <Object?, UiNode>{
        for (final node in scope.nodes) node.id: node,
      };

      final inputId = definition?.inputNodeId ??
          SubgraphDefinition.defaultInputNodeId;
      final outputId = definition?.outputNodeId ??
          SubgraphDefinition.defaultOutputNodeId;

      for (final node in scope.nodes) {
        // Boundary nodes only exist to carry promotions; they are not executed.
        if (node.id == inputId || node.id == outputId) continue;
        final execId = '$prefix${node.id}';
        if (!node.isActive) {
          // Muted (`mode == 2`) and bypassed (`mode == 4`) nodes are not
          // executed. A bypass is *not* simply dropped though: its output must
          // be spliced from a same-typed input. `_resolveLink` handles that at
          // the consumer's side by walking through the bypassed node.
          if (node.isMuted) continue;
          _bypassedNodes.add(execId);
          _uiNodesByExecId[execId] = node;
          continue;
        }
        if (virtualNodeTypes.contains(node.type)) continue;
        // Value broadcasters are frontend-only too: they inline into consumers
        // and have no server-side implementation to run.
        if (valueBroadcastNodeTypes.contains(node.type)) continue;

        final sub = workflow.subgraphs[node.type];
        if (sub != null) {
          final incoming = _instanceIncomingLinks(
            node,
            links,
            promoted,
            inputId,
            nodes,
            prefix,
          );
          _walkInstance(node, sub, execId, const {}, incoming);
          continue;
        }
        _prompt[execId] = _buildNode(node, nodes, links, prefix, promoted, inputId);
        _uiNodesByExecId[execId] = node;
      }
    } finally {
      _scopes.removeLast();
    }
  }

  void _walkInstance(
    UiNode instance,
    SubgraphDefinition definition,
    String execId,
    Map<String, Object?> overrides,
    Map<int, _ResolvedLink> incomingLinks,
  ) {
    final widgets = <String, Object?>{}
      ..addAll(instance.widgetValuesByName())
      ..addAll(overrides);

    final innerLinks = {for (final link in definition.links) link.id: link};
    final innerNodes = <Object?, UiNode>{
      for (final node in definition.nodes) node.id: node,
    };
    final inputId = definition.inputNodeId;

    final promoted = <int, _ResolvedLink>{};
    for (var index = 0; index < definition.inputs.length; index += 1) {
      final entry = definition.inputs[index];
      final name = '${entry['name'] ?? ''}';
      if (name.isEmpty) continue;
      final slotType = '${entry['type'] ?? ''}';
      // A promoted input is either fed by a link from the enclosing graph, or
      // it keeps a literal value in the instance's widget bag. The link wins,
      // because that is what the frontend substitutes at execution time.
      final incoming = incomingLinks[index];
      final value = widgets[name];
      promoted[index] = incoming ?? _InlineValue(value);
      final targets =
          _promotedTargets(index, innerLinks, innerNodes, inputId);
      _parameters.add(
        ParameterDef(
          key: '$execId:$name',
          name: name,
          label: _labelOf(entry) ?? name,
          type: slotType,
          value: value,
          targets: [
            for (final target in targets)
              ParameterTarget(
                execId: '$execId:${target.$1}',
                inputName: target.$2,
              ),
          ],
          group: instance.title,
        ),
      );
    }

    _walk(_GraphScope.subgraph(definition), '$execId:', promoted);
  }

  /// Links feeding a subgraph instance's promoted inputs, keyed by *promoted
  /// input index*.
  ///
  /// An instance's input slots appear in the same order as the definition's
  /// declared inputs, so slot N corresponds to promoted input N. A slot is
  /// either connected in the enclosing graph — in which case execution splices
  /// that producer straight into the inner consumer — or it keeps a literal in
  /// the instance's widget bag.
  Map<int, _ResolvedLink> _instanceIncomingLinks(
    UiNode instance,
    Map<int, UiLink> links,
    Map<int, _ResolvedLink> promoted,
    Object? inputNodeId,
    Map<Object?, UiNode> nodes,
    String prefix,
  ) {
    final incoming = <int, _ResolvedLink>{};
    for (var slot = 0; slot < instance.inputs.length; slot += 1) {
      final linkId = instance.inputs[slot].link;
      if (linkId == null) continue;
      final link = links[linkId];
      if (link == null) continue;

      if (link.originId == inputNodeId) {
        // Nested subgraph: the value is whatever the enclosing graph promoted
        // into this same index.
        final resolved = promoted[link.originSlot];
        if (resolved != null) incoming[slot] = resolved;
        continue;
      }
      final resolved =
          _resolveLink(nodes, links, link.originId, link.originSlot, prefix);
      if (resolved != null) incoming[slot] = resolved;
    }
    return incoming;
  }

  /// `(innerNodeId, inputName)` pairs fed by promoted input [index].
  List<(String, String)> _promotedTargets(
    int index,
    Map<int, UiLink> innerLinks,
    Map<Object?, UiNode> innerNodes,
    Object? inputNodeId,
  ) {
    final found = <(String, String)>[];
    for (final link in innerLinks.values) {
      if (link.originId != inputNodeId) continue;
      if (link.originSlot != index) continue;
      final target = innerNodes[link.targetId];
      if (target == null) continue;
      if (link.targetSlot < 0 || link.targetSlot >= target.inputs.length) {
        continue;
      }
      final name = target.inputs[link.targetSlot].name;
      if (name != null && name.isNotEmpty) {
        found.add(('${target.id}', name));
      }
    }
    return found;
  }

  // -- node building ------------------------------------------------------

  ApiNode _buildNode(
    UiNode node,
    Map<Object?, UiNode> nodes,
    Map<int, UiLink> links,
    String prefix,
    Map<int, _ResolvedLink> promoted,
    Object? inputNodeId,
  ) {
    final widgets = node.widgetValuesByName();
    final inputs = <String, Object?>{};

    for (final slot in node.inputs) {
      final name = slot.name;
      if (name == null || name.isEmpty) continue;
      final linkId = slot.link;
      if (linkId == null) {
        if (widgets.containsKey(name)) inputs[name] = widgets[name];
        continue;
      }
      final link = links[linkId];
      if (link == null) continue;

      if (link.originId == inputNodeId) {
        // A promotion overrides whatever the inner node serialised.
        final promotedValue = promoted[link.originSlot];
        if (promotedValue != null) {
          switch (promotedValue) {
            case _LinkRef(:final execId, :final slot):
              inputs[name] = [execId, slot];
            case _InlineValue(:final value):
              inputs[name] = value;
          }
        }
        continue;
      }

      final resolved = _resolveLink(nodes, links, link.originId, link.originSlot, prefix);
      switch (resolved) {
        case _LinkRef(:final execId, :final slot):
          inputs[name] = [execId, slot];
        case _InlineValue(:final value):
          // A value broadcaster hands the consumer a literal.
          inputs[name] = value;
        case null:
          // The link exists in the workflow but no producer could be found. That
          // means a GetNode whose SetNode is missing, a link into a node that is
          // bypassed, or a genuinely broken save. Dropping the input silently
          // makes ComfyUI reject the whole prompt during validation with a
          // cryptic `required_input_missing`, so say what happened instead.
          _warnings.add(
            '节点 ${node.id}(${node.type}) 的输入 $name 无法解析到上游节点'
            '（链路 origin=${link.originId} slot=${link.originSlot}），已省略',
          );
      }
    }

    for (final entry in widgets.entries) {
      inputs.putIfAbsent(entry.key, () => entry.value);
    }

    return ApiNode(classType: node.type, inputs: inputs, title: node.title);
  }

  /// Resolves a link origin to either a node reference or a literal value.
  ///
  /// Passing through Reroute nodes, GetNode/SetNode pairs and subgraph
  /// instances; stopping at value broadcasters.
  _ResolvedLink? _resolveLink(
    Map<Object?, UiNode> nodes,
    Map<int, UiLink> links,
    Object? origin,
    int slotIndex,
    String prefix,
  ) {
    final seen = <Object?>{};
    var current = origin;
    var currentSlot = slotIndex;
    var currentPrefix = prefix;

    while (current != null) {
      if (!seen.add(current)) return null;
      final node = nodes[current];
      if (node == null) return null;

      final sub = workflow.subgraphs[node.type];
      if (sub != null && node.isActive) {
        final inner = _instanceOutput(node, sub, currentSlot, currentPrefix);
        return inner == null ? null : _LinkRef(inner.$1, inner.$2);
      }
      if (node.type == 'Reroute') {
        final upstream = node.inputs;
        if (upstream.isEmpty) return null;
        final linkId = upstream.first.link;
        if (linkId == null) return null;
        final link = links[linkId];
        if (link == null) return null;
        current = link.originId;
        currentSlot = link.originSlot;
        continue;
      }
      if (node.type == 'GetNode') {
        // A GetNode publishes whatever its matching SetNode is fed from. The
        // pair can live in an enclosing graph scope, so the lookup walks the
        // scope stack from innermost outward.
        final resolved = _resolveGet(node);
        if (resolved == null) return null;
        current = resolved.$1;
        currentSlot = resolved.$2;
        currentPrefix = resolved.$3;
        continue;
      }
      final broadcast = _broadcastValueOf(node, currentSlot);
      if (broadcast != _noValue) return _InlineValue(broadcast);

      if (node.isBypassed) {
        // A bypassed node does not run: the frontend splices its output from a
        // same-typed input so the graph keeps a producer. Without this the
        // consumer would point at a node that is not in the prompt, and
        // ComfyUI answers `required_input_missing`.
        //
        // A bypassed *subgraph instance* has no inner nodes at all, so its
        // same-typed input is the only way out — which is exactly the case
        // below, whether the instance wraps a definition or not.
        final outputType = currentSlot < node.outputs.length
            ? node.outputs[currentSlot].type
            : null;
        UiSlot? replacement;
        for (final input in node.inputs) {
          if (input.link == null) continue;
          if (outputType != null && input.type != outputType) continue;
          replacement = input;
          break;
        }
        if (replacement == null) return null;
        final link = links[replacement.link!];
        if (link == null) return null;
        current = link.originId;
        currentSlot = link.originSlot;
        continue;
      }
      return _LinkRef('$currentPrefix$current', currentSlot);
    }
    return null;
  }

  /// The literal a value-broadcasting node publishes on [slot], if any.
  Object? _broadcastValueOf(UiNode node, int slot) {
    final isBroadcaster = node.type == 'PrimitiveNode' ||
        valueBroadcastNodeTypes.contains(node.type);
    if (!isBroadcaster) return _noValue;

    // Broadcasters keep their published values in widget order: output slot N
    // carries widget value N. Named values are preferred when the frontend
    // wrote them, because they survive widget reordering.
    final outputs = node.outputs;
    if (slot >= 0 && slot < outputs.length) {
      final widgetName = outputs[slot].widgetName;
      final named = node.widgetsValuesNamed;
      if (widgetName != null && named != null && named.containsKey(widgetName)) {
        return named[widgetName];
      }
    }
    final raw = node.widgetsValues;
    if (raw == null || slot < 0 || slot >= raw.length) return _noValue;
    return raw[slot];
  }

  /// Follows a `GetNode` to the node producing its value.
  ///
  /// Returns `(originNodeId, originSlot, prefixOfOwningScope)` so the caller can
  /// keep walking in the scope the producer lives in.
  (Object?, int, String)? _resolveGet(UiNode getNode) {
    final name = _constantOf(getNode);
    if (name == null) return null;
    for (var index = _scopes.length - 1; index >= 0; index -= 1) {
      final binding = _scopes[index][name];
      if (binding == null) continue;
      final linkId = binding.linkId;
      if (linkId == null) return null;
      final link = binding.scope.links
          .where((candidate) => candidate.id == linkId)
          .firstOrNull;
      if (link == null) return null;
      return (link.originId, link.originSlot, binding.prefix);
    }
    return null;
  }

  /// Resolves a link leaving a subgraph instance to a concrete inner node.
  (String, int)? _instanceOutput(
    UiNode instance,
    SubgraphDefinition definition,
    int slotIndex,
    String prefix,
  ) {
    final innerLinks = {for (final link in definition.links) link.id: link};
    final innerNodes = <Object?, UiNode>{
      for (final node in definition.nodes) node.id: node,
    };
    final outputId = definition.outputNodeId;
    final instanceExec = '$prefix${instance.id}';

    final candidates = <UiLink>[];
    if (slotIndex < definition.outputs.length) {
      final declared = definition.outputs[slotIndex]['linkIds'];
      if (declared is List) {
        for (final id in declared) {
          final link = innerLinks[asInt(id)];
          if (link != null) candidates.add(link);
        }
      }
    }
    candidates.addAll(
      innerLinks.values.where((link) => link.targetId == outputId),
    );

    for (final link in candidates) {
      final origin = link.originId;
      final originSlot = link.originSlot;
      final innerNode = innerNodes[origin];
      if (innerNode == null) continue;

      final nested = workflow.subgraphs[innerNode.type];
      if (nested != null) {
        final resolved = _instanceOutput(innerNode, nested, originSlot, '$instanceExec:');
        if (resolved != null) return resolved;
        continue;
      }
      return ('$instanceExec:$origin', originSlot);
    }
    return null;
  }

  // -- SetNode / GetNode --------------------------------------------------

  /// Indexes a graph's `SetNode`s by their `Constant` name.
  Map<String, _SetBinding> _collectSetBindings(
    _GraphScope scope,
    String prefix,
  ) {
    final bindings = <String, _SetBinding>{};
    for (final node in scope.nodes) {
      if (node.type != 'SetNode') continue;
      final name = _constantOf(node);
      if (name == null) continue;
      // The value a SetNode publishes is whatever feeds its first input.
      final linkId = node.inputs.isEmpty ? null : node.inputs.first.link;
      bindings[name] = _SetBinding(
        scope: scope,
        node: node,
        linkId: linkId,
        prefix: prefix,
      );
    }
    return bindings;
  }

  static String? _constantOf(UiNode node) {
    final named = node.widgetsValuesNamed;
    if (named != null && named['Constant'] != null) {
      return '${named['Constant']}';
    }
    final raw = node.widgetsValues;
    if (raw != null && raw.isNotEmpty) return '${raw.first}';
    return null;
  }

  static String? _labelOf(Map<String, Object?> entry) {
    final label = entry['label'] ?? entry['localizedName'];
    if (label is String && label.isNotEmpty) return label;
    return null;
  }
}

/// Sentinel meaning "this node is not a value broadcaster".
const Object _noValue = Object();

/// What a link resolved to: either a reference to another node's output slot,
/// or a literal value inlined by a broadcaster.
sealed class _ResolvedLink {
  const _ResolvedLink();
}

class _LinkRef extends _ResolvedLink {
  const _LinkRef(this.execId, this.slot);

  final String execId;
  final int slot;
}

class _InlineValue extends _ResolvedLink {
  const _InlineValue(this.value);

  final Object? value;
}

/// A graph being walked: either the workflow root or one subgraph definition.
/// Both carry `nodes` and `links`; only a subgraph carries boundary ids and
/// promoted input declarations. Passing it as one type keeps the traversal
/// identical for both, which is what makes nested subgraphs fall out for free.
class _GraphScope {
  const _GraphScope({
    required this.nodes,
    required this.links,
    this.definition,
  });

  factory _GraphScope.root(UiWorkflow workflow) =>
      _GraphScope(nodes: workflow.nodes, links: workflow.links);

  factory _GraphScope.subgraph(SubgraphDefinition definition) => _GraphScope(
        nodes: definition.nodes,
        links: definition.links,
        definition: definition,
      );

  final List<UiNode> nodes;
  final List<UiLink> links;
  final SubgraphDefinition? definition;
}

/// One `SetNode`, the link feeding it, and the execution-id prefix of the graph
/// it lives in.
class _SetBinding {
  const _SetBinding({
    required this.scope,
    required this.node,
    required this.linkId,
    required this.prefix,
  });

  final _GraphScope scope;
  final UiNode node;
  final int? linkId;

  /// Prefix of the scope owning this SetNode, so a GetNode resolved from a
  /// nested graph still yields the producer's real execution id.
  final String prefix;
}

/// The result of expanding a UI workflow.
class ExpandedWorkflow {
  const ExpandedWorkflow({
    required this.prompt,
    required this.parameters,
    required this.warnings,
  });

  /// `execId -> ApiNode`, ready for `POST /prompt`.
  final Map<String, ApiNode> prompt;

  /// Editable parameters discovered while expanding.
  final List<ParameterDef> parameters;

  /// Non-fatal problems (skipped inputs, unresolvable optional links, ...).
  final List<String> warnings;

  Map<String, Object?> toPromptJson() => {
        for (final entry in prompt.entries) entry.key: entry.value.toJson(),
      };
}
