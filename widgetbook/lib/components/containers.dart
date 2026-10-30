import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

import 'package:upgrade_widgetbook/components/knobs.dart';
import 'package:upgrade_widgetbook/frame.dart';

enum _Async { loading, error, empty, data }

final containerComponents = [
  WidgetbookComponent(
    name: 'Panel',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final affordance = context.knobs.boolean(
            label: 'Affordance',
            initialValue: true,
          );
          return Stage(
            children: [
              Panel(
                title: context.label('Hosts', label: 'Title'),
                affordance: affordance
                    ? PanelAffordance(
                        context.label('All', label: 'Affordance label'),
                        color: context.tone(label: 'Affordance tone'),
                        showIcon: context.knobs.boolean(
                          label: 'Affordance icon',
                          initialValue: true,
                        ),
                        onTap: _noop,
                      )
                    : null,
                onHeaderTap: context.tap(label: 'Header tap'),
                child: const ListRowGroup(
                  children: [
                    ListRow(title: 'nyx', value: 'IDLE', onTap: _noop),
                    ListRow(title: 'rose', value: 'OPEN', onTap: _noop),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      WidgetbookUseCase(
        name: 'Variants',
        builder: (context) => const Stage(
          children: [
            Specimen(
              'Untitled',
              child: Panel(child: Meta('A panel without a header.')),
            ),
            Specimen(
              'Affordance, pressed by hand',
              note: 'PanelAffordance keeps its own pressed state: hold it.',
              child: Panel(
                title: 'Agents',
                affordance: PanelAffordance(
                  'Add',
                  icon: UpgradeIcons.add,
                  onTap: _noop,
                ),
                child: Meta('nothing running'),
              ),
            ),
            Specimen(
              'Inert affordance',
              child: Panel(
                title: 'Agents',
                affordance: PanelAffordance('Add', icon: UpgradeIcons.add),
                child: Meta('nothing running'),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'SegmentSwitch',
    useCases: [
      WidgetbookUseCase(
        name: 'Interactive',
        builder: (context) => Stage(
          children: [
            _Segments(
              labels: context
                  .label('Shell,Files,Code', label: 'Labels (comma)')
                  .split(',')
                  .map((label) => label.trim())
                  .where((label) => label.isNotEmpty)
                  .toList(),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'ScreenScaffold',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final back = context.knobs.boolean(label: 'Back', initialValue: true);
          return ScreenScaffold(
            title: context.label('nyx', label: 'Title'),
            breadcrumb: context.label('/ HOSTS / NYX', label: 'Breadcrumb'),
            onBack: back ? _noop : null,
            children: const [
              Panel(
                title: 'Session',
                child: ListRowGroup(
                  children: [
                    ListRow(title: 'development', value: '3 PANES'),
                    ListRow(title: 'scratch', value: '1 PANE'),
                  ],
                ),
              ),
              Panel(title: 'Usage', child: Meta('no agents reporting')),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'AsyncSection',
    useCases: [
      WidgetbookUseCase(
        name: 'States',
        builder: (context) {
          final state = context.knobs.object.segmented(
            label: 'State',
            options: _Async.values,
            initialOption: _Async.data,
            labelBuilder: (state) => state.name,
          );
          final AsyncValue<List<String>> value = switch (state) {
            _Async.loading => const AsyncLoading(),
            _Async.error => AsyncError('host unreachable', StackTrace.empty),
            _Async.empty => const AsyncData([]),
            _Async.data => const AsyncData(['development', 'scratch']),
          };
          return Stage(
            children: [
              Specimen(
                'Loading shows after a delay',
                note: 'DelayedSpinner holds back for Effects.spinnerThreshold.',
                child: Panel(
                  title: 'Sessions',
                  child: AsyncSection<List<String>>(
                    value: value,
                    empty: 'no sessions',
                    builder: (sessions) => ListRowGroup(
                      children: [
                        for (final session in sessions)
                          ListRow(title: session, onTap: _noop),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'EmptyState',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) =>
            Stage(children: [EmptyState(context.label('no hosts yet'))]),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Panel sheet',
    useCases: [
      WidgetbookUseCase(
        name: 'Body with footer',
        builder: (context) => SheetStage(
          open: (context) => showPanelSheet<void>(
            context,
            title: 'Rename',
            builder: (context) => PanelSheetBody(
              title: 'Rename',
              footer: [
                ActionBlock(
                  label: 'SAVE',
                  tone: context.tokens.accent,
                  filled: true,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
              children: const [
                SheetField(label: 'NAME', child: Meta('nyx')),
                SizedBox(height: Spacing.md),
                SheetField(label: 'ADDRESS', child: Meta('100.118.60.77')),
              ],
            ),
          ),
        ),
      ),
      WidgetbookUseCase(
        name: 'Confirm',
        builder: (context) {
          final title = context.label('Forget host', label: 'Title');
          final confirm = context.label('Forget', label: 'Confirm label');
          final message = context.label(
            'Its pinned key and stored sessions go with it.',
            label: 'Message',
          );
          return SheetStage(
            open: (context) => confirmSheet(
              context,
              title: title,
              confirmLabel: confirm,
              message: message.isEmpty ? null : message,
            ),
          );
        },
      ),
    ],
  ),
];

void _noop() {}

class _Segments extends StatefulWidget {
  const _Segments({required this.labels});

  final List<String> labels;

  @override
  State<_Segments> createState() => _SegmentsState();
}

class _SegmentsState extends State<_Segments> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels.isEmpty ? const ['—'] : widget.labels;
    final index = _index.clamp(0, labels.length - 1);
    return Specimen(
      'Tap a segment',
      note: 'selected: ${labels[index]}',
      child: SegmentSwitch(
        labels: labels,
        currentIndex: index,
        onSelected: (index) => setState(() => _index = index),
      ),
    );
  }
}
