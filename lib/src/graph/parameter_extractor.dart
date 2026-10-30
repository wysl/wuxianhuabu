import 'api_prompt.dart';
import 'parameter.dart';
import 'ui_workflow.dart';

/// Inputs that are plumbing rather than user intent.
///
/// A filename prefix, a sampler name or an upload button is technically an
/// editable widget, but showing 40 of them per workflow buries the two fields
/// the user actually came to change. These are hidden by default and revealed
/// through [ParameterExtractorOptions.includeTechnical].
const Set<String> technicalInputNames = {
  // Output plumbing.
  'filename_prefix',
  'prefix',
  'output_dir',
  'save_output',
  'pingpong',
  'loop_count',
  'overwrite',
  // Upload buttons, not values.
  'upload',
  'image_upload',
  'video_upload',
  'audio_upload',
  // Seed control pseudo-widget.
  'control_after_generate',
  // Model / sampler selection: real values, but rarely the point of a form.
  'ckpt_name',
  'unet_name',
  'clip_name',
  'vae_name',
  'lora_name',
  'control_net_name',
  'style_model_name',
  'gligen_name',
  'upscale_model',
  'sampler_name',
  'scheduler',
  'weight_dtype',
  'device',
  'format',
  'codec',
  'frame_rate',
  'fps',
  'type',
  'dtype',
};

/// Names that usually carry the *text* the user wants to write.
const Set<String> promptishInputNames = {
  'text',
  'prompt',
  'string',
  'value',
  'content',
  'caption',
  'instruction',
  'positive',
  'negative',
  'wildcard_text',
  'populated_text',
};

/// Node classes whose widget is a media file name.
const Map<String, String> mediaInputByClass = {
  'LoadImage': 'image',
  'LoadImageMask': 'image',
  'LoadImageOutput': 'image',
  'LoadVideo': 'file',
  'LoadAudio': 'audio',
  'VHS_LoadVideo': 'video',
  'VHS_LoadAudio': 'audio',
  'Load Image': 'image',
};

/// How aggressively to surface parameters.
///
/// The default is deliberately narrow. A workflow that already runs correctly in
/// ComfyUI has its model/sampler/file widgets set to values the *server* agrees
/// with; re-exposing them as editable fields adds no capability and actively
/// causes false failures, because a client-side check then reports a stale
/// filename that the pipeline would never have touched. The author's own
/// handles are the promoted subgraph inputs and the `QQ-多值输入` broadcast
/// nodes — exactly what a workflow is published with when it is meant to be
/// driven from outside.
class ParameterExtractorOptions {
  const ParameterExtractorOptions({
    this.includeTechnical = false,
    this.promptishOnly = false,
    this.promotedAndBroadcastOnly = true,
    this.multilineStringThreshold = 60,
  });

  /// Include model/sampler/filename widgets as well.
  final bool includeTechnical;

  /// Only expose text-like and numeric fields, hiding every model selector.
  final bool promptishOnly;

  /// Restrict the form to values the workflow author explicitly published:
  /// promoted subgraph inputs, and widgets carrying a `QQ-多值输入` value.
  ///
  /// Widgets that merely *exist* on a node are left to the saved workflow. This
  /// keeps the "the pipeline already works" property intact: nothing this client
  /// shows can disagree with the graph it was saved with.
  final bool promotedAndBroadcastOnly;

  /// Strings longer than this render as multi-line.
  final int multilineStringThreshold;
}

/// Builds the editable form for an expanded prompt.
///
/// Promoted subgraph inputs are the *ideal* source: they carry a label and a
/// deliberate choice by the workflow author. But most real workflows use no
/// subgraph at all (12 of the 13 workflows captured from a live instance had
/// none), so widget inputs have to be surfaced directly or the form is empty.
///
/// Order of preference, highest first:
///  1. promoted subgraph inputs (already collected by the expander)
///  2. widget inputs on `PrimitiveNode`-fed slots
///  3. widget inputs that are text or numeric
///  4. every remaining widget input, when `includeTechnical` is on
class ParameterExtractor {
  const ParameterExtractor({
    this.options = const ParameterExtractorOptions(),
  });

  final ParameterExtractorOptions options;

