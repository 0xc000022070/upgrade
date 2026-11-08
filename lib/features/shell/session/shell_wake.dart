import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/shell/session/shell_hold.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';

/// Two of the moments a shell whose reconnect schedule ran out is dialled again: the app
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
  late final ShellHold _hold = ShellHold(
    ref.read(shellSessionsProvider),
    ref.read(shellHoldProvider),
  );

  @override
  void initState() {
    super.initState();
    _hold.refresh();
    unawaited(Device.refreshVpn());
    _network = Device.networkChanges().listen(
      PlatformSignal.onNetwork((signal, up) {
        // Only an arrival. A network going is what put these tabs where they are, and
        // dialling over nothing would spend the fresh schedule for nothing.
        if (up) {
          ref.read(shellSessionsProvider).wakeAll(NetworkChanged(signal));
          // Only a tab's host is renounced; the panel's and the code view's links on the
          // old path would otherwise wait out their keepalive.
          unawaited(ref.read(hostLinksProvider).recheckAll());
          ref.read(agentsWakeProvider.notifier).state++;
        }
      }),
    );
  }

  @override
  void dispose() {
    _hold.dispose();
    unawaited(_network?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appVisibleProvider,
      PlatformSignal.onLifecycle((signal, was, now) {
        if (now) return;
        _away = true;
        ref.read(shellSessionsProvider).leave(signal);
      }),
    );
    ref.listen<bool>(
      appForegroundProvider,
      PlatformSignal.onLifecycle((signal, was, now) {
        if (!now || was == true) return;
        unawaited(Device.refreshVpn());
        final resumed = AppResumed(signal);
        ref.read(shellSessionsProvider)
          ..returned(resumed)
          ..wakeAll(resumed, rehome: _away);
        _away = false;
        _hold.refresh();
        ref.read(agentsWakeProvider.notifier).state++;
      }),
    );
    return widget.child;
  }
}
