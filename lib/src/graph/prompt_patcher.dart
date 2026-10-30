import 'api_prompt.dart';
import 'parameter.dart';

/// Writes submitted parameter values back into an expanded prompt.
///
/// Two rules, both learned from the failure modes:
///
/// * A value goes to **every** target of its parameter. A promoted subgraph
///   input can feed several inner nodes, and writing only the first one leaves
///   the others on their old defaults.
/// * An unknown or unresolvable key becomes a **warning**, not an exception. A
///   stale form field must never be able to block the whole submission.
class PromptPatcher {
  const PromptPatcher();

  PatchResult apply(
    Map<String, ApiNode> prompt,
    List<ParameterDef> parameters,
    Map<String, Object?> values,
  ) {
    final patched = <String, ApiNode>{
      for (final entry in prompt.entries)
        entry.key: ApiNode(
          classType: entry.value.classType,
          inputs: Map<String, Object?>.from(entry.value.inputs),
          title: entry.value.title,
        ),
    };
    final byKey = {for (final parameter in parameters) parameter.key: parameter};
    final warnings = <String>[];

    for (final entry in values.entries) {
      final parameter = byKey[entry.key];
      if (parameter == null) {
        warnings.add('未知参数: ${entry.key}');
        continue;
      }
      if (parameter.targets.isEmpty) {
        warnings.add('参数 ${parameter.label} 没有可写入的目标');
        continue;
      }
      final converted = _coerce(parameter, entry.value, warnings);
      if (converted == _unsupported) continue;

      for (final target in parameter.targets) {
        final node = patched[target.execId];
        if (node == null) {
          warnings.add('节点 ${target.execId} 不在模板中，已跳过 ${parameter.key}');
          continue;
        }
        node.inputs[target.inputName] = converted;
      }
    }

    return PatchResult(prompt: patched, warnings: warnings);
  }

  /// Normalises a submitted value to what the node input expects.
  Object? _coerce(
    ParameterDef parameter,
    Object? value,
    List<String> warnings,
  ) {
    if (value == null) return null;
    switch (parameter.type) {
      case 'INT':
        if (value is int) return value;
        if (value is num) return value.round();
        final parsed = num.tryParse('$value');
        if (parsed == null) {
          warnings.add('参数 ${parameter.label} 需要整数，收到 $value');
          return _unsupported;
        }
        return parsed.round();
      case 'FLOAT':
        if (value is num) return value.toDouble();
        final parsed = num.tryParse('$value');
        if (parsed == null) {
          warnings.add('参数 ${parameter.label} 需要数字，收到 $value');
          return _unsupported;
        }
        return parsed.toDouble();
      case 'BOOLEAN':
        if (value is bool) return value;
        final text = '$value'.toLowerCase();
        if (text == 'true' || text == '1') return true;
        if (text == 'false' || text == '0') return false;
        warnings.add('参数 ${parameter.label} 需要布尔值，收到 $value');
        return _unsupported;
      default:
        // STRING, COMBO and media names all travel as strings.
        return '$value';
    }
  }
}

const Object _unsupported = Object();

/// Result of [PromptPatcher.apply].
class PatchResult {
  const PatchResult({required this.prompt, required this.warnings});

  final Map<String, ApiNode> prompt;
  final List<String> warnings;

  Map<String, Object?> toPromptJson() => {
        for (final entry in prompt.entries) entry.key: entry.value.toJson(),
      };
}
