import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/design/components/ascii_background.dart';
import 'package:upgrade/design/theme.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/device.dart';

class StaticSurface extends ConsumerWidget {
  const StaticSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(staticEnabledProvider).value ?? true;
    final choice = ref.watch(themeProvider).value ?? ThemeChoice.house;
    return AsciiBackgroundDriver(
      enabled: enabled,
      colour: context.tokens.textMuted,
      wallpaper: choice.wallpaper,
      throttled: Device.throttleChanges(),
      child: child,
    );
  }
}
