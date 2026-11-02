import 'package:flutter/widgets.dart';

/// Below [minRatio] (a desktop-mode monitor), lays out on a smaller canvas and draws it
/// scaled up to the window. Phone screens sit far above it.
class LegibleScale extends StatelessWidget {
  const LegibleScale({super.key, required this.child});

  static const minRatio = 1.5;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = minRatio / media.devicePixelRatio;
    if (scale <= 1) return child;
    final size = media.size / scale;
    return MediaQuery(
      data: media.copyWith(
        size: size,
        devicePixelRatio: minRatio,
        padding: media.padding / scale,
        viewPadding: media.viewPadding / scale,
        viewInsets: media.viewInsets / scale,
        systemGestureInsets: media.systemGestureInsets / scale,
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(size: size, child: child),
      ),
    );
  }
}
