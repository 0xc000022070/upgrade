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
  var _step = 0;
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

  void _back() => setState(() => _step--);

  void _install() => Navigator.of(context).pop(
    PhoneLinuxSetup(
      _distro.id,
      nix: _nix,
      tools: {
        for (final tool in widget.catalog.tools)
          if (_tools.contains(tool.id) && tool.fits(_distro, nix: _nix))
            tool.id,
      },
      name: _name.text,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final last = _step == 2;
    return PanelSheetBody(
      title: switch (_step) {
        0 => 'LINUX ON THIS PHONE',
        1 => 'LINUX ON THIS PHONE · PACKAGES',
        _ => 'LINUX ON THIS PHONE · TOOLS',
      },
      footer: [
        Row(
          children: [
            Expanded(
              child: _step == 0
                  ? ActionBlock(
                      label: 'CANCEL',
                      onTap: () => Navigator.of(context).pop(),
                    )
                  : ActionBlock(
                      key: const ValueKey('phone-linux-back'),
                      label: 'BACK',
                      onTap: _back,
                    ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                key: ValueKey(
                  last ? 'phone-linux-install' : 'phone-linux-next',
                ),
                label: last ? 'INSTALL' : 'NEXT',
                tone: tokens.accent,
                filled: true,
                onTap: last ? _install : () => setState(() => _step++),
              ),
            ),
          ],
        ),
      ],
      children: switch (_step) {
        0 => _systemStep(context),
        1 => _packageStep(context),
        _ => _toolStep(context),
      },
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
    ];
  }

  Widget _chosen({required bool nix}) => ListRowGroup(
    children: [
      ListRow(
        key: const ValueKey('phone-linux-chosen'),
        leading: HostMark(_distro.system, phone: true, size: IconSizes.glyph),
        title: _named,
        subtitle: [_distro.label, if (nix && _nix) 'NIX'].join(' · '),
        trailing: PanelAffordance('CHANGE', showIcon: false, onTap: _back),
        onTap: _back,
      ),
    ],
  );

  List<Widget> _packageStep(BuildContext context) => [
    _chosen(nix: false),
    const SizedBox(height: Spacing.lg),
    SheetField(
      label: 'PACKAGE MANAGERS',
      child: ListRowGroup(
        children: [
          ListRow(
            key: const ValueKey('phone-linux-manager'),
            leading: UpgradeIcon(
              UpgradeIcons.checkboxChecked,
              size: IconSizes.check,
              color: context.tokens.textMuted,
            ),
            title: _distro.manager.toUpperCase(),
            subtitle: "${_distro.short}'s own · always there",
          ),
          ListRow(
            key: const ValueKey('phone-linux-nix'),
            leading: _checkbox(context, _nix),
            title: 'NIX',
            subtitle:
                'Its own glibc, for root · '
                'about ${widget.catalog.nixMb} MB to download',
            subtitleMaxLines: 2,
            onTap: () => setState(() => _nix = !_nix),
          ),
        ],
      ),
    ),
  ];

  List<Widget> _toolStep(BuildContext context) {
    String unfit(PhoneLinuxTool tool) {
      final others = [
        for (final distro in widget.catalog.distros)
          if (distro.libc == tool.libc) distro.short,
      ];
      return _unfit(
        tool,
        _distro,
        throughNix: [
          'Needs ${tool.libc}: choose NIX in the previous step',
          if (others.isNotEmpty) 'or pick ${others.join(' or ')}',
        ].join(', '),
      );
    }

    return [
      _chosen(nix: true),
      const SizedBox(height: Spacing.lg),
      _ToolRows(
        tools: widget.catalog.tools,
        chosen: _tools,
        fits: (tool) => tool.fits(_distro, nix: _nix),
        unfit: unfit,
        onToggle: (tool) =>
            setState(() => _tools.remove(tool.id) || _tools.add(tool.id)),
      ),
    ];
  }
}

Widget _checkbox(BuildContext context, bool checked) => UpgradeIcon(
  checked ? UpgradeIcons.checkboxChecked : UpgradeIcons.checkboxEmpty,
  size: IconSizes.check,
  color: checked ? context.tokens.accent : context.tokens.textMuted,
);

String _unfit(
  PhoneLinuxTool tool,
  PhoneLinuxDistro distro, {
  required String throughNix,
}) => tool.libc == null || tool.libc == distro.libc
    ? 'Not offered on ${distro.label}'
    : tool.nix
    ? throughNix
    : 'Needs ${tool.libc}, which ${distro.label} does not have';

class _ToolRows extends StatelessWidget {
  const _ToolRows({
    required this.tools,
    required this.chosen,
    required this.fits,
    required this.unfit,
    required this.onToggle,
  });

  final Iterable<PhoneLinuxTool> tools;
  final Set<String> chosen;
  final bool Function(PhoneLinuxTool tool) fits;
  final String Function(PhoneLinuxTool tool) unfit;
  final ValueChanged<PhoneLinuxTool> onToggle;

  @override
  Widget build(BuildContext context) {
    final muted = context.tokens.textMuted;
    final sections = <String, List<PhoneLinuxTool>>{};
    for (final tool in tools) {
      (sections[tool.section] ??= []).add(tool);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, MapEntry(key: section, value: tools))
            in sections.entries.indexed) ...[
          if (index > 0) const SizedBox(height: Spacing.lg),
          SheetField(
            label: section,
            child: ListRowGroup(
              children: [
                for (final tool in tools)
                  if (fits(tool))
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
                      subtitle: unfit(tool),
                      subtitleColor: muted,
                      subtitleMaxLines: 2,
                    ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

Future<Set<String>?> pickPhoneLinuxTools(
  BuildContext context, {
  required PhoneLinuxCatalog catalog,
  required PhoneLinuxDistro distro,
  required bool nix,
  required Set<String> installed,
}) => showPanelSheet<Set<String>>(
  context,
  title: 'TOOLS',
  builder: (context) => _PhoneLinuxToolPicker(
    distro: distro,
    nix: nix,
    tools: [
      for (final tool in catalog.tools)
        if (!installed.contains(tool.id)) tool,
    ],
  ),
);

class _PhoneLinuxToolPicker extends StatefulWidget {
  const _PhoneLinuxToolPicker({
    required this.distro,
    required this.nix,
    required this.tools,
  });

  final PhoneLinuxDistro distro;
  final bool nix;
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
          tools: widget.tools,
          chosen: _chosen,
          fits: (tool) => tool.fits(widget.distro, nix: widget.nix),
          unfit: (tool) => _unfit(
            tool,
            widget.distro,
            throughNix:
                'Needs ${tool.libc}, which ${widget.distro.label} '
                'does not have; a system with NIX can add it',
          ),
          onToggle: (tool) =>
              setState(() => _chosen.remove(tool.id) || _chosen.add(tool.id)),
        ),
      ],
    );
  }
}
