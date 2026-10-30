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
class ParameterExtractorOptions {
  const ParameterExtractorOptions({
    this.includeTechnical = false,
    this.promptishOnly = false,
    this.multilineStringThreshold = 60,
  });

  /// Include model/sampler/filename widgets as well.
  final bool includeTechnical;

  /// Only expose text-like and numeric fields, hiding every model selector.
  final bool promptishOnly;

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

  static String? _slotTypeOf(UiNode? node, String inputName) {
    if (node == null) return null;
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
