import 'package:flutter/widgets.dart';

import 'package:upgrade/data/enums.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';

UpgradeIcons systemGlyph(HostSystem? system) => switch (system) {
  HostSystem.nixos => UpgradeIcons.systemNixos,
  HostSystem.darwin => UpgradeIcons.systemDarwin,
  HostSystem.ubuntu => UpgradeIcons.systemUbuntu,
  HostSystem.arch => UpgradeIcons.systemArch,
  HostSystem.alpine => UpgradeIcons.systemAlpine,
  HostSystem.linux || HostSystem.other || null => UpgradeIcons.systemServer,
};

String systemWord(HostSystem? system) => switch (system) {
  HostSystem.nixos => 'NixOS',
  HostSystem.darwin => 'macOS',
  HostSystem.ubuntu => 'Ubuntu',
  HostSystem.arch => 'Arch Linux',
  HostSystem.alpine => 'Alpine Linux',
  HostSystem.linux => 'Linux',
  HostSystem.other || null => 'host',
};

class HostMark extends StatelessWidget {
  const HostMark(
    this.system, {
    super.key,
    this.size = IconSizes.sm,
    this.color,
  });

  final HostSystem? system;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: systemWord(system),
    child: UpgradeIcon(
      systemGlyph(system),
      size: size,
      color: color ?? context.tokens.textSecondary,
    ),
  );
}
