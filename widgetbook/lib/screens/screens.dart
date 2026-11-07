import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/data/project_icons.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/features/code/diff_pane.dart';
import 'package:upgrade/features/devices/device_sheet.dart';
import 'package:upgrade/features/home/usage_panel.dart';
import 'package:upgrade/features/hosts/hook_sheet.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/projects/project_icon_picker.dart';
import 'package:upgrade/features/tasks/link_preview_card.dart';

import 'package:upgrade_widgetbook/frame.dart';
import 'package:upgrade_widgetbook/screens/fixtures.dart';

final screenComponents = [
  WidgetbookComponent(
    name: 'Usage panel',
    useCases: [
      WidgetbookUseCase(
        name: 'Accounts',
        builder: (context) {
          final session = context.knobs.double.slider(
            label: 'Claude session %',
            initialValue: 46,
            max: 100,
          );
          final reached = context.knobs.boolean(label: 'Codex limit reached');
          final unreached = context.knobs.boolean(label: 'Pine not reached');
          final stale = context.knobs.int.slider(
            label: 'Captured (min ago)',
            initialValue: 2,
            max: 240,
          );
          return _Usage(
            usages: [
              (
                host: hostVm,
                usage: usageOf(
                  'claude',
                  session: session,
                  week: 61,
                  plan: 'max',
                  age: Duration(minutes: stale),
                ),
              ),
              (
                host: hostPine,
                usage: usageOf(
                  'codex',
                  session: reached ? 100 : 12,
                  reached: reached,
                  error: unreached ? 'NOT REACHED' : null,
                  account: 'dev@pine',
                ),
              ),
            ],
          );
        },
      ),
      WidgetbookUseCase(
        name: 'Single account',
        builder: (context) =>
            _Usage(usages: [(host: hostVm, usage: usageOf('claude'))]),
      ),
      WidgetbookUseCase(
        name: 'Empty',
        builder: (context) => const Stage(
          children: [
            Specimen(
              'No account, no panel',
              note: 'UsagePanel draws nothing until a host reports usage.',
              child: _Usage(usages: []),
            ),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Host key sheet',
    useCases: [
      WidgetbookUseCase(
        name: 'New key',
        builder: (context) => SheetStage(
          open: (context) =>
              askHostKey(context, host: hostVm, offer: hostKeyOffer),
        ),
      ),
      WidgetbookUseCase(
        name: 'Changed key',
        builder: (context) => SheetStage(
          open: (context) => askHostKey(
            context,
            host: hostVm,
            offer: hostKeyOffer,
            pinned: pinnedHostKey,
          ),
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Hook sheet',
    useCases: [
      WidgetbookUseCase(
        name: 'Installed',
        builder: (context) => SheetStage(
          open: (context) => showHookSheet(context, hookInstalled),
        ),
      ),
      WidgetbookUseCase(
        name: 'Missing',
        builder: (context) =>
            SheetStage(open: (context) => showHookSheet(context, hookMissing)),
      ),
      WidgetbookUseCase(
        name: 'Declared by Nix',
        builder: (context) =>
            SheetStage(open: (context) => showHookSheet(context, hookDeclared)),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Device sheet',
    useCases: [
      for (final (name, fixture) in const [
        ('Listed', DeviceFixture.listed),
        ('No stopped devices', DeviceFixture.none),
        ('No tools', DeviceFixture.noTools),
        ('Host unreachable', DeviceFixture.failed),
        ('Loading', DeviceFixture.loading),
      ])
        WidgetbookUseCase(
          name: name,
          builder: (context) => SheetStage(
            open: (context) async {
              final group = fixtureDevices(fixture);
              try {
                await showDeviceSheet(context, group);
              } finally {
                group.dispose();
              }
              return null;
            },
          ),
        ),
    ],
  ),
  WidgetbookComponent(
    name: 'Link preview card',
    useCases: [
      WidgetbookUseCase(
        name: 'Variants',
        builder: (context) => const Stage(
          children: [
            Specimen(
              'Full',
              note:
                  'Fixtures carry no image URL: the thumbnail would be a '
                  'network fetch.',
              child: LinkPreviewCard(preview: linkFull),
            ),
            Specimen('URL only', child: LinkPreviewCard(preview: linkBare)),
          ],
        ),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Project icon picker',
    useCases: [
      WidgetbookUseCase(
        name: 'Interactive',
        builder: (context) => const Stage(children: [_IconPicker()]),
      ),
    ],
  ),
  WidgetbookComponent(
    name: 'Diff stat',
    useCases: [
      WidgetbookUseCase(
        name: 'Playground',
        builder: (context) {
          final files = context.knobs.int.slider(
            label: 'Files (0 = hidden)',
            initialValue: 3,
            max: 40,
          );
          return Stage(
            children: [
              DiffStat(
                added: context.knobs.int.slider(
                  label: 'Added',
                  initialValue: 128,
                  max: 2000,
                ),
                removed: context.knobs.int.slider(
                  label: 'Removed',
                  initialValue: 41,
                  max: 2000,
                ),
                files: files == 0 ? null : files,
              ),
            ],
          );
        },
      ),
    ],
  ),
];

class _Usage extends StatelessWidget {
  const _Usage({required this.usages});

  final List<HostUsage> usages;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      retry: (_, _) => null,
      overrides: [usageFeedProvider.overrideWith(FixtureUsageFeed.new)],
      child: Stage(
        children: [UsagePanel(usages: usages, now: fixedNow)],
      ),
    );
  }
}

class _IconPicker extends StatefulWidget {
  const _IconPicker();

  @override
  State<_IconPicker> createState() => _IconPickerState();
}

class _IconPickerState extends State<_IconPicker> {
  String? _value = ProjectIconKind.raven.name;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProjectIconPicker(
          value: _value,
          onChanged: (value) => setState(() => _value = value),
        ),
        Meta('value: ${_value ?? 'null'}'),
      ],
    );
  }
}
