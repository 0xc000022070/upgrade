import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/alerts/toasts.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/drag_sheet.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/shell_launch.dart';
import 'package:upgrade/features/shell/host_shell_screen.dart';
import 'package:upgrade/features/shell/sheets/launch_picker_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';

final _openShellRoutes = Expando<ShellSheetRoute>();

void openHostShell(
  BuildContext context,
  Host host, {
  required UserIntent? intent,
  ShellSession? session,
  String? command,
  String? directory,
  PaneRef? pane,
  ShellLaunch? launch,
  bool ownConnection = false,
  bool openNew = false,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final fresh = openNew || command != null || launch != null;
  if (fresh && !container.read(shellSessionsProvider).canOpen(host.id)) {
    // Raised before the push: the sheet covers the strip, and landing on the last tab
    // would pass for the new one.
    container
        .read(toastQueueProvider.notifier)
        .raise(
          Toast(
            id: 'tab-limit:${host.id}',
            verb: 'TAB LIMIT',
            subject: host.name,
          ),
        );
    return;
  }

  final navigator = Navigator.of(context, rootNavigator: true);
  final up = _openShellRoutes[navigator];
  if (up != null && up.isActive) {
    if (up.host.id == host.id) return;
    // Asked for another host while this one's shell is up, which is what a tap on a
    // passphrase notification does: the sheet goes to the host that was asked for.
    navigator.removeRoute(up);
  }

  final route = ShellSheetRoute(
    host: host,
    intent: intent,
    session: session,
    command: command,
    directory: directory,
    pane: pane,
    launch: launch,
    ownConnection: ownConnection,
    openNew: openNew,
  );
  _openShellRoutes[navigator] = route;
  unawaited(
    navigator.push(route).whenComplete(() {
      if (identical(_openShellRoutes[navigator], route)) {
        _openShellRoutes[navigator] = null;
      }
    }),
  );
}

/// A host with a shell still running resumes its last tab; one whose tabs have all
/// exited, or that has none, asks how to start one. Exited tabs stay on the strip.
Future<void> pickHostShell(
  BuildContext context,
  ShellSessions store,
  Host host,
  UserIntent intent,
) async {
  final running = store.forHost(host.id).any((s) => s.state is! ShellExited);
  if (running) return openHostShell(context, host, intent: intent);
  await showLaunchPicker(
    context,
    host,
    onPick: (picked, launch, {ownConnection = false}) {
      if (!context.mounted) return;
      openHostShell(
        context,
        host,
        intent: picked,
        launch: launch,
        ownConnection: ownConnection,
        openNew: true,
      );
    },
  );
}

class ShellSheetRoute extends DragSheetRoute<void> with KeepsScreensEdge {
  ShellSheetRoute({
    required this.host,
    required this.intent,
    this.session,
    this.command,
    this.directory,
    this.pane,
    this.launch,
    this.ownConnection = false,
    this.openNew = false,
  });

  final Host host;
  final UserIntent? intent;
  final ShellSession? session;

  /// What the tab runs in place of the login shell, which is how an agent row hands its
  /// attach, and a workspace its directory, to a terminal.
  final String? command;

  final String? directory;

  /// Remembered on the tab so the next tap on that agent finds it.
  final PaneRef? pane;

  final ShellLaunch? launch;

  final bool ownConnection;

  final bool openNew;

  @override
  Key get frameKey => const ValueKey('shell-sheet');

  @override
  Key get ruleKey => const ValueKey('shell-grip-rule');

  @override
  String get barrierLabel => '${host.name} shell';

  @override
  Widget buildSheet(BuildContext context) {
    return _SheetContents(
      host: host,
      intent: intent,
      session: session,
      command: command,
      directory: directory,
      pane: pane,
      launch: launch,
      ownConnection: ownConnection,
      openNew: openNew,
    );
  }
}

/// The shell is keyed by host id, so switching drops the state of the host being left and
/// builds the one arrived at from its `initState` — the same path a fresh open takes,
/// which is what makes the arriving host activate the tab it was asked for.
class _SheetContents extends StatefulWidget {
  const _SheetContents({
    required this.host,
    required this.intent,
    this.session,
    this.command,
    this.directory,
    this.pane,
    this.launch,
    this.ownConnection = false,
    this.openNew = false,
  });

  final Host host;
  final UserIntent? intent;
  final ShellSession? session;
  final String? command;
  final String? directory;
  final PaneRef? pane;
  final ShellLaunch? launch;
  final bool ownConnection;
  final bool openNew;

  @override
  State<_SheetContents> createState() => _SheetContentsState();
}

class _SheetContentsState extends State<_SheetContents> {
  late Host _host = widget.host;

  late UserIntent? _intent = widget.intent;
  late ShellSession? _session = widget.session;
  late var _openNew = widget.openNew || widget.launch != null;
  late ShellLaunch? _openLaunch = widget.launch;
  late var _openOwn = widget.ownConnection;

  void _switchTo(Host host, ShellSession? session) {
    if (host.id == _host.id) return;
    setState(() {
      _host = host;
      _intent = null;
      _session = session;
      _openNew = false;
    });
  }

  void _openOn(
    Host host,
    ShellLaunch? launch,
    UserIntent intent, {
    bool ownConnection = false,
  }) {
    if (host.id == _host.id) return;
    setState(() {
      _host = host;
      _intent = intent;
      _session = null;
      _openNew = true;
      _openLaunch = launch;
      _openOwn = ownConnection;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HostShellRoute(
      key: ValueKey(_host.id),
      host: _host,
      intent: _intent,
      session: _session,
      openNew: _openNew,
      openLaunch: _openLaunch,
      openOwn: _openOwn,
      // Only the host the sheet opened on is the one they were meant for: switching
      // hosts carries nothing of the directory or the agent it came from.
      command: _host.id == widget.host.id ? widget.command : null,
      directory: _host.id == widget.host.id ? widget.directory : null,
      pane: _host.id == widget.host.id ? widget.pane : null,
      onSwitchHost: _switchTo,
      onOpenHost: _openOn,
    );
  }
}
