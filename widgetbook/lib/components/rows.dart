import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/data/enums.dart';
import 'package:upgrade/design/components/bracket_label.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/item_line.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/meta_row.dart';
import 'package:upgrade/design/components/path_line.dart';
import 'package:upgrade/design/components/picker_row.dart';
import 'package:upgrade/design/components/priority_row.dart';
import 'package:upgrade/design/components/status_tag.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

import 'package:upgrade_widgetbook/components/knobs.dart';
import 'package:upgrade_widgetbook/frame.dart';

final rowComponents = [
  WidgetbookComponent(
    name: 'ListRow',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final tokens = context.tokens;
          final glyph = context.knobs.boolean(
            label: 'Leading glyph',
            initialValue: true,
          );
          final progress = context.knobs.boolean(label: 'Progress');
          return Stage(
            children: [
              ListRowGroup(
                children: [
                  ListRow(
                    title: context.label('oak', label: 'Title'),
                    kicker: _optional(context.label('', label: 'Kicker')),
                    subtitle: _optional(
                      context.label(
                        'dev@198.51.100.77:2222',
                        label: 'Subtitle',
                      ),
                    ),
                    caption: _optional(context.label('', label: 'Caption')),
                    value: _optional(context.label('3 AGENTS', label: 'Value')),
                    valueColor: context.tone(label: 'Value tone'),
                    valueStrong: context.knobs.boolean(label: 'Value strong'),
                    titleColor: context.tone(label: 'Title tone'),
                    lead: context.knobs.boolean(label: 'Lead'),
                    node: context.knobs.boolean(label: 'Node'),
                    decode: context.knobs.boolean(label: 'Decode'),
                    metadataBelow: context.knobs.boolean(
                      label: 'Metadata below',
                    ),
                    progress: progress
                        ? context.knobs.double.slider(
                            label: 'Progress value',
                            initialValue: 0.4,
                            max: 1,
                          )
                        : null,
                    leading: glyph
                        ? UpgradeIcon(
                            UpgradeIcons.hosts,
                            size: IconSizes.glyph,
                            color: tokens.textSecondary,
                          )
                        : null,
                    onTap: context.tap(),
                  ),
                ],
              ),
            ],
          );
        },
      ),
      WidgetbookUseCase(
        name: 'States',
        builder: (context) {
          final tokens = context.tokens;
          Widget glyph(UpgradeIcons icon, [Color? color]) => UpgradeIcon(
            icon,
            size: IconSizes.glyph,
            color: color ?? tokens.textSecondary,
          );
          return Stage(
            children: [
              Specimen(
                'Normal · selected · disabled · loading · error',
                note:
                    'Each row is styled the way a feature screen styles it: the '
                    'row has no state flags of its own.',
                child: ListRowGroup(
                  children: [
                    ListRow(
                      title: 'oak',
                      subtitle: 'dev@198.51.100.77:2222',
                      value: 'IDLE',
                      leading: glyph(UpgradeIcons.hosts),
                      onTap: _noop,
                    ),
                    ListRow(
                      title: 'pine',
                      subtitle: 'dev@198.51.100.21:22',
                      value: 'OPEN',
                      valueColor: tokens.accent,
                      valueStrong: true,
                      titleColor: tokens.accent,
                      lead: true,
                      leading: glyph(UpgradeIcons.hosts, tokens.accent),
                      onTap: _noop,
                    ),
                    ListRow(
                      title: 'juniper',
                      subtitle: 'no key on this phone',
                      titleColor: tokens.textDisabled,
                      subtitleColor: tokens.textDisabled,
                      leading: glyph(UpgradeIcons.hosts, tokens.textDisabled),
                    ),
                    ListRow(
                      title: 'fixture',
                      subtitle: 'connecting',
                      leading: glyph(UpgradeIcons.hosts),
                      trailing: const DotSpinner(),
                      onTap: _noop,
                    ),
                    ListRow(
                      title: 'gateway',
                      subtitle: 'host key changed',
                      subtitleColor: tokens.danger,
                      value: 'REFUSED',
                      valueColor: tokens.danger,
                      leading: glyph(UpgradeIcons.hosts, tokens.danger),
                      onTap: _noop,
                    ),
                  ],
                ),
              ),
              Specimen(
                'Progress',
                child: ListRowGroup(
                  children: [
                    ListRow(
                      title: 'release.apk',
                      value: '41%',
                      progress: 0.41,
                      onTap: _noop,
                    ),
                  ],
                ),
              ),
              Specimen(
                'Priority marks',
                child: ListRowGroup(
                  children: [
                    for (final priority in Priority.values)
                      ListRow(
                        title: 'ship ${priority.name} task',
                        mark: PriorityMark(
                          priority: priority,
                          seed: priority.index,
                        ),
                        onTap: _noop,
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'PickerRow',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            PickerRow(
              label: context.label('test-key'),
              value: _optional(context.label('ED25519', label: 'Value')),
              subtitle: _optional(context.label('', label: 'Subtitle')),
              selected: context.knobs.boolean(label: 'Selected'),
              dim: context.knobs.boolean(label: 'Dim'),
              indent: context.knobs.boolean(label: 'Indent'),
              onTap: _noop,
            ),
          ],
        ),
      ),
      WidgetbookUseCase(
        name: 'Interactive list',
        builder: (context) => const Stage(children: [_Picker()]),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'PriorityMark',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) => Stage(
          children: [
            Row(
              children: [
                PriorityMark(
                  priority: context.knobs.object.segmented(
                    label: 'Priority',
                    options: Priority.values,
                    initialOption: Priority.high,
                    labelBuilder: (priority) => priority.name,
                  ),
                  seed: 0,
                  dim: context.knobs.boolean(label: 'Dim'),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Labels',
    useCases: [
      WidgetbookUseCase(
        name: 'Meta, MetaRow, BracketLabel, StatusTag',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              Specimen(
                'Meta',
                child: Meta(
                  context.label('captured 2m ago', label: 'Meta text'),
                  strong: context.knobs.boolean(label: 'Strong'),
                  color: context.tone(),
                ),
              ),
              const Specimen(
                'MetaRow',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MetaRow('ADDRESS', '198.51.100.77:2222'),
                    MetaRow('USER', 'dev'),
                    MetaRow('KEY', 'test-key'),
                  ],
                ),
              ),
              Specimen(
                'BracketLabel',
                child: BracketLabel('KEY', value: 'SHA256:hDVbIZXc…'),
              ),
              Specimen(
                'StatusTag',
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    StatusTag('OPEN', color: tokens.accent),
                    StatusTag('WAIT', color: tokens.warning),
                    StatusTag('FAIL', color: tokens.danger),
                    StatusTag('IDLE', color: tokens.textMuted),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      WidgetbookUseCase(
        name: 'ItemLine and PathLine',
        builder: (context) {
          final tokens = context.tokens;
          return Stage(
            children: [
              Specimen(
                'PathLine',
                note:
                    'Drop the viewport width: the directories collapse '
                    'before the name does.',
                child: PathLine(
                  context.label(
                    '/home/dev/Projects/fixture/lib/features/hosts/host_row.dart',
                    label: 'Path',
                  ),
                  style: tokens.value,
                ),
              ),
              Specimen(
                'ItemLine',
                child: ItemLine(
                  context.label('fixture: 3 files changed', label: 'Line'),
                  style: tokens.rowTitle,
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
];

void _noop() {}

String? _optional(String value) => value.isEmpty ? null : value;

class _Picker extends StatefulWidget {
  const _Picker();

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  static const _keys = ['test-key', 'juniper', 'pine-ed25519', 'legacy-rsa'];
  String _selected = _keys.first;

  @override
  Widget build(BuildContext context) {
    return Specimen(
      'Tap a row',
      note: 'The selected row is drawn by PickerRow itself; the last is dim.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final key in _keys)
            PickerRow(
              label: key,
              value: key == 'legacy-rsa' ? 'RSA' : 'ED25519',
              selected: key == _selected,
              dim: key == 'legacy-rsa',
              onTap: () => setState(() => _selected = key),
            ),
        ],
      ),
    );
  }
}
