import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart' show hostsProvider;
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/features/hosts/host_strip.dart';
import 'package:upgrade/features/shell/shell_header.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/features/shell/session/shell_watcher.dart';
import 'package:upgrade/features/shell/shell_status.dart';

const parkedShellBarHeight = 36.0;

typedef _Group = ({Host host, int tabs, ShellState? trouble});

ShellState? _trouble(List<ShellSession> sessions) {
  for (final session in sessions) {
    if (session.state is ShellFailed) return session.state;
  }
  for (final session in sessions) {
    if (session.state is! ShellLive) return session.state;
  }
  return null;
}

class _View {
  _View(ShellSessions store)
    : session = store.parked,
      lastHostId = store.parkedHostId {
    final session = this.session;
    if (session == null) {
      groups = const [];
      label = null;
      return;
    }
    final open = store.openHosts;
    groups = [
      for (final (host, sessions) in open)
        if (host.id == session.host.id)
          (host: host, tabs: sessions.length, trouble: _trouble(sessions)),
      for (final (host, sessions) in open)
        if (host.id != session.host.id)
          (host: host, tabs: sessions.length, trouble: _trouble(sessions)),
    ];
    final named = shellSessionLabel(session);
    label = groups.length == 1 && named != '${session.number}' ? named : null;
  }

  final ShellSession? session;
  final String? lastHostId;
  late final List<_Group> groups;
  late final String? label;

  bool same(_View other) =>
      identical(session, other.session) &&
      lastHostId == other.lastHostId &&
      label == other.label &&
      listEquals(
        [
          for (final group in groups)
            (group.host, group.tabs, group.trouble?.runtimeType),
        ],
        [
          for (final group in other.groups)
            (group.host, group.tabs, group.trouble?.runtimeType),
        ],
      );
}

/// Drawn whenever a host is registered, so it is already standing under the sheet
/// while the sheet is up and is on screen the instant the sheet has gone. Nothing
/// animates it in: the sheet going down is the only thing that should be moving.
class ParkedShellBar extends ConsumerWidget {
  const ParkedShellBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Parked(
    store: ref.watch(shellSessionsProvider),
    hosts: ref.watch(hostsProvider).valueOrNull ?? const [],
  );
}

class _Parked extends StatefulWidget {
  const _Parked({required this.store, required this.hosts});

  final ShellSessions store;
  final List<Host> hosts;

  @override
  State<_Parked> createState() => _ParkedState();
}

class _ParkedState extends State<_Parked> {
  late ShellFollower _follower;
  late _View _view;

  @override
  void initState() {
    super.initState();
    _wire();
  }

