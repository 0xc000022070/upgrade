import 'dart:async';
import 'dart:convert';

import 'package:flterm/flterm.dart';
import 'package:flutter/services.dart';

/// Only the standard clipboard: a primary selection, set on every highlight, would
/// overwrite what the user copied.
ClipboardWriteResult copyFromHost(ClipboardWrite write) {
  if (write.location != ClipboardLocation.standard) return .unsupported;
  for (final content in write.contents) {
    if (!content.mime.startsWith('text/plain')) continue;
    final text = utf8.decode(content.data, allowMalformed: true);
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    return .success;
  }
  return .unsupported;
}
