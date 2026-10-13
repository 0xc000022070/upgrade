import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract interface class AttachmentBytes {
  Future<Uint8List?> read(String relative);

  /// Leaves a file that is already there alone: the same relative path is the same
  /// picture, and the bytes are content.
  Future<void> write(String relative, Uint8List bytes);
}

class FileAttachmentBytes implements AttachmentBytes {
  const FileAttachmentBytes();

  @override
  Future<Uint8List?> read(String relative) async {
    final file = File(p.join(await _root(), relative));
    return file.existsSync() ? file.readAsBytes() : null;
  }

  @override
  Future<void> write(String relative, Uint8List bytes) async {
    final file = File(p.join(await _root(), relative));
    if (file.existsSync()) return;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<String> _root() async => (await getApplicationSupportDirectory()).path;
}
