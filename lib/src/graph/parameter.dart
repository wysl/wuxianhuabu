import 'api_prompt.dart';

/// A user-editable value discovered inside a workflow.
///
/// Parameters are what make "no API JSON import" work for the user: the form is
/// derived from the graph, and submitting writes each value back to every
/// `(_execId, inputName)` pair the parameter feeds.
class ParameterDef {
  ParameterDef({
    required this.key,
    required this.name,
    required this.label,
    required this.type,
    required this.value,
    required this.targets,
    this.group,
    this.options,
    this.min,
    this.max,
    this.step,
    this.multiline = false,
    this.media,
    this.hidden = false,
  });

  /// Stable identifier used as the form field key, e.g. `867:unet_name`.
  final String key;

  /// Raw input name, e.g. `unet_name`.
  final String name;

  /// Display label, e.g. `LoRA堆可选` or `UNet名称`.
  final String label;

  /// Slot type as declared: `INT`, `FLOAT`, `STRING`, `BOOLEAN`, `COMBO`, or a
  /// custom type such as `LORA_STACK`.
  final String type;

  /// Current value taken from the workflow.
  final Object? value;

  /// Every node input this parameter writes to.
  final List<ParameterTarget> targets;

  /// Section the form groups this under; the subgraph instance title when the
  /// parameter came from a promotion.
  final String? group;

  /// Allowed values for `COMBO` parameters, when known.
  final List<String>? options;

  final num? min;
  final num? max;
  final num? step;

  /// Rendered as a multi-line text area.
  final bool multiline;

  /// `image`, `video` or `audio` when this parameter names a media file, which
  /// turns the field into a picker with upload.
  final String? media;

  final bool hidden;

  bool get isCombo => type.toUpperCase() == 'COMBO' || options != null;
  bool get isNumeric => type == 'INT' || type == 'FLOAT';
  bool get isBoolean => type == 'BOOLEAN';
  bool get isString => type == 'STRING';
  bool get isMedia => media != null;

  /// True when this type is editable as a plain value. Types such as
  /// `LORA_STACK` or `MODEL` are connections, not widgets, and must not be
  /// offered as text fields.
  bool get isEditable =>
      isCombo || isNumeric || isBoolean || isString || isMedia;

  ParameterDef copyWith({
    Object? value,
    List<String>? options,
    num? min,
    num? max,
    num? step,
    bool? multiline,
    String? media,
    String? group,
    bool? hidden,
  }) =>
      ParameterDef(
        key: key,
        name: name,
        label: label,
        type: type,
        value: value ?? this.value,
        targets: targets,
        group: group ?? this.group,
        options: options ?? this.options,
        min: min ?? this.min,
        max: max ?? this.max,
        step: step ?? this.step,
        multiline: multiline ?? this.multiline,
        media: media ?? this.media,
        hidden: hidden ?? this.hidden,
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'name': name,
        'label': label,
        'type': type,
        'value': value,
        'targets': [for (final target in targets) target.toJson()],
        if (group != null) 'group': group,
        if (options != null) 'options': options,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (step != null) 'step': step,
        if (multiline) 'multiline': multiline,
        if (media != null) 'media': media,
        if (hidden) 'hidden': hidden,
      };

  @override
  String toString() => 'ParameterDef($key, $type, value=$value)';
}
