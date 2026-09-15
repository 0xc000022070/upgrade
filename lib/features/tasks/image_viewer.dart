import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/attachment_files.dart';
import '../../application/native_plugins.dart';
import '../../design/tokens.dart';

/// Black, pinch to zoom, back to close. A route rather than a
/// dialog — this is the one surface in the app that wants the whole screen,
/// and the system back gesture is the only affordance it needs.
Future<void> openImageViewer(BuildContext context, String relative) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      barrierColor: context.tokens.mediaBackdrop,
      pageBuilder: (_, _, _) => inheritPluginScope(
        context,
        _ImageViewer(relative: relative),
        surface: 'item.detail',
      ),
    ),
  );
}

class _ImageViewer extends ConsumerWidget {
  const _ImageViewer({required this.relative});

  final String relative;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.read(attachmentFilesProvider).absolute(relative);
    return ColoredBox(
      color: context.tokens.mediaBackdrop,
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
