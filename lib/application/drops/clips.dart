import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

enum ClipSource { screen, photo }

class Clip {
  Clip({
    required this.id,
    required this.file,
    required this.bytes,
    required this.source,
    required this.takenAt,
    this.width,
    this.height,
    this.hostName,
  });

  final String id;
  final File file;
  final int bytes;
  final ClipSource source;
  final DateTime takenAt;
  final int? width;
  final int? height;

  final String? hostName;

  String get fileName => p.basename(file.path);

  String get sizeLabel =>
      width == null || height == null ? '' : '$width×$height';
}

/// The bytes live under the cache directory, not in memory: the gallery picker is
/// another activity and Android is free to kill this process behind it.
class ClipStore extends ChangeNotifier {
  ClipStore(this.directory);

  static const directoryName = 'clips';

  static const maxClips = 8;
  static const maxBytes = 24 * 1024 * 1024;

  static const _uuid = Uuid();

  final Directory directory;
  final _clips = <Clip>[];

  List<Clip> get clips => List.unmodifiable(_clips.reversed);
  int get count => _clips.length;
  int get totalBytes => _clips.fold(0, (sum, clip) => sum + clip.bytes);

  static Future<ClipStore> open() async {
    final cache = await getTemporaryDirectory();
    final directory = Directory(p.join(cache.path, directoryName));
    if (directory.existsSync()) await directory.delete(recursive: true);
    return ClipStore(directory);
  }

  Future<Clip> add(
    Uint8List png, {
    required ClipSource source,
    String? hostName,
  }) async {
    if (!directory.existsSync()) await directory.create(recursive: true);
    final id = _uuid.v7();
    final file = File(p.join(directory.path, pngNameFor(id)));
    await file.writeAsBytes(png, flush: true);
    final size = pngSize(png);
    final clip = Clip(
      id: id,
      file: file,
      bytes: png.length,
      source: source,
      takenAt: DateTime.now(),
      width: size?.width,
      height: size?.height,
      hostName: hostName,
    );
    _clips.add(clip);
    await _trim();
    notifyListeners();
    return clip;
  }

  Future<void> remove(Clip clip) async {
    if (!_clips.remove(clip)) return;
    notifyListeners();
    await _delete(clip);
  }

  /// The newest is never dropped, even when it alone is over the byte budget.
  Future<void> _trim() async {
    while (_clips.length > 1 &&
        (_clips.length > maxClips || totalBytes > maxBytes)) {
      await _delete(_clips.removeAt(0));
    }
  }

  Future<void> _delete(Clip clip) async {
    try {
      if (clip.file.existsSync()) await clip.file.delete();
    } on FileSystemException {
      // The clip is gone from the list either way.
    }
  }
}

({int width, int height})? pngSize(List<int> head) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (head.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (head[i] != signature[i]) return null;
  }
  int be32(int at) =>
      (head[at] << 24) |
      (head[at + 1] << 16) |
      (head[at + 2] << 8) |
      head[at + 3];
  return (width: be32(16), height: be32(20));
}

final clipStoreProvider = Provider<ClipStore>((ref) {
  ref.keepAlive();
  return ClipStore(
    Directory(p.join(Directory.systemTemp.path, 'striked-clips')),
  );
});

String pngNameFor(String id) => '$id.png';

String freshPngName() => pngNameFor(const Uuid().v7());
