import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/graph/node_definition.dart';

/// `InputSpec` has to read three different `/object_info` shapes, and getting
/// it wrong makes every dropdown a text box or reports false validation
/// failures, so each shape is pinned here.
void main() {
  group('InputSpec.parses server declarations', () {
    test('typed widget with bounds', () {
      final spec = InputSpec.fromJson([
        'INT',
        {'default': 0, 'min': 0, 'max': 100, 'step': 1},
      ]);
      expect(spec.type, 'INT');
      expect(spec.min, 0);
      expect(spec.max, 100);
      expect(spec.isWidget, isTrue);
      expect(spec.comboOptions, isNull);
    });

    test('combo as an inline list', () {
      final spec = InputSpec.fromJson([
        ['a.safetensors', 'b.safetensors'],
        {'default': 'a.safetensors'},
      ]);
      expect(spec.type, 'COMBO');
      expect(spec.comboOptions, ['a.safetensors', 'b.safetensors']);
    });

    test('dynamic combo lists objects keyed by value', () {
      // `COMFY_DYNAMICCOMBO_V3` expands into per-key inputs; the value that
      // belongs in the prompt is the object's `key`, not the object itself.
      final spec = InputSpec.fromJson([
        'COMFY_DYNAMICCOMBO_V3',
        {
          'options': [
            {
              'key': 'on',
              'inputs': {'required': <String, Object?>{}},
            },
            {
              'key': 'off',
              'inputs': {'required': <String, Object?>{}},
            },
          ],
        },
      ]);
      expect(spec.comboOptions, ['on', 'off']);
    });

    test('plain COMBO with options list', () {
      final spec = InputSpec.fromJson([
        'COMBO',
        {
          'options': ['x', 'y'],
        },
      ]);
      expect(spec.comboOptions, ['x', 'y']);
    });

    test('unknown connection type is not a widget', () {
      final spec = InputSpec.fromJson(['MODEL', {}]);
      expect(spec.isWidget, isFalse);
    });
  });

  group('validatePrompt', () {
    NodeDefinitionRegistry registry() => NodeDefinitionRegistry.fromJson({
          'UNETLoader': {
            'input': {
              'required': {
                'unet_name': [
                  ['good.safetensors'],
                  {'default': 'good.safetensors'},
                ],
              },
            },
            'output': ['MODEL'],
          },
        });

    test('accepts a value from the option list', () {
      final problems = registry().validatePrompt({
        '1': {
          'class_type': 'UNETLoader',
          'inputs': {'unet_name': 'good.safetensors'},
        },
      });
      expect(problems, isEmpty);
    });

    test('reports a stale value the server would reject', () {
      final problems = registry().validatePrompt({
        '1': {
          'class_type': 'UNETLoader',
          'inputs': {'unet_name': 'missing.safetensors'},
        },
      });
      expect(problems, hasLength(1));
      expect(problems.single, contains('missing.safetensors'));
      expect(problems.single, contains('不在服务器可选列表'));
    });

    test('reports a missing custom node', () {
      final problems = registry().validatePrompt({
        '1': {'class_type': 'SomeUninstalledNode', 'inputs': <String, Object?>{}},
      });
      expect(problems.single, contains('SomeUninstalledNode'));
      expect(problems.single, contains('不存在'));
    });

    test('ignores link values, which the server validates itself', () {
      final problems = registry().validatePrompt({
        '1': {
          'class_type': 'UNETLoader',
          'inputs': {
            'unet_name': ['2', 0],
          },
        },
      });
      expect(problems, isEmpty);
    });
  });
}
