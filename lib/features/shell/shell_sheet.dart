import 'package:flutter/widgets.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/motion.dart';
import '../../platform/herdr_client.dart';
import 'host_shell_screen.dart';
import 'shell_header.dart';
import 'shell_sessions.dart';

/// The way in: a host panel's `SHELL >` row on HOSTS, a host row on SSH, or one
/// of that tab's session cards, which names the session it wants on screen.
///
/// The shell is a sheet over that screen, not a page in front of it: the
/// screen stays drawn under the wash, and the header drags the sheet down.
void openHostShell(
  BuildContext context,
  Host host, {
  ShellSession? session,
  String? command,
  String? directory,
  PaneRef? pane,
}) {
  Navigator.of(context, rootNavigator: true).push(
    ShellSheetRoute(
      host: host,
      session: session,
      command: command,
      directory: directory,
      pane: pane,
    ),
  );
}

/// The rule on the sheet's top edge, which is the whole of what says the shell
/// is a sheet. It is drawn over the header's ground rather than above it: the
/// sheet stands flush under the status bar, and rows are what a terminal is.
const _gripWidth = 36.0;
const _gripHeight = 2.0;
const _gripInset = 5.0;

/// A release faster than this, in px/s, decides on its own: downward leaves,
/// upward stays. Slower, where the finger left the sheet decides.
const _sheetFling = 700.0;

/// A slow release past this share of the sheet's rise leaves; short of it,
/// the sheet comes back.
const _sheetLeaveShare = 1 / 3;

/// The shell as a modal sheet: the route beneath stays under a wash, the
/// sheet rises from the bottom, and a drag on its header takes it down again.
///
/// The wash is lighter than the panel sheet's: what shows through it is the
/// tab the shell was opened from, and it should still read as that tab.
class ShellSheetRoute extends PopupRoute<void> implements SheetDrag {
  ShellSheetRoute({
    required this.host,
    this.session,
    this.command,
    this.directory,
    this.pane,
  });

  final Host host;
  final ShellSession? session;

  /// What the tab runs in place of the login shell, which is how an agent row
  /// hands its attach, and a workspace its directory, to a terminal.
  final String? command;

  /// Where [command] leaves the tab standing.
  final String? directory;

  /// The herdr pane [command] attaches the tab to, remembered on the tab so
  /// the next tap on that agent finds it.
  final PaneRef? pane;

  /// Held for the route's life rather than made per frame: a curved animation
  /// listens to its parent, and one made in a build is one nobody disposes.
  CurvedAnimation? _curved;

  /// Up between a drag's start and its landing. A tap on the grip ends in the
  /// recognizer's cancel with no start before it, and that is not a drag.
  bool _dragging = false;

  @override
  Color get barrierColor => const Color(0x99000000);

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => '${host.name} shell';

  @override
  Duration get transitionDuration => Motion.normal;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _SheetFrame(
      child: _SheetContents(
        host: host,
        session: session,
        command: command,
        directory: directory,
        pane: pane,
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Under the finger the sheet is where the finger is, one to one; on its
    // own it eases. The gesture flag outlives the finger until the settle
    // lands, so the curve does not swap under a sheet that is still moving.
    final linear = navigator?.userGestureInProgress ?? false;
    final position = linear
        ? animation
        : _curved ??= CurvedAnimation(
            parent: animation,
            curve: Motion.enter,
            reverseCurve: Motion.exit,
          );
    return SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(position),
      child: child,
    );
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }

  /// The grip's drag, driven from the route so the controller stays where a
  /// route keeps it. The navigator's gesture flag goes up here and comes down
  /// only when the sheet has landed, whichever way it went.
  @override
  void dragStart() {
    _dragging = true;
    navigator!.didStartUserGesture();
  }

  /// A finger's pixel is that share of the screen's height off the rise:
  /// the slide is the screen's height, so the two move one to one.
  @override
  void dragBy(double pixels, double height) {
    final next = controller!.value - pixels / height;
    controller!.value = next.clamp(0.0, 1.0);
  }

  /// A fast release decides by its direction, a slow one by where the sheet
  /// is. Downward is positive, as the screen's y is.
  @override
  void dragEnd(double velocity) {
    if (!_dragging) return;
    final leave = velocity.abs() > _sheetFling
        ? velocity > 0
        : controller!.value < 1 - _sheetLeaveShare;
    _settle(leave: leave);
  }

  @override
  void dragCancel() {
    if (_dragging) _settle(leave: false);
  }

  void _settle({required bool leave}) {
    _dragging = false;
    final nav = navigator!;
    final ctl = controller!;
    if (leave) {
      // The pop reverses the controller from where it is, which is the rest
      // of the slide and nothing more.
      nav.pop();
    } else {
      ctl.animateTo(1, duration: Motion.fast, curve: Curves.linear);
    }
    if (!ctl.isAnimating) {
      nav.didStopUserGesture();
      return;
    }
    late final AnimationStatusListener landed;
    landed = (_) {
      ctl.removeStatusListener(landed);
      nav.didStopUserGesture();
    };
    ctl.addStatusListener(landed);
  }
}

/// The sheet's box: the screen's height less the status bar, parked at the
/// bottom, a hairline and the grip's rule along its top edge.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        key: const ValueKey('shell-sheet'),
        height: media.size.height - media.padding.top,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The frame already stands clear of the status bar, so the safe
            // area inside the route must not stand clear of it again.
            MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: DecoratedBox(
                // In front of the child: the route paints its own ground over
                // the whole box, and a rule behind it would be painted out.
                position: DecorationPosition.foreground,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: SpectacleColors.borderNormal),
                  ),
                ),
                child: child,
              ),
            ),
            // Over the header's first rows, and out of the way of its cells:
            // the rule is a sign, and the header under it is the grip.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(child: _SheetRule()),
            ),
          ],
        ),
      ),
    );
  }
}

/// The short rule under the sheet's top edge.
class _SheetRule extends StatelessWidget {
  const _SheetRule();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: _gripInset + _gripHeight,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          key: ValueKey('shell-grip-rule'),
          width: _gripWidth,
          height: _gripHeight,
          child: ColoredBox(color: SpectacleColors.textDisabled),
        ),
      ),
    );
  }
}

/// What the sheet holds: one host's shell at a time, and the host it holds is
/// the switcher's to change.
///
/// The shell is keyed by host id, so switching drops the state of the host
/// being left and builds the one arrived at from its `initState` — the same
/// path a fresh open takes, which is what makes the arriving host activate the
/// tab it was asked for.
class _SheetContents extends StatefulWidget {
  const _SheetContents({
    required this.host,
    this.session,
    this.command,
    this.directory,
    this.pane,
  });

  final Host host;
  final ShellSession? session;
  final String? command;
  final String? directory;
  final PaneRef? pane;

  @override
  State<_SheetContents> createState() => _SheetContentsState();
}

class _SheetContentsState extends State<_SheetContents> {
  late Host _host = widget.host;
  late ShellSession? _session = widget.session;

  void _switchTo(Host host, ShellSession? session) {
    if (host.id == _host.id) return;
    setState(() {
      _host = host;
      _session = session;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HostShellRoute(
      key: ValueKey(_host.id),
      host: _host,
      session: _session,
      // Only the host the sheet opened on is the one they were meant for:
      // switching hosts carries nothing of the directory or the agent it came
      // from.
      command: _host.id == widget.host.id ? widget.command : null,
      directory: _host.id == widget.host.id ? widget.directory : null,
      pane: _host.id == widget.host.id ? widget.pane : null,
      onSwitchHost: _switchTo,
    );
  }
}
