import 'parameter.dart';

/// Minimal node definition taken from `/object_info`.
/// Only the parts the client needs are modelled: the declared inputs (to build
/// form fields and validate values), `input_order` (a stable order for widgets
/// that the serialized workflow does not name), and `output` (to know which
/// slot carries which type when a link has to be resolved by type).
class NodeDefinition {
  const NodeDefinition({
    required this.classType,
    required this.requiredInputs,
    required this.optionalInputs,
    required this.inputOrder,
    required this.outputs,
    this.displayName,
    this.category,
    this.outputNode = false,
  });

  final String classType;
  final Map<String, InputSpec> requiredInputs;
  final Map<String, InputSpec> optionalInputs;

  /// Declared order of input names, used to order form fields predictably.
  final List<String> inputOrder;

  /// `(name, type)` per output slot.
  final List<(String, String)> outputs;

  final String? displayName;
  final String? category;
  final bool outputNode;

  InputSpec? specFor(String inputName) =>
      requiredInputs[inputName] ?? optionalInputs[inputName];

  bool get isOutputNode => outputNode;

  static NodeDefinition fromJson(String classType, Object? raw) {
    final info = raw is Map ? raw : const {};
    final input = info['input'];
    final requiredRaw = input is Map ? input['required'] : null;
    final optionalRaw = input is Map ? input['optional'] : null;
    final order = input is Map && input['input_order'] is List
        ? [for (final entry in input['input_order'] as List) '$entry']
        : const <String>[];
    final outputs = info['output'];
    final outputNames = info['output_name'];

    return NodeDefinition(
      classType: classType,
      requiredInputs: _specs(requiredRaw),
      optionalInputs: _specs(optionalRaw),
      inputOrder: order,
      outputs: [
        for (var index = 0; index < (outputs is List ? outputs.length : 0); index += 1)
          (
            outputNames is List && index < outputNames.length
                ? '${outputNames[index]}'
                : 'output_$index',
            '${outputs[index]}',
          ),
      ],
      displayName: info['display_name'] is String ? info['display_name'] as String : null,
      category: info['category'] is String ? info['category'] as String : null,
      outputNode: info['output_node'] == true,
    );
  }

  static Map<String, InputSpec> _specs(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, InputSpec>{};
    for (final entry in raw.entries) {
      result['${entry.key}'] = InputSpec.fromJson(entry.value);
    }
    return result;
  }
}

/// One declared input of a node class, as `/object_info` describes it.
class InputSpec {
  const InputSpec({
    required this.type,
    this.options = const {},
    this.hasWidgetControl = false,
  });

  /// `INT`, `FLOAT`, `STRING`, `BOOLEAN`, `COMBO`, or a connection type.
  final String type;

  /// Combo option list, numeric bounds, and similar constraints.
  final Map<String, Object?> options;

  /// True when the server marks a seed-ish input as followed by a
  /// `control_after_generate` value.
  final bool hasWidgetControl;

  List<String>? get comboOptions {
    final values = options['options'];
    if (values is! List) return null;
    final result = <String>[];
    for (final value in values) {
      // Most combos list plain strings, but a dynamic combo
      // (`COMFY_DYNAMICCOMBO_V3`) lists `{key, inputs}` objects whose `key` is
      // the value that goes into the prompt.
      if (value is Map) {
        final key = value['key'];
        if (key != null) result.add('$key');
        continue;
      }
      result.add('$value');
    }
    return result;
  }

  num? get min => options['min'] is num ? options['min'] as num : null;
  num? get max => options['max'] is num ? options['max'] as num : null;
  num? get step => options['step'] is num ? options['step'] as num : null;

  bool get isWidget {
    const widgetTypes = {'INT', 'FLOAT', 'STRING', 'BOOLEAN', 'COMBO'};
    return widgetTypes.contains(type.toUpperCase());
  }

  static InputSpec fromJson(Object? raw) {
    // Shapes seen in ComfyUI's own `/object_info`:
    //   ["INT", {"default": 0, "min": 0, ...}]
    //   [["a", "b"], {"default": "a"}]          (COMBO as inline list)
    //   ["COMBO", {"options": ["a", "b"]}]
    if (raw is List && raw.isNotEmpty) {
      final typeRaw = raw.first;
      final spec = raw.length > 1 && raw[1] is Map ? raw[1] as Map : const {};
      final options = <String, Object?>{
        for (final entry in spec.entries) '${entry.key}': entry.value,
      };
      if (typeRaw is List) {
        return InputSpec(
          type: 'COMBO',
          options: {...options, 'options': typeRaw},
        );
      }
      return InputSpec(
        type: '$typeRaw',
        options: options,
        hasWidgetControl: spec['control_after_generate'] == true,
      );
    }
    if (raw is Map) {
      final options = <String, Object?>{
        for (final entry in raw.entries) '${entry.key}': entry.value,
      };
      return InputSpec(
        type: raw['type'] is String ? raw['type'] as String : 'COMBO',
        options: options,
        hasWidgetControl: raw['control_after_generate'] == true,
      );
    }
    return const InputSpec(type: 'STRING');
  }
}

