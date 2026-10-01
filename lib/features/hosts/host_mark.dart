import 'package:flutter/widgets.dart';

import '../../data/enums.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';

DazzleIcons systemGlyph(HostSystem? system) => switch (system) {
  HostSystem.nixos => DazzleIcons.systemNixos,
  HostSystem.darwin => DazzleIcons.systemDarwin,
  HostSystem.linux || HostSystem.other || null => DazzleIcons.systemServer,
};

String systemWord(HostSystem? system) => switch (system) {
  HostSystem.nixos => 'NixOS',
  HostSystem.darwin => 'macOS',
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
    child: DazzleIcon(
      systemGlyph(system),
      size: size,
      color: color ?? context.tokens.textSecondary,
    ),
  );
}
