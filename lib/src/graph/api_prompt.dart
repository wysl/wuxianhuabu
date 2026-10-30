/// One node of an API-format prompt.
///
/// The shape `POST /prompt` accepts: `{class_type, inputs, _meta?}`.
class ApiNode {
  ApiNode({
    required this.classType,
    required this.inputs,
    this.title,
  });

  /// The ComfyUI node class. Must exist in `/object_info`, otherwise the
  /// server answers 400 `missing_node_type`.
  final String classType;

  /// Input name -> literal value, or `[execId, slot]` for a link.
  final Map<String, Object?> inputs;

  final String? title;

  Map<String, Object?> toJson() => {
        'class_type': classType,
        'inputs': inputs,
        if (title != null && title!.isNotEmpty) '_meta': {'title': title},
      };

  @override
  String toString() => 'ApiNode($classType, ${inputs.length} inputs)';
}

/// One place a parameter value has to be written.
///
/// A promoted subgraph input can feed several inner nodes, so an edit has to
/// land on every one of them; keeping them as a list rather than a single
/// target is what makes multi-consumer parameters behave.
class ParameterTarget {
  const ParameterTarget({required this.execId, required this.inputName});

  final String execId;
  final String inputName;

  @override
  String toString() => '$execId.$inputName';

  Map<String, Object?> toJson() => {'exec_id': execId, 'input_name': inputName};

  static ParameterTarget fromJson(Map<String, Object?> raw) => ParameterTarget(
        execId: '${raw['exec_id']}',
        inputName: '${raw['input_name']}',
      );
}
