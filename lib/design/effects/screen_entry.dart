import 'package:flutter/widgets.dart';

/// The shell keeps every tab alive in an IndexedStack, so "on entry" cannot be
/// initState — a tab is built once and then only shown and hidden. This carries
/// a counter that the shell bumps when the subtree becomes the visible tab, and
/// entry effects key off changes to it.
class ScreenEntry extends InheritedWidget {
  const ScreenEntry({super.key, required this.tick, required super.child});

  final int tick;

  static int? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScreenEntry>()?.tick;

  @override
  bool updateShouldNotify(ScreenEntry oldWidget) => oldWidget.tick != tick;
}
