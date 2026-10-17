import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/platform/files/phone_files.dart';

export 'package:striked/platform/files/phone_files.dart';

final phoneFilesProvider = Provider<PhoneFiles>((ref) => PhoneFiles());

sealed class ClipboardPlan {
  const ClipboardPlan();
}

final class CopyText extends ClipboardPlan {
  const CopyText(this.text);

  final String text;
}

final class CopyImage extends ClipboardPlan {
  const CopyImage(this.path, this.mime);

  final String path;
  final String mime;
}

ClipboardPlan planClipboard(List<SharedItem> items, List<String?> landed) {
  assert(items.length == landed.length);
  if (items case [SharedFile(:final mime, image: true)]) {
    return CopyImage(landed[0]!, mime);
  }
  return CopyText(
    [
      for (var i = 0; i < items.length; i++)
        switch (items[i]) {
          SharedText(:final text) => text,
          SharedFile() => landed[i]!,
        },
    ].join('\n'),
  );
}

String freeName(String name, Set<String> taken) {
  if (!taken.contains(name)) return name;
  final dot = name.lastIndexOf('.');
  final (stem, extension) = dot <= 0
      ? (name, '')
      : (name.substring(0, dot), name.substring(dot));
  for (var n = 2; ; n++) {
    final candidate = '$stem ($n)$extension';
    if (!taken.contains(candidate)) return candidate;
  }
}

String sharedTextName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'shared-${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}.txt';
}
