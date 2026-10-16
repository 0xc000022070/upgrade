import 'package:flutter/material.dart';

import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/platform/phone_linux.dart';

Future<PhoneLinuxSetup?> pickPhoneLinuxSetup(
  BuildContext context, {
  required PhoneLinuxCatalog catalog,
  required String name,
}) => showPanelSheet<PhoneLinuxSetup>(
  context,
  title: 'LINUX ON THIS PHONE',
  builder: (context) => _PhoneLinuxPicker(catalog: catalog, name: name),
);

class _PhoneLinuxPicker extends StatefulWidget {
  const _PhoneLinuxPicker({required this.catalog, required this.name});

  final PhoneLinuxCatalog catalog;
  final String name;

  @override
  State<_PhoneLinuxPicker> createState() => _PhoneLinuxPickerState();
}

class _PhoneLinuxPickerState extends State<_PhoneLinuxPicker> {
  late var _distro = widget.catalog.distros.first;
  var _nix = false;
  var _choosingTools = false;
  final _tools = <String>{};
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _named {
    final name = _name.text.trim();
    return name.isEmpty ? widget.name : name;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tools = _choosingTools;
    return PanelSheetBody(
      title: tools ? 'LINUX ON THIS PHONE · TOOLS' : 'LINUX ON THIS PHONE',
      footer: [
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                label: tools ? 'BACK' : 'CANCEL',
                onTap: tools
                    ? () => setState(() => _choosingTools = false)
                    : () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                key: ValueKey(
                  tools ? 'phone-linux-install' : 'phone-linux-next',
                ),
                label: tools ? 'INSTALL' : 'NEXT',
                tone: tokens.accent,
                filled: true,
                onTap: tools
                    ? () => Navigator.of(context).pop(
                        PhoneLinuxSetup(
                          _distro.id,
                          nix: _nix,
                          tools: {
                            for (final tool in widget.catalog.tools)
                              if (_tools.contains(tool.id) &&
                                  tool.fits(_distro))
                                tool.id,
                          },
                          name: _name.text,
                        ),
                      )
                    : () => setState(() => _choosingTools = true),
              ),
            ),
          ],
        ),
      ],
      children: tools ? _toolStep(context) : _systemStep(context),
    );
  }

  List<Widget> _systemStep(BuildContext context) {
    final tokens = context.tokens;
    return [
      Text(
        'Adds this phone to your hosts. It runs as an app, without root.',
        style: tokens.prose,
      ),
      const SizedBox(height: Spacing.md),
      SheetField(
        label: 'NAME',
        child: UpgradeField(
          key: const ValueKey('phone-linux-name'),
          controller: _name,
          hint: widget.name,
        ),
      ),
      const SizedBox(height: Spacing.md),
      ListRowGroup(
        children: [
          for (final distro in widget.catalog.distros)
            ListRow(
              key: ValueKey('phone-linux-distro-${distro.id}'),
              leading: HostMark(
                distro.system,
                phone: true,
                size: IconSizes.glyph,
              ),
              title: distro.label,
              subtitle: distro.detail,
              subtitleMaxLines: 2,
              trailing: distro == _distro
                  ? UpgradeIcon(
                      UpgradeIcons.check,
                      size: IconSizes.check,
                      color: tokens.accent,
                    )
                  : null,
              onTap: () => setState(() => _distro = distro),
            ),
        ],
      ),
      const SizedBox(height: Spacing.lg),
      ListRowGroup(
        children: [
          ListRow(
            key: const ValueKey('phone-linux-nix'),
            leading: _checkbox(context, _nix),
            title: 'NIX',
            subtitle:
                'The package manager, for root · '
                'about ${widget.catalog.nixMb} MB to download',
            subtitleMaxLines: 2,
            onTap: () => setState(() => _nix = !_nix),
          ),
        ],
      ),
    ];
  }

  List<Widget> _toolStep(BuildContext context) => [
    ListRowGroup(
      children: [
        ListRow(
          key: const ValueKey('phone-linux-chosen'),
          leading: HostMark(_distro.system, phone: true, size: IconSizes.glyph),
          title: _named,
          subtitle: [_distro.label, if (_nix) 'NIX'].join(' · '),
          trailing: PanelAffordance(
            'CHANGE',
            showIcon: false,
            onTap: () => setState(() => _choosingTools = false),
          ),
          onTap: () => setState(() => _choosingTools = false),
        ),
      ],
    ),
    const SizedBox(height: Spacing.lg),
    _ToolRows(
      distro: _distro,
      tools: widget.catalog.tools,
      chosen: _tools,
      onToggle: (tool) =>
          setState(() => _tools.remove(tool.id) || _tools.add(tool.id)),
    ),
  ];
}

