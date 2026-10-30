import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/drops/attachment_files.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/design/tokens.dart';

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
