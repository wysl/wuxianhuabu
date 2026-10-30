import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/comfy_graph.dart';
import 'package:wuxianhuabu/src/graph/prompt_patcher.dart';

/// Real workflows captured from a live ComfyUI 0.42.1 instance.
///
/// These are the acceptance corpus: every file here must expand without
/// throwing, must never emit a virtual node, and must produce at least one
/// editable parameter. Synthetic fixtures prove individual rules; these prove
/// the rules survive contact with 4000+ custom node types.
final Directory fixtureDir = Directory('tools/fixtures');

List<File> fixtures() {
  if (!fixtureDir.existsSync()) return const [];
  return fixtureDir
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Map<String, Object?> load(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

void main() {
  group('real workflow corpus', () {
    test('fixtures are present', () {
      expect(
        fixtures(),
        isNotEmpty,
        reason: 'run tools/fetch_workflows.py to populate tools/fixtures',
      );
    });

    for (final file in fixtures()) {
      final name = file.uri.pathSegments.last;

      test('$name expands to a valid prompt', () {
        final workflow = UiWorkflow.fromJson(load(file));
        final expanded = WorkflowExpander(workflow).expand();

        expect(
          expanded.prompt,
          isNotEmpty,
          reason: '$name produced no nodes at all',
        );

        // 1. No virtual node may survive: the server rejects unknown
        //    class_types outright with `missing_node_type`.
        for (final entry in expanded.prompt.entries) {
          expect(
            virtualNodeTypes.contains(entry.value.classType),
            isFalse,
            reason: '${entry.key} leaked virtual node ${entry.value.classType}',
          );
        }

        // 2. No subgraph instance may survive either: it is not a real class.
        for (final entry in expanded.prompt.entries) {
          expect(
            workflow.subgraphs.containsKey(entry.value.classType),
            isFalse,
            reason: '${entry.key} leaked subgraph instance ${entry.value.classType}',
          );
        }

        // 3. Every link must point at a node that exists in the prompt.
        for (final entry in expanded.prompt.entries) {
          for (final input in entry.value.inputs.entries) {
            final value = input.value;
            if (value is! List || value.length != 2) continue;
            final target = '${value[0]}';
            expect(
              expanded.prompt.containsKey(target),
              isTrue,
              reason:
                  '${entry.key}.${input.key} points at missing node $target',
            );
          }
        }

        // 4. Parameters must be writable and typed.
        expect(
          expanded.parameters.where((p) => p.targets.isNotEmpty),
          isNotEmpty,
          reason: '$name exposed no writable parameter',
        );
        for (final parameter in expanded.parameters) {
          for (final target in parameter.targets) {
            final node = expanded.prompt[target.execId];
            expect(
              node,
              isNotNull,
              reason: '${parameter.key} targets missing node ${target.execId}',
            );
            expect(
              node!.inputs.containsKey(target.inputName),
              isTrue,
              reason:
                  '${parameter.key} targets ${target.inputName}, absent on '
                  '${target.execId}',
            );
          }
        }
      });
    }
  });

  group('prompt patching on real workflows', () {
    test('submitting every parameter leaves the prompt valid', () {
      for (final file in fixtures()) {
        final workflow = UiWorkflow.fromJson(load(file));
        final expanded = WorkflowExpander(workflow).expand();

        final values = <String, Object?>{};
        for (final parameter in expanded.parameters) {
          if (!parameter.isEditable || parameter.targets.isEmpty) continue;
          values[parameter.key] = switch (parameter.type) {
            'INT' => 7,
            'FLOAT' => 0.5,
            'BOOLEAN' => true,
            _ => 'probe',
          };
        }
        if (values.isEmpty) continue;

        final patched = const PromptPatcher()
            .apply(expanded.prompt, expanded.parameters, values);

        // Unknown-key warnings are allowed; target-missing warnings are not,
        // because every target was just proven to exist.
        for (final warning in patched.warnings) {
          expect(
            warning.contains('不在模板中'),
            isFalse,
            reason: '${file.path}: $warning',
          );
        }

        // Every patched value landed on every target.
        for (final entry in values.entries) {
          final parameter =
              expanded.parameters.firstWhere((p) => p.key == entry.key);
          for (final target in parameter.targets) {
            expect(
              patched.prompt[target.execId]!.inputs[target.inputName],
              entry.value,
              reason: '${file.path}: ${entry.key} did not reach $target',
            );
          }
        }
      }
    });

    test('unknown key warns instead of throwing', () {
      final workflow = UiWorkflow.fromJson(load(fixtures().first));
      final expanded = WorkflowExpander(workflow).expand();
      final patched = const PromptPatcher()
          .apply(expanded.prompt, expanded.parameters, {'nope:not_real': 1});
      expect(patched.warnings, isNotEmpty);
      expect(patched.prompt.length, expanded.prompt.length);
    });
  });
}
