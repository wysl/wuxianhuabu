import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/comfy_workflow_service.dart';
import '../graph/parameter.dart';

/// Editable values for one prepared workflow.
class WorkflowParams {
  const WorkflowParams({
    required this.parameters,
    required this.values,
    this.initial = const {},
  });

  final List<ParameterDef> parameters;

  /// Current editor values, keyed by [ParameterDef.key].
  final Map<String, Object?> values;

  /// Values when the workflow was opened, for [reset].
  final Map<String, Object?> initial;

  Object? valueOf(ParameterDef parameter) =>
      values.containsKey(parameter.key) ? values[parameter.key] : parameter.value;

  /// Values that differ from the workflow's own defaults.
  ///
  /// Submitting only the edits is not merely economical: a combo value carried
  /// over from a stale save is exactly what the server rejects with
  /// `Value not in list`, so untouched defaults stay out of the request.
  Map<String, Object?> get changed => {
        for (final entry in values.entries)
          if (initial[entry.key] != entry.value) entry.key: entry.value,
      };
}

/// One notifier per prepared workflow, so switching workflows keeps each one's
/// edits instead of resetting the form.
final workflowParamsProvider = NotifierProvider.family<WorkflowParamsNotifier,
    WorkflowParams, PreparedWorkflow>(WorkflowParamsNotifier.new);

class WorkflowParamsNotifier extends Notifier<WorkflowParams> {
  WorkflowParamsNotifier(this.workflow);

  /// The workflow these values belong to.
  final PreparedWorkflow workflow;

  @override
  WorkflowParams build() {
    final initial = <String, Object?>{
      for (final parameter in workflow.parameters)
        if (parameter.targets.isNotEmpty) parameter.key: parameter.value,
    };
    return WorkflowParams(
      parameters: workflow.parameters,
      values: Map<String, Object?>.from(initial),
      initial: initial,
    );
  }

  void set(String key, Object? value) {
    state = WorkflowParams(
      parameters: state.parameters,
      values: {...state.values, key: value},
      initial: state.initial,
    );
  }

  void reset() {
    state = WorkflowParams(
      parameters: state.parameters,
      values: Map<String, Object?>.from(state.initial),
      initial: state.initial,
    );
  }

  /// Overlays values from a finished run ("use these again").
  void adopt(Map<String, Object?> values) {
    state = WorkflowParams(
      parameters: state.parameters,
      values: {...state.values, ...values},
      initial: state.initial,
    );
  }
}
