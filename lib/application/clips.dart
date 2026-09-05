import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Where a clip came from: a box drawn over a host's screen, or the gallery.
enum ClipSource { screen, photo }

/// One held image: a PNG in the cache and its pixel size. Nothing about it
/// reaches the database.
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

  /// The host whose screen this was cut from; null for a photo.
  final String? hostName;

  String get fileName => p.basename(file.path);

  /// `1280×720`, or nothing when the header could not be read.
  String get sizeLabel =>
      width == null || height == null ? '' : '$width×$height';
}

/// Every clip of this run, newest first, on a budget.
///
/// The bytes live under the platform's cache directory rather than in memory:
/// the gallery picker is another activity, and Android is free to kill this
/// process behind it, which is exactly the crop-then-attach flow a clip is
/// for. The directory is emptied at boot, so nothing outlives the run; RAM
/// holds the records and whatever thumbnails the tray has drawn.
class ClipStore extends ChangeNotifier {
  ClipStore(this.directory);

  static const directoryName = 'clips';

  /// Eight clips and twenty-four megabytes, whichever runs out first. Past
  /// either the oldest goes, unasked: a tray is a handful, not an archive.
  static const maxClips = 8;
  static const maxBytes = 24 * 1024 * 1024;

  static const _uuid = Uuid();

  final Directory directory;
  final _clips = <Clip>[];

  List<Clip> get clips => List.unmodifiable(_clips.reversed);
  int get count => _clips.length;
  int get totalBytes => _clips.fold(0, (sum, clip) => sum + clip.bytes);

  /// The store under the cache directory, emptied of whatever the last run
  /// left behind before anything is read from it.
  static Future<ClipStore> open() async {
    final cache = await getTemporaryDirectory();
    final directory = Directory(p.join(cache.path, directoryName));
    if (directory.existsSync()) await directory.delete(recursive: true);
    return ClipStore(directory);
  }

  /// Keeps one PNG. The size is read off its header, never by decoding it.
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

  /// Oldest first until both budgets hold. The newest is never dropped: a
  /// clip that on its own is over the byte budget is still the one the user
  /// just made.
  Future<void> _trim() async {
    while (_clips.length > 1 &&
        (_clips.length > maxClips || totalBytes > maxBytes)) {
      await _delete(_clips.removeAt(0));
    }
  }

  /// Best effort: the record is gone whether or not the file was.
  Future<void> _delete(Clip clip) async {
    try {
      if (clip.file.existsSync()) await clip.file.delete();
    } on FileSystemException {
      // Already gone, or the cache was cleared under the app.
    }
  }
}

/// The dimensions in a PNG's IHDR chunk, which every PNG carries at the same
/// offset, or null for bytes that are not one.
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

/// The store, for the app's lifetime. Boot overrides it with one under the
/// platform's cache directory; without that override — a widget test — it is
/// under the system temp, which is the same thing on a machine with no
/// platform.
final clipStoreProvider = Provider<ClipStore>((ref) {
  ref.keepAlive();
  return ClipStore(
    Directory(p.join(Directory.systemTemp.path, 'spectacle-clips')),
  );
});

/// The name a picture lands under, here and on a host: an id with no
/// character a gate or a shell would read into.
String pngNameFor(String id) => '$id.png';

String freshPngName() => pngNameFor(const Uuid().v7());
