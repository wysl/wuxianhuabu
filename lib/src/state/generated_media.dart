import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Results produced by runs, keyed by the workflow they came from.
///
/// Kept outside the canvas widget so a canvas can rebuild (zoom, workflow
/// switch) without losing the generated cards, and so the runner panel can
/// publish a result without knowing anything about the board.
class GeneratedMedia {
  const GeneratedMedia({
    required this.promptId,
    required this.workflowPath,
    required this.media,
    required this.createdAt,
  });

  final String promptId;
  final String workflowPath;

  /// `{filename, subfolder, type}` records from `history.outputs`.
  final List<Map<String, String>> media;
  final DateTime createdAt;
}

final generatedMediaProvider =
    NotifierProvider<GeneratedMediaNotifier, List<GeneratedMedia>>(
  GeneratedMediaNotifier.new,
);

class GeneratedMediaNotifier extends Notifier<List<GeneratedMedia>> {
  @override
  List<GeneratedMedia> build() => const [];

  /// Records a finished run. Newest first, and capped so a long session cannot
  /// grow the board without bound.
  void add(GeneratedMedia entry) {
    if (entry.media.isEmpty) return;
    final next = [entry, ...state];
    state = next.length > 60 ? next.sublist(0, 60) : next;
  }

  /// Media for one workflow, newest first.
  List<GeneratedMedia> forWorkflow(String path) =>
      state.where((entry) => entry.workflowPath == path).toList();

  void clear() => state = const [];
}
