import 'package:flutter/widgets.dart';

import 'package:upgrade/features/shell/session/shell_sessions.dart';

/// The store says which tabs exist, each session says what it is showing and what state
/// it is in. Anything that reads a tab's state through the store needs both, and the
/// subscription on the tabs has to move as the set does — a tab that has gone is let go
/// of, one that was already followed is left alone.
class ShellFollower {
  ShellFollower({
    required this.store,
    required this.watch,
    required this.onChange,
  }) {
    store.addListener(_onStore);
    _follow();
  }

  final ShellSessions store;

  final List<ShellSession> Function(ShellSessions store) watch;

  final VoidCallback onChange;

  var _watched = const <ShellSession>[];

  void _onStore() {
    _follow();
    onChange();
  }

  void _follow() {
    final next = watch(store);
    for (final session in _watched) {
      if (!next.contains(session)) session.removeListener(onChange);
    }
    for (final session in next) {
      if (!_watched.contains(session)) session.addListener(onChange);
    }
    _watched = List.of(next);
  }

  void dispose() {
    store.removeListener(_onStore);
    for (final session in _watched) {
      session.removeListener(onChange);
    }
    _watched = const [];
  }
}

class ShellWatcher extends StatefulWidget {
  const ShellWatcher({
    super.key,
    required this.store,
    required this.watch,
    required this.builder,
  });

  final ShellSessions store;

  final List<ShellSession> Function(ShellSessions store) watch;

  final WidgetBuilder builder;

  @override
  State<ShellWatcher> createState() => _ShellWatcherState();
}

class _ShellWatcherState extends State<ShellWatcher> {
  late ShellFollower _follower;

  @override
  void initState() {
    super.initState();
    _follower = _wire();
  }

  @override
  void didUpdateWidget(ShellWatcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _follower.dispose();
      _follower = _wire();
    }
  }

  @override
  void dispose() {
    _follower.dispose();
    super.dispose();
  }

  ShellFollower _wire() => ShellFollower(
    store: widget.store,
    watch: widget.watch,
    onChange: _onChange,
  );

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
