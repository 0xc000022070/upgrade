import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../design/components/static_background.dart';

/// SPEC.md §16b.1's grain with §39.16's switch in front of it. The driver lives
/// in the design layer and takes a flag; reading the preference is this layer's
/// job, so a design component never learns that a database exists.
///
/// The preference is watched rather than read once: it is changed on the
/// settings route, and the driver underneath it has to stop on the write and
/// not on the next mount.
class StaticSurface extends ConsumerWidget {
  const StaticSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Before the first row arrives the grain runs, which is what every build
    // before §39.16 did. Defaulting to off would make the app look broken for
    // the frame it takes to read one row.
    final enabled = ref.watch(staticEnabledProvider).value ?? true;
    return StaticBackgroundDriver(enabled: enabled, child: child);
  }
}
