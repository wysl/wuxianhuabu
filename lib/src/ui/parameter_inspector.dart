import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/comfy_workflow_service.dart';
import '../graph/parameter.dart';
import '../state/connection_providers.dart';
import '../state/workflow_params.dart';

/// The generated parameter form for the selected workflow.
///
/// Nothing here is hand-written per workflow: the fields come from
/// [PreparedWorkflow.parameters], which the expander derives from the graph.
/// That is what makes a workflow saved in ComfyUI usable without an import step
/// and without an API-format JSON.
class ParameterInspector extends ConsumerStatefulWidget {
  const ParameterInspector({super.key, required this.prepared});

  final PreparedWorkflow? prepared;

  @override
  ConsumerState<ParameterInspector> createState() => _ParameterInspectorState();
}

class _ParameterInspectorState extends ConsumerState<ParameterInspector> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prepared = widget.prepared;
    if (prepared == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '从左侧选择一个工作流，参数表单会按工作流结构自动生成。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final params = ref.watch(workflowParamsProvider(prepared));
    final controller = ref.read(workflowParamsProvider(prepared).notifier);
    final editable = params.parameters.where((p) => p.isEditable).toList();

    // Group into "the things people change" and "model/sampler plumbing", with
    // promoted subgraph inputs kept first because they were authored as the
    // public interface of the workflow.
    final promoted = editable.where((p) => !p.key.contains('.' )).toList();
    final rest = editable.where((p) => p.key.contains('.')).toList();
    final primary = rest.where(_isPrimary).toList();
    final secondary = rest.where((p) => !_isPrimary(p)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(prepared.name,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis),
                    Text(
                      '${prepared.nodeCount} 个执行节点 · ${editable.length} 个可调参数',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '重置为工作流中的值',
                onPressed: controller.reset,
                icon: const Icon(Icons.restart_alt, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        if (prepared.preflightProblems.isNotEmpty)
          _PreflightProblems(problems: prepared.preflightProblems),
        if (prepared.warnings.isNotEmpty)
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              '${prepared.warnings.length} 条展开提示',
              style: theme.textTheme.labelMedium,
            ),
            children: [
              for (final warning in prepared.warnings)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 16, 2),
                  child: Text(warning, style: theme.textTheme.labelSmall),
                ),
            ],
          ),
        const Divider(height: 1),
        Expanded(
          child: editable.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '这个工作流没有可调参数。\n'
                      '在 ComfyUI 里把想调的输入提升为子图输入，'
                      '或把值接到 Primitive 节点，即可在这里编辑。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    if (promoted.isNotEmpty) ...[
                      _sectionLabel(theme, '提升参数'),
                      for (final parameter in promoted)
                        _Field(
                          parameter: parameter,
                          value: params.valueOf(parameter),
                          onChanged: (value) =>
                              controller.set(parameter.key, value),
                        ),
                    ],
                    if (primary.isNotEmpty) ...[
                      if (promoted.isNotEmpty) const SizedBox(height: 12),
                      _sectionLabel(theme, '常用参数'),
                      for (final parameter in primary)
                        _Field(
                          parameter: parameter,
                          value: params.valueOf(parameter),
                          onChanged: (value) =>
                              controller.set(parameter.key, value),
                        ),
                    ],
                    if (secondary.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text('模型与采样',
                              style: theme.textTheme.labelMedium),
                          children: [
                            for (final parameter in secondary)
                              _Field(
                                parameter: parameter,
                                value: params.valueOf(parameter),
                                onChanged: (value) =>
                                    controller.set(parameter.key, value),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  static Widget _sectionLabel(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      );

  /// Heuristic for "show this at the top": text prompts and geometry, which are
  /// what people edit between runs.
  static bool _isPrimary(ParameterDef parameter) {
    const interesting = {
      'text',
      'prompt',
      'negative_prompt',
      'width',
      'height',
      'seed',
      'noise_seed',
      'steps',
      'cfg',
      'denoise',
      'length',
      'batch_size',
      'megapixels',
    };
    return interesting.contains(parameter.name) || parameter.isMedia;
  }
}

class _PreflightProblems extends StatelessWidget {
  const _PreflightProblems({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Text(
                '提交前检查发现 ${problems.length} 个问题',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '这些是服务器端状态（模型未安装、自定义节点缺失），客户端已如实读取，'
            '提交会被 ComfyUI 拒绝。',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 6),
          for (final problem in problems.take(6))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('· $problem', style: theme.textTheme.labelSmall),
            ),
          if (problems.length > 6)
            Text('…另有 ${problems.length - 6} 条',
                style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// Renders one parameter with an editor suited to its type.
class _Field extends ConsumerWidget {
  const _Field({
    required this.parameter,
    required this.value,
    required this.onChanged,
  });

  final ParameterDef parameter;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = parameter.label;
    final helper = parameter.key;

    if (parameter.isMedia) {
      return _MediaField(
        parameter: parameter,
        value: value,
        onChanged: onChanged,
      );
    }
    if (parameter.isBoolean) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label, style: Theme.of(context).textTheme.bodySmall),
          value: value == true,
          onChanged: onChanged,
        ),
      );
    }
    if (parameter.isCombo) {
      final options = parameter.options ?? const <String>[];
      final current = '$value';
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DropdownButtonFormField<String>(
          initialValue: options.contains(current) ? current : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 1,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          hint: Text(current, overflow: TextOverflow.ellipsis),
          items: [
            if (!options.contains(current) && current.isNotEmpty)
              DropdownMenuItem(
                value: current,
                child: Text('$current（不在服务器列表中）',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            for (final option in options)
              DropdownMenuItem(
                value: option,
                child: Text(option, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (selected) {
            if (selected != null) onChanged(selected);
          },
        ),
      );
    }
    if (parameter.isNumeric) {
      return _NumericField(
        parameter: parameter,
        value: value,
        onChanged: onChanged,
      );
    }
    // Strings, including long prompts.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _TextValueField(
        label: label,
        helper: helper,
        initial: '$value',
        multiline: parameter.multiline,
        onChanged: onChanged,
      ),
    );
  }
}

class _TextValueField extends StatefulWidget {
  const _TextValueField({
    required this.label,
    required this.helper,
    required this.initial,
    required this.multiline,
    required this.onChanged,
  });

  final String label;
  final String helper;
  final String initial;
  final bool multiline;
  final ValueChanged<Object?> onChanged;

  @override
  State<_TextValueField> createState() => _TextValueFieldState();
}

class _TextValueFieldState extends State<_TextValueField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(covariant _TextValueField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only adopt an outside change; adopting on every rebuild would fight the
    // user's cursor while typing (and break IME composition).
    if (widget.initial != oldWidget.initial &&
        widget.initial != _controller.text) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: _controller,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 8 : 1,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
          helperMaxLines: 1,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      );
}

class _NumericField extends StatefulWidget {
  const _NumericField({
    required this.parameter,
    required this.value,
    required this.onChanged,
  });

  final ParameterDef parameter;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  State<_NumericField> createState() => _NumericFieldState();
}

class _NumericFieldState extends State<_NumericField> {
  late final TextEditingController _controller =
      TextEditingController(text: '${widget.value ?? ''}');

  @override
  void didUpdateWidget(covariant _NumericField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = '${widget.value ?? ''}';
    if (incoming != '${oldWidget.value ?? ''}' && incoming != _controller.text) {
      _controller.text = incoming;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parameter = widget.parameter;
    final isInt = parameter.type == 'INT';
    final min = parameter.min;
    final max = parameter.max;
    final current = widget.value is num ? widget.value as num : null;

    // A slider is only honest when the range is known, finite-sized, and not
    // absurd. Seed ranges run to 2^64, which overflows double subtraction; a
    // slider there would be a lie, so those stay plain text fields.
    final span = (min != null && max != null && max > min)
        ? _spanWithinSliderLimit(min, max)
        : false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _controller,
            keyboardType:
                TextInputType.numberWithOptions(decimal: !isInt, signed: false),
            onChanged: (text) {
              // `num.tryParse` promotes a 16-digit integer to double and
              // silently loses precision, which is visible as
              // `655674275920...952000.0` in the seed field. Integers parse as
              // int; only explicitly floating-point input goes through double.
              final value = isInt && !text.contains('.')
                  ? int.tryParse(text)
                  : num.tryParse(text);
              if (value != null) widget.onChanged(value);
            },
            decoration: InputDecoration(
              labelText: parameter.label,
              helperText: parameter.key,
              helperMaxLines: 1,
              isDense: true,
              border: const OutlineInputBorder(),
              suffixText: min != null && max != null
                  ? '$min..$max'
                  : null,
            ),
          ),
          if (span && current != null)
            Slider(
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: (max - min) <= 100 ? (max - min).round() : null,
              value: current.toDouble().clamp(
                    min.toDouble(),
                    max.toDouble(),
                  ),
              onChanged: (value) {
                final next = isInt ? value.round() : value;
                _controller.text = '$next';
                widget.onChanged(next);
              },
            ),
        ],
      ),
    );
  }

  /// Whether a numeric range is small enough to be a usable slider.
  ///
  /// Compared as `int` where possible, because `max - min` on a 64-bit range
  /// overflows into a huge `double` and makes every huge range look small.
  static bool _spanWithinSliderLimit(num min, num max) {
    if (max > 1e9) return false;
    final span = max - min;
    if (!span.isFinite) return false;
    return span <= 100000;
  }
}

/// A media parameter: pick from the server's `input` directory or upload.
class _MediaField extends ConsumerWidget {
  const _MediaField({
    required this.parameter,
    required this.value,
    required this.onChanged,
  });

  final ParameterDef parameter;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: TextFormField(
              initialValue: '$value',
              onChanged: onChanged,
              decoration: InputDecoration(
                labelText: parameter.label,
                helperText: parameter.key,
                helperMaxLines: 1,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '上传文件',
            icon: const Icon(Icons.upload_file, size: 20),
            onPressed: () async {
              final service = ref.read(workflowServiceProvider);
              if (service == null) return;
              final picked = await FilePicker.pickFile(
                dialogTitle: '选择要上传的${parameter.media ?? '媒体'}文件',
              );
              final path = picked?.path;
              if (path == null) return;
              try {
                final name = await service.uploadFile(File(path));
                onChanged(name);
              } on Object catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('上传失败：$error')),
                  );
                }
              }
            },
          ),
          Icon(
            Icons.image_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
