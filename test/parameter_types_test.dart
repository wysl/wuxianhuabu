import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/comfy_graph.dart';

/// Numeric parameters must round-trip 64-bit seeds exactly.
///
/// A seed is an ordinary `INT` widget with a range up to 2^64, and it is the
/// one parameter nearly every workflow has. Treating it as a double silently
/// corrupts it, and the corruption is invisible until the server rejects the
/// value or the user notices a seed that no longer matches what they typed.
void main() {
  group('large integer parameters', () {
    test('an int value stays an int through parameter patching', () {
      final parameters = [
        ParameterDef(
          key: '984.seed',
          name: 'seed',
          label: 'seed',
          type: 'INT',
          value: 655674275926655,
          targets: const [
            ParameterTarget(execId: '984', inputName: 'seed'),
          ],
        ),
      ];
      final prompt = {
        '984': ApiNode(
          classType: 'KSampler',
          inputs: {'seed': 655674275926655},
        ),
      };

      // Submitting the value the user sees must not change it.
      final patched = const PromptPatcher().apply(
        prompt,
        parameters,
        {'984.seed': 655674275926655},
      );
      final written = patched.prompt['984']!.inputs['seed'];
      expect(written, isA<int>());
      expect(written, 655674275926655);
      // The failure mode being guarded against: a double that prints as
      // 6.55674275926655e+14 and loses the trailing digits.
      expect('$written', '655674275926655');
    });

    test('a value near 2^53 is not silently rounded', () {
      // 2^53 + 1 is the first integer a double cannot represent.
      const precise = 9007199254740993;
      final parameters = [
        ParameterDef(
          key: 'k.seed',
          name: 'seed',
          label: 'seed',
          type: 'INT',
          value: precise,
          targets: const [ParameterTarget(execId: 'k', inputName: 'seed')],
        ),
      ];
      final patched = const PromptPatcher().apply(
        {'k': ApiNode(classType: 'KSampler', inputs: {'seed': precise})},
        parameters,
        {'k.seed': precise},
      );
      expect(patched.prompt['k']!.inputs['seed'], precise);
    });

    test('a numeric string is coerced to int for INT parameters', () {
      final parameters = [
        ParameterDef(
          key: 'k.seed',
          name: 'seed',
          label: 'seed',
          type: 'INT',
          value: 0,
          targets: const [ParameterTarget(execId: 'k', inputName: 'seed')],
        ),
      ];
      final patched = const PromptPatcher().apply(
        {'k': ApiNode(classType: 'KSampler', inputs: {'seed': 0})},
        parameters,
        {'k.seed': '123456789012345'},
      );
      final written = patched.prompt['k']!.inputs['seed'];
      expect(written, isA<int>());
      expect(written, 123456789012345);
    });

    test('FLOAT parameters keep fractional values', () {
      final parameters = [
        ParameterDef(
          key: 'k.cfg',
          name: 'cfg',
          label: 'cfg',
          type: 'FLOAT',
          value: 1.0,
          targets: const [ParameterTarget(execId: 'k', inputName: 'cfg')],
        ),
      ];
      final patched = const PromptPatcher().apply(
        {'k': ApiNode(classType: 'KSampler', inputs: {'cfg': 1.0})},
        parameters,
        {'k.cfg': 7.5},
      );
      expect(patched.prompt['k']!.inputs['cfg'], 7.5);
    });
  });

  group('seed control value handling', () {
    test('the control_after_generate value is not read as the next widget', () {
      // The serialized array is `[seed, "randomize", steps, cfg, ...]`; reading
      // it positionally would assign "randomize" to `steps`.
      final node = UiNode.fromJson({
        'id': 1,
        'type': 'KSampler',
        'inputs': [
          {'name': 'seed', 'type': 'INT', 'widget': {'name': 'seed'}},
          {'name': 'steps', 'type': 'INT', 'widget': {'name': 'steps'}},
          {'name': 'cfg', 'type': 'FLOAT', 'widget': {'name': 'cfg'}},
        ],
        'widgets_values': [123456789, 'randomize', 20, 8.0],
      });
      final values = node.widgetValuesByName();
      expect(values['seed'], 123456789);
      expect(values['steps'], 20);
      expect(values['cfg'], 8.0);
    });

    test('named values win when the frontend wrote them', () {
      final node = UiNode.fromJson({
        'id': 1,
        'type': 'KSampler',
        'inputs': [
          {'name': 'seed', 'type': 'INT', 'widget': {'name': 'seed'}},
          {'name': 'steps', 'type': 'INT', 'widget': {'name': 'steps'}},
        ],
        'widgets_values': [1, 'fixed', 2],
        'widgets_values_named': {'seed': 999, 'steps': 42},
      });
      final values = node.widgetValuesByName();
      expect(values['seed'], 999);
      expect(values['steps'], 42);
    });
  });
}
