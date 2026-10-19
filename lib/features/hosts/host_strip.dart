import 'package:flutter/material.dart';

import 'package:striked/data/enums.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/hosts/host_mark.dart';

const hostGroupMaxWidth = 80.0;

class HostGroupCell extends StatelessWidget {
  const HostGroupCell({
    super.key,
    required this.name,
    required this.system,
    this.hostId,
    required this.front,
    required this.onTap,
    this.hidden = 0,
    this.tint,
  });

  final String name;
  final HostSystem? system;
  final String? hostId;
  final bool front;
  final int hidden;
  final VoidCallback onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final ink =
        tint ?? (front ? context.tokens.textPrimary : context.tokens.textMuted);
    return Semantics(
      label: hidden > 0 ? '$name, $hidden tabs folded' : name,
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          color: context.tokens.surfaceSecondary,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HostMark(
                system,
                hostId: hostId,
                size: IconSizes.affordance,
                color: ink,
              ),
              const SizedBox(width: Spacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth:
                      hostGroupMaxWidth - IconSizes.affordance - Spacing.xs,
                ),
                child: Text(
                  name.toUpperCase(),
                  style: context.tokens.label.copyWith(color: ink),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (hidden > 0) ...[
                const SizedBox(width: Spacing.xs),
                Text(
                  '+$hidden',
                  style: context.tokens.label.copyWith(
                    color: context.tokens.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HostMenu extends StatelessWidget {
  const HostMenu({
    super.key,
    required this.title,
    required this.hosts,
    required this.onPick,
    required this.builder,
    required this.itemKey,
    this.current,
    this.controller,
    this.onOpen,
    this.onClose,
  });

  final String title;
  final List<Host> hosts;
  final void Function(Host host) onPick;
  final MenuAnchorChildBuilder builder;
  final String Function(Host host) itemKey;
  final String? current;
  final MenuController? controller;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: controller,
      onOpen: onOpen,
      onClose: onClose,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          context.tokens.surfaceSecondary,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(Spacing.sm)),
        minimumSize: const WidgetStatePropertyAll(Size(200, 0)),
        maximumSize: const WidgetStatePropertyAll(Size(280, 360)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(Radii.sharp)),
            side: BorderSide(color: context.tokens.borderNormal),
          ),
        ),
      ),
      alignmentOffset: const Offset(0, Spacing.sm),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.sm,
            Spacing.md,
            Spacing.sm,
          ),
          child: Text(title, style: context.tokens.label),
        ),
        for (final host in hosts)
          MenuItemButton(
            key: ValueKey(itemKey(host)),
            onPressed: () => onPick(host),
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(
                Size(192, TapTargets.minHeight),
              ),
              padding: WidgetStatePropertyAll(
                EdgeInsetsDirectional.only(start: Spacing.md, end: Spacing.lg),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(Radii.sharp)),
                ),
              ),
            ),
            child: Row(
              children: [
                StrikedIcon(
                  StrikedIcons.hosts,
                  size: IconSizes.glyph,
                  color: context.tokens.textMuted,
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Text(
                    host.name.toUpperCase(),
                    style: context.tokens.rowTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (host.id == current) ...[
                  const SizedBox(width: Spacing.md),
                  Text('CURRENT', style: context.tokens.label),
                ],
              ],
            ),
          ),
      ],
      builder: builder,
    );
  }
}
