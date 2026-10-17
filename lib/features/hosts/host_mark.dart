import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/phone_linux.dart';
import 'package:striked/data/enums.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';

StrikedIcons systemGlyph(HostSystem? system) => switch (system) {
  HostSystem.nixos => StrikedIcons.systemNixos,
  HostSystem.darwin => StrikedIcons.systemDarwin,
  HostSystem.ubuntu => StrikedIcons.systemUbuntu,
  HostSystem.arch => StrikedIcons.systemArch,
  HostSystem.alpine => StrikedIcons.systemAlpine,
  HostSystem.linux || HostSystem.other || null => StrikedIcons.systemServer,
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
                  StrikedIcon(StrikedIcons.phoneFrame, size: size, color: ink),
                  Positioned(
                    left: size * glyphAt.dx / _phoneViewBox,
                    top: size * glyphAt.dy / _phoneViewBox,
                    child: StrikedIcon(
                      systemGlyph(system),
                      size: size * _glyphScale,
                      color: ink,
                    ),
                  ),
                ],
              ),
            )
          : StrikedIcon(systemGlyph(system), size: size, color: ink),
    );
  }
}
