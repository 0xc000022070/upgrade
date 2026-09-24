import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../platform/device.dart';
import 'shell_sessions.dart';

/// The two moments a shell whose reconnect schedule ran out is dialled again: the app
/// coming back in front, and a network arriving under it. Mounted above the shell route
/// rather than inside it, because the store outlives every route.
class ShellWakeHost extends ConsumerStatefulWidget {
  const ShellWakeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShellWakeHost> createState() => _ShellWakeHostState();
}

class _ShellWakeHostState extends ConsumerState<ShellWakeHost> {
  StreamSubscription<bool>? _network;
  var _away = false;

  @override
  void initState() {
    super.initState();
    _network = Device.networkChanges().listen((up) {
      // Only an arrival. A network going is what put these tabs where they are, and
      // dialling over nothing would spend the fresh schedule for nothing.
      if (up) ref.read(shellSessionsProvider).wakeAll();
    });
  }

  @override
  void dispose() {
    unawaited(_network?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(appVisibleProvider, (was, now) {
      if (!now) _away = true;
    });
    ref.listen<bool>(appForegroundProvider, (was, now) {
      if (!now || was == true) return;
      ref.read(shellSessionsProvider).wakeAll(rehome: _away);
      _away = false;
    });
    return widget.child;
  }
}
