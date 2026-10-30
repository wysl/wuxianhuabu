/// Raised when a UI workflow cannot be expanded into an API prompt.
///
/// Expansion fails loudly rather than silently dropping nodes: a prompt that
/// is missing a producer produces a confusing `node_errors` response from
/// ComfyUI, and a prompt that is missing a *consumer* silently generates the
/// wrong picture. Both are worse than an explicit error.
class GraphExpansionError implements Exception {
  GraphExpansionError(this.message, {this.details});

  final String message;

  /// Optional machine-readable context, e.g. the offending node ids.
  final Map<String, Object?>? details;

  @override
  String toString() {
    if (details == null || details!.isEmpty) return 'GraphExpansionError: $message';
    return 'GraphExpansionError: $message ($details)';
  }
}
