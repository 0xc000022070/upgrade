import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/data/host_system.dart';
import 'package:upgrade/application/phone_linux.dart';
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

const _phoneViewBox = 24.0;
const _phoneScreen = Rect.fromLTRB(4, 1, 20, 19.5);
const _glyphScale = 0.5;

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
    final onPhone = phone || hostId != null && ref.isPhoneLinux(hostId!);
    const glyphUnits = _phoneViewBox * _glyphScale;
    final glyphAt =
        _phoneScreen.center - const Offset(glyphUnits, glyphUnits) / 2;
    return Semantics(
      label: onPhone
          ? '${systemWord(system)} on this phone'
          : systemWord(system),
      child: onPhone
          ? SizedBox.square(
              dimension: size,
              child: Stack(
                children: [
                  UpgradeIcon(UpgradeIcons.phoneFrame, size: size, color: ink),
                  Positioned(
                    left: size * glyphAt.dx / _phoneViewBox,
                    top: size * glyphAt.dy / _phoneViewBox,
                    child: UpgradeIcon(
                      systemGlyph(system),
                      size: size * _glyphScale,
                      color: ink,
                    ),
                  ),
                ],
              ),
            )
          : UpgradeIcon(systemGlyph(system), size: size, color: ink),
    );
  }
}
