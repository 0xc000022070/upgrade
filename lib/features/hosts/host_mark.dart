import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/phone_linux.dart';
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

class HostMark extends ConsumerWidget {
  const HostMark(
    this.system, {
    super.key,
    this.hostId,
    this.phone = false,
    this.size = IconSizes.sm,
    this.color,
  });

  final HostSystem? system;
  final String? hostId;
  final bool phone;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ink = color ?? context.tokens.textSecondary;
    final glyph = UpgradeIcon(systemGlyph(system), size: size, color: ink);
    final onPhone = phone || hostId != null && ref.isPhoneLinux(hostId!);
    return Semantics(
      label: onPhone
          ? '${systemWord(system)} on this phone'
          : systemWord(system),
      child: onPhone
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: size / 2,
                  height: size,
                  child: ClipRect(
                    child: OverflowBox(
                      maxWidth: size,
                      child: UpgradeIcon(
                        UpgradeIcons.phone,
                        size: size,
                        color: ink,
                      ),
                    ),
                  ),
                ),
                glyph,
              ],
            )
          : glyph,
    );
  }
}