Widget _checkbox(BuildContext context, bool checked) => UpgradeIcon(
  checked ? UpgradeIcons.checkboxChecked : UpgradeIcons.checkboxEmpty,
  size: IconSizes.check,
  color: checked ? context.tokens.accent : context.tokens.textMuted,
);

class _ToolRows extends StatelessWidget {
  const _ToolRows({
    required this.distro,
    required this.tools,
    required this.chosen,
    required this.onToggle,
  });

  final PhoneLinuxDistro distro;
  final Iterable<PhoneLinuxTool> tools;
  final Set<String> chosen;
  final ValueChanged<PhoneLinuxTool> onToggle;

  @override
  Widget build(BuildContext context) {
    final muted = context.tokens.textMuted;
    return SheetField(
      label: 'TOOLS',
      child: ListRowGroup(
        children: [
          for (final tool in tools)
            if (tool.fits(distro))
              ListRow(
                key: ValueKey('phone-linux-tool-${tool.id}'),
                leading: _checkbox(context, chosen.contains(tool.id)),
                title: tool.label,
                subtitle: tool.detail,
                subtitleMaxLines: 2,
                onTap: () => onToggle(tool),
              )
            else
              ListRow(
                key: ValueKey('phone-linux-tool-${tool.id}'),
                leading: _checkbox(context, false),
                title: tool.label,
                titleColor: muted,
                subtitle: tool.libc == null || tool.libc == distro.libc
                    ? 'Not offered on ${distro.label}'
                    : 'Needs ${tool.libc}, which ${distro.label} does not have',
                subtitleColor: muted,
                subtitleMaxLines: 2,
              ),
        ],
      ),
    );
  }
}

Future<Set<String>?> pickPhoneLinuxTools(
  BuildContext context, {
  required PhoneLinuxCatalog catalog,
  required PhoneLinuxDistro distro,
  required Set<String> installed,
}) => showPanelSheet<Set<String>>(
  context,
  title: 'TOOLS',
  builder: (context) => _PhoneLinuxToolPicker(
    distro: distro,
    tools: [
      for (final tool in catalog.tools)
        if (!installed.contains(tool.id)) tool,
    ],
  ),
);

class _PhoneLinuxToolPicker extends StatefulWidget {
  const _PhoneLinuxToolPicker({required this.distro, required this.tools});

  final PhoneLinuxDistro distro;
  final List<PhoneLinuxTool> tools;

  @override
  State<_PhoneLinuxToolPicker> createState() => _PhoneLinuxToolPickerState();
}

class _PhoneLinuxToolPickerState extends State<_PhoneLinuxToolPicker> {
  final _chosen = <String>{};

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return PanelSheetBody(
      title: 'TOOLS',
      footer: [
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                label: 'CANCEL',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: 'INSTALL',
                tone: tokens.accent,
                filled: true,
                onTap: _chosen.isEmpty
                    ? null
                    : () => Navigator.of(context).pop({..._chosen}),
              ),
            ),
          ],
        ),
      ],
      children: [
        _ToolRows(
          distro: widget.distro,
          tools: widget.tools,
          chosen: _chosen,
          onToggle: (tool) =>
              setState(() => _chosen.remove(tool.id) || _chosen.add(tool.id)),
        ),
      ],
    );
  }
}