  /// Collects parameters from the value-broadcast nodes (`QQ-多值输入` and
  /// friends).
  ///
  /// These nodes never appear in the prompt — the expander inlines their values
  /// into every consumer — so they cannot be found by walking the prompt. They
  /// are read from the UI graph instead, and each one's targets are the slots
  /// that received the inlined value. That is what makes editing the value here
  /// reach the pipeline: the patcher writes to the consumer slots, which is the
  /// same place the expander wrote to.
  List<ParameterDef> fromBroadcastNodes({
    required List<UiNode> nodes,
    required Map<String, ApiNode> prompt,
    Map<int, UiLink> links = const {},
    Map<String, UiNode> nodesById = const {},
    String prefix = '',
  }) {
    final parameters = <ParameterDef>[];
    for (final node in nodes) {
      if (!valueBroadcastNodeTypes.contains(node.type)) continue;
      if (node.isMuted || node.isBypassed) continue;

      // Widget value per output slot, in the same order the expander uses.
      final values = node.widgetsValuesNamed ?? _positionalWidgets(node);
      for (var slot = 0; slot < node.outputs.length; slot++) {
        final output = node.outputs[slot];
        // The output's `*` slot is the node's passthrough ("连接到控件输入"),
        // not a published value.
        if (output.widgetName == null && output.type == '*') continue;
        final label = output.localizedName?.isNotEmpty == true
            ? output.localizedName
            : output.widgetName;
        final value = _valueForSlot(node, values, slot);
        if (value == null) continue;

        // Follow the real links first: that is exact, and it is what the expander
        // itself walked when inlining the value.
        var targets = _linkedTargets(
          node: node,
          slot: slot,
          links: links,
          nodesById: nodesById,
          prefix: prefix,
          prompt: prompt,
        );
        // Broadcast outputs may also be consumed from outside the scope that
        // declares the links; fall back to value matching only then.
        targets = targets.isEmpty
            ? _broadcastTargets(node, slot, prompt)
            : targets;
        if (targets.isEmpty) continue;

        parameters.add(
          ParameterDef(
            key: 'broadcast-${node.id}-$slot',
            name: label ?? 'value$slot',
            label: label?.isNotEmpty == true
                ? label!
                : '${node.title ?? node.type} · ${slot + 1}',
            type: _inferType(value),
            value: value,
            targets: targets,
            group: node.title,
            multiline: value is String &&
                (value.length > options.multilineStringThreshold ||
                    value.contains('\n')),
          ),
        );
      }
    }
    return parameters;
  }

  /// Walks this broadcast output's links to the exact prompt slots it fed.
  ///
  /// Exactness matters: value matching on a boolean like `false` would hit every
  /// unrelated `False` input in the prompt and make one edit rewrite them all.
  List<ParameterTarget> _linkedTargets({
    required UiNode node,
    required int slot,
    required Map<int, UiLink> links,
    required Map<String, UiNode> nodesById,
    required String prefix,
    required Map<String, ApiNode> prompt,
  }) {
    final output = node.outputs[slot];
    final targets = <ParameterTarget>[];
    for (final linkId in output.links) {
      final link = links[linkId];
      if (link == null) continue;
      final targetNode = nodesById['${link.targetId}'];
      if (targetNode == null) continue;
      final inputName = _inputNameAt(targetNode, link.targetSlot);
      if (inputName == null) continue;
      final execId = '$prefix${link.targetId}';
      if (!prompt.containsKey(execId)) continue;
      final target = ParameterTarget(execId: execId, inputName: inputName);
      if (!targets.any((existing) =>
          existing.execId == target.execId &&
          existing.inputName == target.inputName)) {
        targets.add(target);
      }
    }
    return targets;
  }

