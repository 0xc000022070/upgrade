import 'package:flutter/widgets.dart';

class HomeCardViewport extends InheritedWidget {
  const HomeCardViewport({
    super.key,
    required this.height,
    required super.child,
  });

  final double height;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeCardViewport>()?.height;

  @override
  bool updateShouldNotify(HomeCardViewport oldWidget) =>
      height != oldWidget.height;
}
