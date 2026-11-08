import 'package:flutter/widgets.dart';

import 'package:upgrade/design/motion.dart';

/// Deliberately deeper than `tokens.scrim`.
const sheetScrim = Color(0xCC000000);

/// What a route's content inherits from the context that opens it: the dialog route sits
/// under the navigator, outside any scope the opener lives in.
class SheetScope extends InheritedWidget {
  const SheetScope({super.key, required this.inherit, required super.child});

  final Widget Function(BuildContext opener, Widget content) inherit;

  static Widget wrap(BuildContext opener, Widget content) {
    final scope = opener.getInheritedWidgetOfExactType<SheetScope>();
    return scope == null ? content : scope.inherit(opener, content);
  }

  @override
  bool updateShouldNotify(SheetScope old) => inherit != old.inherit;
}

Future<T?> showSheetRoute<T>(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  // The nearest navigator rather than the root: the app has one, so they are the same
  // there, and a host that nests the app's widgets keeps the sheet under its theme.
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: 'DISMISS $title',
    barrierColor: sheetScrim,
    transitionDuration: Motion.fast,
    pageBuilder: (context, animation, secondary) => child,
    transitionBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Motion.enter)),
          child: child,
        ),
      );
    },
  );
}
