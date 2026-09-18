import 'package:flutter/widgets.dart';

/// The shell keeps every tab alive in an IndexedStack, so "on entry" cannot be
/// `initState` — a tab is built once and then only shown and hidden. The shell bumps
/// this counter when the subtree becomes the visible tab.
class ScreenEntry extends InheritedWidget {
  const ScreenEntry({super.key, required this.tick, required super.child});

  final int tick;

  static int? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScreenEntry>()?.tick;

  @override
  bool updateShouldNotify(ScreenEntry oldWidget) => oldWidget.tick != tick;
}