  static String? _inputNameAt(UiNode node, int slot) {
    final candidates = <String?>[
      if (slot >= 0 && slot < node.inputs.length) node.inputs[slot].name,
      if (slot >= 0 && slot < node.inputs.length)
        node.inputs[slot].widgetName,
    ];
    for (final candidate in candidates) {
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    return null;
  }

  /// Widget values keyed by output slot for a broadcaster that only serialized a
  /// positional array.
  Map<String, Object?> _positionalWidgets(UiNode node) {
    final map = <String, Object?>{};
    final raw = node.widgetsValues;
    if (raw == null) return map;
    for (var slot = 0; slot < node.outputs.length; slot++) {
      if (slot >= raw.length) break;
      map['value_${slot + 1}'] = raw[slot];
    }
    return map;
  }

  Object? _valueForSlot(
    UiNode node,
    Map<String, Object?> values,
    int slot,
  ) {
    // Broadcast nodes serialize their published values as `value_1 .. value_N`
    // (one per output), *not* under their widget names. `widgetsValuesNamed`
    // therefore cannot be looked up by `widgetName`; the positional index is the
    // reliable key here.
    final positionalName = 'value_${slot + 1}';
    if (values.containsKey(positionalName)) return values[positionalName];

    final widgetName = node.outputs[slot].widgetName;
    if (widgetName != null && values.containsKey(widgetName)) {
      return values[widgetName];
    }
    // Fall back to the serialized array by widget position.
    final raw = node.widgetsValues;
    if (raw != null && slot < raw.length) return raw[slot];
    return null;
  }

  /// Slots in the prompt that hold this broadcast output's value.
  ///
  /// After inlining there is no link left to follow, so the match is by value:
  /// every prompt input of a compatible type whose value equals the broadcast
  /// value is a place the expander wrote it. Ambiguity is acceptable here — they
  /// all carried the same value, and the user is editing that shared value.
  List<ParameterTarget> _broadcastTargets(
    UiNode node,
    int slot,
    Map<String, ApiNode> prompt,
  ) {
    final value = _valueForSlot(
      node,
      node.widgetsValuesNamed ?? _positionalWidgets(node),
      slot,
    );
    if (value == null) return const [];

    final targets = <ParameterTarget>[];
    for (final entry in prompt.entries) {
      for (final input in entry.value.inputs.entries) {
        if (_sameValue(input.value, value)) {
          targets.add(
            ParameterTarget(execId: entry.key, inputName: input.key),
          );
        }
      }
    }
    return targets;
  }

  static bool _sameValue(Object? a, Object? b) {
    if (a == b) return true;
    if (a is num && b is num) return a.toDouble() == b.toDouble();
    if (a is String && b is String) return a == b;
    return false;
  }

  /// Extracts widget parameters from [prompt], skipping any [execId] already
  /// covered by [existing] (i.e. promoted parameters).
  ///
  /// [nodesById] provides the UI nodes so widget types can be read from the
  /// serialized slot markers; [classTypes] keeps display labels honest.
  List<ParameterDef> fromWidgets({
    required Map<String, ApiNode> prompt,
    required Map<String, UiNode> nodesById,
    List<ParameterDef> existing = const [],
    Map<String, String>? labels,
  }) {
    final covered = <String>{};
    for (final parameter in existing) {
      for (final target in parameter.targets) {
        covered.add('${target.execId}.${target.inputName}');
      }
    }

    final parameters = <ParameterDef>[];
    for (final entry in prompt.entries) {
      final execId = entry.key;
      final node = entry.value;
      final uiNode = nodesById[execId];

      for (final input in node.inputs.entries) {
        final inputName = input.key;
        final value = input.value;

        // Links, lists and maps are not values.
        if (value is List || value is Map) continue;
        if (covered.contains('$execId.$inputName')) continue;
        if (technicalInputNames.contains(inputName)) {
          if (!options.includeTechnical) continue;
        }

        final slotType = _slotTypeOf(uiNode, inputName);
        if (slotType == null && !options.includeTechnical) {
          // No slot marker means the widget is not declared on the node, so
          // its type is unknown. Without a type there is no safe editor.
          continue;
        }

        // The narrow default: only what the author published. A `PrimitiveNode`
        // is an explicit "this is a knob" marker, so it still qualifies even
        // though it is not a broadcast node.
        if (options.promotedAndBroadcastOnly && !options.includeTechnical) {
          final fedByPrimitive = _fedByPrimitive(uiNode, inputName);
          if (!fedByPrimitive) continue;
        }

        final type = slotType ?? _inferType(value);
        if (!_isWidgetType(type)) continue;
        if (options.promptishOnly && !_isPromptish(inputName, value)) continue;

        parameters.add(
          ParameterDef(
            key: '$execId.$inputName',
            name: inputName,
            label: labels?[inputName] ??
                (uiNode?.title?.isNotEmpty == true
                    ? '${uiNode!.title} · $inputName'
                    : inputName),
            type: type,
            value: value,
            targets: [ParameterTarget(execId: execId, inputName: inputName)],
            group: uiNode?.title,
            multiline: type == 'STRING' &&
                value is String &&
                (value.length > options.multilineStringThreshold ||
                    value.contains('\n')),
            media: mediaInputByClass[uiNode?.type ?? ''] == inputName
                ? _mediaKind(uiNode!.type)
                : null,
          ),
        );
      }
    }
    return parameters;
  }

  /// Whether [inputName] on [node] is fed by a `PrimitiveNode`.
  ///
  /// A primitive is the frontend's own "expose this as a knob" marker, so it is
  /// author intent in the same sense a promoted subgraph input is.
  static bool _fedByPrimitive(UiNode? node, String inputName) {
    if (node == null) return false;
    for (final slot in node.inputs) {
      if (slot.name != inputName) continue;
      // `widgetName` present means the value lives in widgets_values, i.e. it is
      // a plain widget, not a promoted/published input.
      if (slot.widgetName != null) return false;
      return slot.link != null;
    }
    return false;
  }

  static String? _slotTypeOf(UiNode? node, String inputName) {    if (node == null) return null;
    for (final slot in node.inputs) {
      if (slot.name == inputName) {
        final type = slot.type;
        if (type == null) continue;
        // A widget-backed slot reports its widget type; a converted input
        // reports the connection type, which is not editable.
        if (slot.widgetName == null && widgetKinds.contains(type)) return null;
        return type;
      }
    }
    return null;
  }

  static String _inferType(Object? value) {
    if (value is bool) return 'BOOLEAN';
    if (value is int) return 'INT';
    if (value is double) return 'FLOAT';
    return 'STRING';
  }

  static bool _isWidgetType(String type) {
    final upper = type.toUpperCase();
    if (widgetKinds.contains(upper)) return true;
    // Custom widget types such as `LORA_STACK` are still pickers; the frontend
    // renders them, so treat unknown scalar types as text rather than dropping
    // them silently.
    return upper != 'MODEL' &&
        upper != 'CLIP' &&
        upper != 'VAE' &&
        upper != 'LATENT' &&
        upper != 'IMAGE' &&
        upper != 'MASK' &&
        upper != 'CONDITIONING';
  }

  static bool _isPromptish(String inputName, Object? value) {
    if (promptishInputNames.contains(inputName)) return true;
    return value is num || value is bool;
  }

  static String? _mediaKind(String classType) {
    if (classType.contains('Audio')) return 'audio';
    if (classType.contains('Video')) return 'video';
    if (classType.contains('Image')) return 'image';
    return null;
  }
}