  @override
  void didUpdateWidget(_Parked oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _follower.dispose();
      _wire();
    }
  }

  @override
  void dispose() {
    _follower.dispose();
    super.dispose();
  }

  void _wire() {
    _view = _View(widget.store);
    _follower = ShellFollower(
      store: widget.store,
      watch: (store) => [
        for (final (_, sessions) in store.openHosts) ...sessions,
      ],
      onChange: _onChange,
    );
  }

  void _onChange() {
    if (!mounted) return;
    final next = _View(widget.store);
    if (_view.same(next)) return;
    setState(() => _view = next);
  }

  @override
  Widget build(BuildContext context) {
    final session = _view.session;
    if (session != null) {
      return _Bar(session: session, groups: _view.groups, label: _view.label);
    }
    final hosts = widget.hosts;
    if (hosts.isEmpty) return const SizedBox.shrink();
    final host = hosts.firstWhere(
      (h) => h.id == _view.lastHostId,
      orElse: () => hosts.first,
    );
    return _NewShellBar(store: widget.store, host: host, hosts: hosts);
  }
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.barKey,
    required this.semantics,
    required this.onTap,
    required this.child,
  });

  final Key barKey;
  final String semantics;
  final GestureTapCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semantics,
    button: true,
    child: GestureDetector(
      key: barKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.tokens.surfacePrimary,
          border: Border(
            top: BorderSide(
              color: context.tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: SizedBox(
            height: parkedShellBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.screenEdge,
              ),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

class _NewShellBar extends StatelessWidget {
  const _NewShellBar({
    required this.store,
    required this.host,
    required this.hosts,
  });

  final ShellSessions store;
  final Host host;
  final List<Host> hosts;

  @override
  Widget build(BuildContext context) {
    if (hosts.length == 1) return _bar(context, null);
    return HostMenu(
      title: 'NEW SHELL ON',
      hosts: hosts,
      current: host.id,
      itemKey: (host) => 'parked-shell-new-pick-${host.id}',
      onPick: UserIntent.onGestureWith(
        (intent, Host picked) => pickHostShell(context, store, picked, intent),
      ),
      builder: (context, controller, _) => _bar(context, controller),
    );
  }

  Widget _bar(BuildContext context, MenuController? menu) {
    final style = context.tokens.panelHeader;
    final ink = context.tokens.textPrimary;
    return _Frame(
      barKey: const ValueKey('parked-shell-new'),
      semantics: 'new shell on ${host.name}',
      onTap: menu == null
          ? UserIntent.onGesture(
              (intent) => pickHostShell(context, store, host, intent),
            )
          : menu.isOpen
          ? menu.close
          : menu.open,
      child: Row(
        children: [
          HostMark(host.system, size: IconSizes.glyph, color: ink),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text(
              host.name.toUpperCase(),
              key: ValueKey('parked-shell-new-host-${host.id}'),
              style: style.copyWith(color: ink),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(
            'NEW SHELL',
            key: const ValueKey('parked-shell-verb'),
            style: style.copyWith(color: context.tokens.accent),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.session, required this.groups, this.label});

  final ShellSession session;

  final List<_Group> groups;

  final String? label;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    return _Frame(
      barKey: const ValueKey('parked-shell'),
      semantics: [
        for (final group in groups)
          '${group.host.name} ${group.tabs} ${group.tabs == 1 ? 'shell' : 'shells'}',
      ].join(', '),
      // The session, not the host: the bar lands on the tab the strip will show in
      // front.
      onTap: UserIntent.onGesture(
        (intent) => openHostShell(
          context,
          session.host,
          intent: intent,
          session: session,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final measure = _measurer(context);
          const long = 'TAP TO RESUME';
          final verb =
              _GroupCell.widthOf(groups.first, measure) +
                      Spacing.md +
                      measure(long) <=
                  constraints.maxWidth
              ? long
              : 'RESUME';
          return Row(
            children: [
              Expanded(
                child: label == null
                    ? _Groups(groups: groups)
                    : Row(
                        children: [
                          Flexible(
                            child: _GroupCell(
                              group: groups.single,
                              front: true,
                            ),
                          ),
                          const SizedBox(width: Spacing.md),
                          Expanded(
                            child: Text(
                              label,
                              key: const ValueKey('parked-shell-label'),
                              style: context.tokens.rowKicker,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: Spacing.md),
              Text(
                verb,
                key: const ValueKey('parked-shell-verb'),
                style: context.tokens.panelHeader.copyWith(
                  color: context.tokens.accent,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

double Function(String) _measurer(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final style = context.tokens.panelHeader;
  return (text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  };
}

class _Groups extends StatelessWidget {
  const _Groups({required this.groups});

  final List<_Group> groups;

  @override
  Widget build(BuildContext context) {
    final style = context.tokens.panelHeader;
    final measure = _measurer(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth;
        // Room is kept for the short count; the long one is drawn only if it fits too.
        var shown = 1;
        var used = _GroupCell.widthOf(groups.first, measure);
        while (shown < groups.length) {
          final next = used + _gap + _GroupCell.widthOf(groups[shown], measure);
          final after = groups.length - shown - 1;
          final reserve = after == 0 ? 0.0 : _gap + measure('+$after');
          if (next + reserve > room) break;
          used = next;
          shown++;
        }
        final left = groups.length - shown;
        final long = '+$left HOSTS';
        final short = '+$left';
        // The front name gives way before the short count does.
        final squeezed =
            used - _GroupCell.nameWidth(groups.first, measure) + _gap;
        final tail = left == 0
            ? null
            : used + _gap + measure(long) <= room
            ? long
            : squeezed + measure(short) <= room
            ? short
            : null;
        return Row(
          children: [
            Flexible(child: _GroupCell(group: groups.first, front: true)),
            for (final group in groups.skip(1).take(shown - 1)) ...[
              const SizedBox(width: _gap),
              _GroupCell(group: group, front: false),
            ],
            if (tail != null) ...[
              const SizedBox(width: _gap),
              Text(
                tail,
                key: const ValueKey('parked-shell-more'),
                style: style.copyWith(color: context.tokens.textMuted),
                maxLines: 1,
                softWrap: false,
              ),
            ],
          ],
        );
      },
    );
  }
}

const _gap = Spacing.xl;

class _GroupCell extends StatelessWidget {
  const _GroupCell({required this.group, required this.front});

  final _Group group;
  final bool front;

  static double nameWidth(_Group group, double Function(String) measure) {
    final name = measure(group.host.name.toUpperCase());
    return name < hostGroupMaxWidth ? name : hostGroupMaxWidth;
  }

  static double widthOf(_Group group, double Function(String) measure) {
    return IconSizes.glyph +
        Spacing.md +
        nameWidth(group, measure) +
        Spacing.md +
        measure('${group.tabs}') +
        (group.trouble == null ? 0 : Spacing.md + shellDotSize);
  }

  @override
  Widget build(BuildContext context) {
    final ink = front ? context.tokens.textPrimary : context.tokens.textMuted;
    final style = context.tokens.panelHeader;
    final trouble = group.trouble;
    return Row(
      key: ValueKey('parked-shell-host-${group.host.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        HostMark(group.host.system, size: IconSizes.glyph, color: ink),
        const SizedBox(width: Spacing.md),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: hostGroupMaxWidth),
            child: Text(
              group.host.name.toUpperCase(),
              style: style.copyWith(color: ink),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: Spacing.md),
        Text(
          '${group.tabs}',
          style: style.copyWith(color: context.tokens.textMuted),
        ),
        if (trouble != null) ...[
          const SizedBox(width: Spacing.md),
          ShellStateDot(state: trouble),
        ],
      ],
    );
  }
}
