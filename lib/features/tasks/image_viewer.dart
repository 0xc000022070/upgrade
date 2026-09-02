import 'dart:io';

import 'package:flutter/material.dart';

import 'image_input.dart';

/// SPEC.md §39.10: black, pinch to zoom, back to close. A route rather than a
/// dialog — this is the one surface in the app that wants the whole screen,
/// and the system back gesture is the only affordance it needs.
Future<void> openImageViewer(BuildContext context, String relative) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      barrierColor: const Color(0xFF000000),
      pageBuilder: (_, _, _) => _ImageViewer(relative: relative),
    ),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.relative});

  final String relative;

  @override
  Widget build(BuildContext context) {
    final path = ImageAttachments.absolute(relative);
    return ColoredBox(
      color: const Color(0xFF000000),
      child: GestureDetector(
        // Tap closes as well as back: a viewer with no chrome has to say yes to
        // the gesture a user will try first.
        onTap: () => Navigator.of(context).maybePop(),
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: path == null
                ? const SizedBox.shrink()
                : Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
          ),
        ),
      ),
    );
  }
}
