import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/comfy_graph.dart';
import 'package:wuxianhuabu/src/core/comfy_workflow_service.dart';
import 'package:wuxianhuabu/src/ui/parameter_inspector.dart';

/// The parameter form must show each parameter's *own* value.
///
/// This is a regression test for a widget-identity bug: the form is a list of
/// same-typed editors, and without stable keys Flutter reused state by
/// position. Every field then *displayed* its neighbour's value — a 64-bit seed
/// rendered as `18446744073709552000.0` and a megapixels slider was labelled
/// `1.4096`. It looked exactly like a number-parsing bug, which is why only a
/// widget test catches it.
PreparedWorkflow buildPrepared() {
  final raw = jsonDecode(
    File('tools/fixtures/MOSS.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final expanded = WorkflowExpander(UiWorkflow.fromJson(raw)).expand();
  return PreparedWorkflow(
    sourcePath: 'tools/fixtures/MOSS.json',
    name: 'MOSS',
    workflow: UiWorkflow.fromJson(raw),
    expanded: expanded,
    parameters: expanded.parameters,
    preflightProblems: const [],
  );
}

/// Every built editor carries a key derived from its parameter.
Finder findEditor(String key) => find.byWidgetPredicate((widget) {
      final widgetKey = widget.key;
      return widgetKey is ValueKey<String> && widgetKey.value == key;
    });

/// The text controller of the editor keyed [key], resolved by descending from
/// the keyed wrapper to the actual form field.
String editorText(WidgetTester tester, String key) {
  final field = find.descendant(
    of: findEditor(key),
    matching: find.byType(TextFormField),
  );
  expect(field, findsOneWidget, reason: 'no TextFormField under $key');
  return tester.widget<TextFormField>(field).controller!.text;
}

void main() {
  setUp(() {
    // A tall surface so the whole form lays out at once.
    final view =
        TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.implicitView!;
    view.physicalSize = const Size(1200, 6000);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.implicitView!;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> pump(WidgetTester tester, PreparedWorkflow prepared) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: ParameterInspector(prepared: prepared)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Reveal the collapsed "model and sampling" section, where most numeric
    // parameters live.
    final expander = find.text('模型与采样');
    if (expander.evaluate().isNotEmpty) {
      await tester.tap(expander);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('every built editor is keyed by its parameter', (tester) async {
    final prepared = buildPrepared();
    await pump(tester, prepared);

    final editable = prepared.parameters
        .where((p) => p.isEditable && p.targets.isNotEmpty)
        .toList();
    expect(editable, isNotEmpty);

    // Each visible editor must resolve to exactly one parameter. Duplicate keys
    // would mean two fields share state, which is the bug being guarded.
    final keys = <String>{};
    for (final parameter in editable) {
      final prefix = parameter.isMedia
          ? 'media-'
          : parameter.isNumeric
              ? 'num-'
              : parameter.isCombo || parameter.isBoolean
                  ? null
                  : 'text-';
      if (prefix == null) continue;
      keys.add('$prefix${parameter.key}');
    }
    for (final key in keys) {
      expect(
        findEditor(key).evaluate().length,
        lessThanOrEqualTo(1),
        reason: 'key $key is not unique',
      );
    }
    expect(keys, isNotEmpty);
  });

  testWidgets('each numeric field shows its own value', (tester) async {
    final prepared = buildPrepared();
    await pump(tester, prepared);

    final numerics = prepared.parameters
        .where((p) => p.isNumeric && p.value is num && p.targets.isNotEmpty)
        .toList();
    expect(
      numerics.length,
      greaterThanOrEqualTo(3),
      reason: 'need several numeric parameters to exercise reuse',
    );

    var checked = 0;
    for (final parameter in numerics) {
      if (findEditor('num-${parameter.key}').evaluate().isEmpty) {
        continue; // not laid out at this surface size
      }
      final text = editorText(tester, 'num-${parameter.key}');
      expect(
        text,
        '${parameter.value}',
        reason: '${parameter.key} displays $text, '
            'expected ${parameter.value}',
      );
      checked += 1;
    }
    expect(checked, greaterThanOrEqualTo(2));
  });

  testWidgets('a 64-bit seed is not rendered in exponent form', (tester) async {
    final prepared = buildPrepared();
    final seed = prepared.parameters.firstWhere(
      (p) => p.name == 'seed' && p.value is int,
      orElse: () => throw StateError('fixture has no integer seed'),
    );
    // ignore: avoid_print
    print('seed parameter: ${seed.key} = ${seed.value}');

    await pump(tester, prepared);

    expect(findEditor('num-${seed.key}'), findsOneWidget);
    final text = editorText(tester, 'num-${seed.key}');
    expect(text, '${seed.value}');
    expect(text, isNot(contains('e+')));
    expect(text, isNot(contains('.0')));
  });
}