/// A map of every node class the server knows, parsed from `/object_info`.
class NodeDefinitionRegistry {
  NodeDefinitionRegistry(this._definitions);

  final Map<String, NodeDefinition> _definitions;

  static final NodeDefinitionRegistry empty = NodeDefinitionRegistry(const {});

  int get length => _definitions.length;

  bool contains(String classType) => _definitions.containsKey(classType);

  NodeDefinition? operator [](String classType) => _definitions[classType];

  static NodeDefinitionRegistry fromJson(Object? raw) {
    if (raw is! Map) return NodeDefinitionRegistry.empty;
    return NodeDefinitionRegistry({
      for (final entry in raw.entries)
        '${entry.key}': NodeDefinition.fromJson('${entry.key}', entry.value),
    });
  }

  /// Configures [parameters] with the option lists and numeric bounds declared
  /// by the server.
  ///
  /// The workflow itself carries the *current* value of a combo, but not the
  /// alternatives; without this pass every dropdown would be a text field.
  ///
  /// [classTypesByExecId] maps an execution id (`867:27`) to the node class it
  /// runs, because a parameter knows the ids it writes to but not the classes.
  List<ParameterDef> enrich(
    List<ParameterDef> parameters, {
    Map<String, String> classTypesByExecId = const {},
  }) {
    final enriched = <ParameterDef>[];
    for (final parameter in parameters) {
      if (!parameter.isEditable || parameter.targets.isEmpty) {
        enriched.add(parameter);
        continue;
      }
      final target = parameter.targets.first;
      // Widget-backed inputs are named directly on the node, so the node class
      // has to come from the expanded prompt rather than the parameter.
      final classType = classTypesByExecId[target.execId];
      final definition = classType == null ? null : _definitions[classType];
      final spec = definition?.specFor(parameter.name);
      if (spec == null) {
        enriched.add(parameter);
        continue;
      }
      enriched.add(
        parameter.copyWith(
          options: spec.comboOptions ?? parameter.options,
          min: spec.min ?? parameter.min,
          max: spec.max ?? parameter.max,
          step: spec.step ?? parameter.step,
        ),
      );
    }
    return enriched;
  }

  /// Checks an expanded prompt against the server's own input declarations.
  ///
  /// This catches the failure mode that a saved workflow cannot reveal about
  /// itself: the JSON was written against a different set of installed models
  /// or custom nodes, so a value that was valid then is now out of range. The
  /// server answers `Value not in list` for these, but only *after* a submit;
  /// reporting it up front turns a confusing 400 into an actionable message.
  ///
  /// Returns one message per problem, empty when the prompt looks submit-ready.
  List<String> validatePrompt(Map<String, Object?> prompt) {
    final problems = <String>[];

    for (final entry in prompt.entries) {
      final execId = entry.key;
      final node = entry.value;
      if (node is! Map) continue;
      final classType = '${node['class_type']}';
      final definition = _definitions[classType];
      if (definition == null) {
        problems.add('节点 $execId 的类型 $classType 在服务器上不存在（缺少自定义节点）');
        continue;
      }
      final inputs = node['inputs'];
      if (inputs is! Map) continue;

      for (final input in inputs.entries) {
        final name = '${input.key}';
        final value = input.value;
        // Links are validated by the server's graph walk, not here.
        if (value is List || value is Map) continue;

        final spec = definition.specFor(name);
        if (spec == null) continue;

        final allowed = spec.comboOptions;
        if (allowed != null && allowed.isNotEmpty && value is String) {
          if (!allowed.contains(value)) {
            problems.add(
              '$execId.$name 的值 "$value" 不在服务器可选列表中'
              '（${definition.classType}，共 ${allowed.length} 项）',
            );
          }
          continue;
        }
        if (spec.type == 'INT' && value is num && value != value.roundToDouble()) {
          problems.add('$execId.$name 需要整数，收到 $value');
        }
      }
    }
    return problems;
  }
}
