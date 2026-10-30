import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/upgrade_field.dart';

import 'package:upgrade_widgetbook/components/knobs.dart';
import 'package:upgrade_widgetbook/frame.dart';

enum _Transport { ssh, mosh }

final inputComponents = [
  WidgetbookComponent(
    name: 'UpgradeField',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final hint = context.label('search hosts', label: 'Hint');
          final enabled = context.knobs.boolean(
            label: 'Enabled',
            initialValue: true,
          );
          final obscure = context.knobs.boolean(label: 'Obscure');
          final lines = context.knobs.int.slider(
            label: 'Max lines',
            initialValue: 1,
            min: 1,
            max: UpgradeField.bodyLines,
          );
          return Stage(
            children: [
              _Controlled(
                builder: (controller) => UpgradeField(
                  controller: controller,
                  hint: hint,
                  enabled: enabled,
                  obscureText: obscure,
                  maxLines: obscure ? 1 : lines,
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'FieldPanel',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final label = context.label('Address', label: 'Label');
          final hint = context.label('100.118.60.77', label: 'Hint');
          final enabled = context.knobs.boolean(
            label: 'Enabled',
            initialValue: true,
          );
          final obscure = context.knobs.boolean(label: 'Obscure');
          final maxLength = context.knobs.int.slider(
            label: 'Max length (0 = none)',
            initialValue: 0,
            max: 64,
          );
          return Stage(
            children: [
              _Controlled(
                builder: (controller) => FieldPanel(
                  label: label,
                  controller: controller,
                  hint: hint,
                  enabled: enabled,
                  obscureText: obscure,
                  maxLength: maxLength == 0 ? null : maxLength,
                ),
              ),
            ],
          );
        },
      ),
      WidgetbookUseCase(
        name: 'States',
        builder: (context) => Stage(
          children: [
            _Controlled(
              builder: (controller) => FieldPanel(
                label: 'Empty',
                controller: controller,
                hint: 'dev',
              ),
            ),
            _Controlled(
              initial: 'dev',
              builder: (controller) =>
                  FieldPanel(label: 'Filled', controller: controller),
            ),
            _Controlled(
              initial: 'dev',
              builder: (controller) => FieldPanel(
                label: 'Disabled',
                controller: controller,
                enabled: false,
              ),
            ),
            _Controlled(
              initial: 'hunter2',
              builder: (controller) => FieldPanel(
                label: 'Obscured',
                controller: controller,
                obscureText: true,
              ),
            ),
            _Controlled(
              initial: 'cat ~/.ssh/config\nls -la',
              builder: (controller) => FieldPanel(
                label: 'Multi-line',
                controller: controller,
                maxLines: 4,
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'ChoicePanel',
    useCases: [
      WidgetbookUseCase(
        name: 'Interactive',
        builder: (context) =>
            Stage(children: [_Choice(label: context.label('Transport'))]),
      ),
    ],
  ),
];

class _Controlled extends StatefulWidget {
  const _Controlled({required this.builder, this.initial = ''});

  final Widget Function(TextEditingController controller) builder;
  final String initial;

  @override
  State<_Controlled> createState() => _ControlledState();
}

class _ControlledState extends State<_Controlled> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}

class _Choice extends StatefulWidget {
  const _Choice({required this.label});

  final String label;

  @override
  State<_Choice> createState() => _ChoiceState();
}

class _ChoiceState extends State<_Choice> {
  _Transport _value = _Transport.ssh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoicePanel<_Transport>(
          label: widget.label,
          options: _Transport.values,
          value: _value,
          labelOf: (transport) => transport.name.toUpperCase(),
          onChanged: (value) => setState(() => _value = value),
        ),
        Meta('selected: ${_value.name}'),
      ],
    );
  }
}
