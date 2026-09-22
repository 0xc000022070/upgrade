import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../design/components/ascii_background.dart';
import '../design/tokens.dart';

class StaticSurface extends ConsumerWidget {
  const StaticSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(staticEnabledProvider).value ?? true;
    return AsciiBackgroundDriver(
      enabled: enabled,
      colour: context.tokens.textMuted,
      child: child,
    );
  }
}
