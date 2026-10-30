import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/comfy_graph.dart';

/// Ground-truth oracle: workflows ComfyUI actually executed.
///
/// `tools/export_history_pairs.py` pulls, out of `/history`, the UI workflow a
/// user saved *and* the API prompt ComfyUI ran from it. Replaying those pairs
/// through the expander is the only objective check that the expansion rules
/// are right rather than merely non-crashing.
///
/// Comparisons are deliberately structural rather than byte-exact:
///
///  * link values must match as `[execId, slot]`
///  * widget values must match when both sides have them
///  * node sets must be equal once non-executing nodes are accounted for
File pairFile() => File('tools/fixtures/history/pairs.json');

List<Map<String, Object?>> pairs() {
  final file = pairFile();
  if (!file.existsSync()) return const [];
  final raw = jsonDecode(file.readAsStringSync()) as List;
  return [for (final entry in raw) entry as Map<String, Object?>];
}

void main() {
  final corpus = pairs();

  test('history corpus is present', () {
    expect(
      corpus,
      isNotEmpty,
      reason: 'run tools/export_history_pairs.py to populate the oracle',
    );
  });

  for (final pair in corpus) {
    final id = '${pair['id']}'.substring(0, 8);
    final workflowRaw = pair['workflow'] as Map<String, Object?>;
    final executed = pair['executed'] as Map<String, Object?>;

    test('$id reproduces the executed prompt', () {
      final workflow = UiWorkflow.fromJson(workflowRaw);
      final expanded = WorkflowExpander(workflow).expand();
      final own = expanded.toPromptJson();

      // 1. The node sets must agree. ComfyUI drops muted/bypassed and virtual
      //    nodes; so do we, so anything left over is a real disagreement.
      final expectedIds = executed.keys.toSet();
      final actualIds = own.keys.toSet();
      expect(
        actualIds.difference(expectedIds),
        isEmpty,
        reason: 'expanded extra nodes the server never ran: '
            '${actualIds.difference(expectedIds)}',
      );
      expect(
        expectedIds.difference(actualIds),
        isEmpty,
        reason: 'expansion dropped nodes the server ran: '
            '${expectedIds.difference(actualIds)}',
      );

      // 2. Every node's class must match.
      for (final execId in expectedIds) {
        final expected = executed[execId] as Map<String, Object?>;
        final actual = own[execId] as Map<String, Object?>;
        expect(
          actual['class_type'],
          expected['class_type'],
          reason: 'node $execId class mismatch',
        );
      }

      // 3. Every link both sides know about must resolve identically, and we
      //    must not invent links the server did not have.
      final mismatches = <String>[];
      for (final execId in expectedIds) {
        final expectedInputs =
            (executed[execId] as Map<String, Object?>)['inputs'] as Map<String, Object?>? ??
                const {};
        final actualInputs =
            (own[execId] as Map<String, Object?>)['inputs'] as Map<String, Object?>? ??
                const {};

        for (final entry in expectedInputs.entries) {
          final expectedValue = entry.value;
          final actualValue = actualInputs[entry.key];
          if (expectedValue is List && expectedValue.length == 2) {
            // ComfyUI writes `["", ""]` for an optional input that had a link
            // which was resolved away (a converted widget, a cleared virtual
            // link). It is a "no link" sentinel, not a reference to node "".
            if ('${expectedValue[0]}' == '' && '${expectedValue[1]}' == '') {
              continue;
            }
            if (actualValue is! List || actualValue.length != 2) {
              mismatches.add('$execId.${entry.key}: expected link '
                  '${expectedValue.join(':')}, got $actualValue');
              continue;
            }
            if ('${actualValue[0]}' != '${expectedValue[0]}' ||
                '${actualValue[1]}' != '${expectedValue[1]}') {
              mismatches.add('$execId.${entry.key}: expected link '
                  '${expectedValue.join(':')}, got ${actualValue.join(':')}');
            }
          }
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });
  }
}
