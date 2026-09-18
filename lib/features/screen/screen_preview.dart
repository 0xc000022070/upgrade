import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../platform/vnc/framebuffer.dart';
import '../../platform/vnc/rfb_messages.dart';
import 'screen_transform.dart';

/// Small enough that a blur of sigma 2 over it destroys the text and leaves the layout,
/// and that one file per host stays a few tens of kilobytes.
const previewWidth = 320;

const previewInterval = Duration(seconds: 30);

class PreviewFrame {
  const PreviewFrame({
    required this.width,
    required this.height,
    required this.rgb,
  });

  final int width;
  final int height;
  final Uint8List rgb;
}

/// Area averaging: every target pixel is the mean of the source box it covers, which is
/// what keeps a downscaled terminal readable as a layout instead of a field of aliased
/// single pixels.
PreviewFrame downsampleFrame(
  Framebuffer framebuffer, {
  int width = previewWidth,
}) {
  final sourceWidth = framebuffer.width;
  final sourceHeight = framebuffer.height;
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    return PreviewFrame(width: 0, height: 0, rgb: Uint8List(0));
  }
  // A frame already narrower than the target is stored as it is: upscaling would cost
  // bytes and add nothing the blur does not destroy anyway.
  final targetWidth = math.min(sourceWidth, width);
  final targetHeight = math.max(
    1,
    (sourceHeight * targetWidth / sourceWidth).round(),
  );
  final bytesPerPixel = framebuffer.stride ~/ sourceWidth;
  final pixels = framebuffer.pixels;
  final rgb = Uint8List(targetWidth * targetHeight * 3);
  var at = 0;
  for (var y = 0; y < targetHeight; y++) {
    final top = y * sourceHeight ~/ targetHeight;
    final bottom = math.max(top + 1, (y + 1) * sourceHeight ~/ targetHeight);
    for (var x = 0; x < targetWidth; x++) {
      final left = x * sourceWidth ~/ targetWidth;
      final right = math.max(left + 1, (x + 1) * sourceWidth ~/ targetWidth);
      var blue = 0;
      var green = 0;
      var red = 0;
      for (var sourceY = top; sourceY < bottom; sourceY++) {
        var offset = framebuffer.offsetOf(left, sourceY);
        for (var sourceX = left; sourceX < right; sourceX++) {
          blue += pixels[offset];
          green += pixels[offset + 1];
          red += pixels[offset + 2];
          offset += bytesPerPixel;
        }
      }
      final count = (right - left) * (bottom - top);
      rgb[at++] = red ~/ count;
      rgb[at++] = green ~/ count;
      rgb[at++] = blue ~/ count;
    }
  }
  return PreviewFrame(width: targetWidth, height: targetHeight, rgb: rgb);
}

/// No scaling in either direction: what the user drew a box around is what the agent
/// gets, and a terminal's text is the first thing resampling destroys.
PreviewFrame cropFrame(Framebuffer framebuffer, CropRect rect) {
  final left = rect.left.clamp(0, framebuffer.width);
  final top = rect.top.clamp(0, framebuffer.height);
  final width = math.min(rect.width, framebuffer.width - left);
  final height = math.min(rect.height, framebuffer.height - top);
  if (width <= 0 || height <= 0) {
    return PreviewFrame(width: 0, height: 0, rgb: Uint8List(0));
  }
  final pixels = framebuffer.pixels;
  final rgb = Uint8List(width * height * 3);
  var at = 0;
  for (var y = top; y < top + height; y++) {
    var offset = framebuffer.offsetOf(left, y);
    for (var x = 0; x < width; x++) {
      rgb[at++] = pixels[offset + 2];
      rgb[at++] = pixels[offset + 1];
      rgb[at++] = pixels[offset];
      offset += Rfb.bytesPerPixel;
    }
  }
  return PreviewFrame(width: width, height: height, rgb: rgb);
}

/// Written by hand rather than through `dart:ui`, which can only encode an image it has
/// already uploaded to the GPU: the frame arrives as bytes, the tile wants bytes back,
/// and a round trip through the engine would put the writer on the platform thread and
/// out of reach of a plain unit test.
Uint8List encodePng(PreviewFrame frame) {
  final stride = frame.width * 3;
  final raw = Uint8List(frame.height * (stride + 1));
  for (var y = 0; y < frame.height; y++) {
    final row = y * (stride + 1);
    // Filter 0: the rows go in unfiltered and deflate does the work.
    raw[row] = 0;
    raw.setRange(row + 1, row + 1 + stride, frame.rgb, y * stride);
  }
  final header = BytesBuilder()
    ..add(_be32(frame.width))
    ..add(_be32(frame.height))
    // 8 bits per sample, truecolour, deflate, no filtering, no interlace.
    ..add(const [8, 2, 0, 0, 0]);
  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', header.takeBytes()))
        ..add(_chunk('IDAT', ZLibEncoder().convert(raw)))
        ..add(_chunk('IEND', Uint8List(0))))
      .takeBytes();
}

/// Read off the header rather than by decoding: the tile needs the aspect before it has
/// an image to measure.
({int width, int height})? readPngSize(List<int> head) {
  // Signature 8 bytes, then the IHDR chunk's length and name, then the two dimensions.
  // Nothing before byte 24 varies between PNGs this writer makes.
  if (head.length < 24) return null;
  int be32(int at) =>
      (head[at] << 24) |
      (head[at + 1] << 16) |
      (head[at + 2] << 8) |
      head[at + 3];
  return (width: be32(16), height: be32(20));
}

Uint8List _chunk(String type, List<int> data) {
  final name = ascii.encode(type);
  final body = Uint8List(name.length + data.length)
    ..setRange(0, name.length, name)
    ..setRange(name.length, name.length + data.length, data);
  return (BytesBuilder()
        ..add(_be32(data.length))
        ..add(body)
        ..add(_be32(_crc32(body))))
      .takeBytes();
}

Uint8List _be32(int value) => Uint8List(4)
  ..[0] = (value >> 24) & 0xFF
  ..[1] = (value >> 16) & 0xFF
  ..[2] = (value >> 8) & 0xFF
  ..[3] = value & 0xFF;

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// The bytes are carried rather than the path alone because the file is replaced in place
/// — an image keyed on the path would go on drawing the frame before this one.
class StoredPreview {
  const StoredPreview({
    required this.file,
    required this.bytes,
    required this.width,
    required this.height,
  });

  final File file;
  final Uint8List bytes;
  final int width;
  final int height;

  double get aspect => height == 0 ? 16 / 9 : width / height;
}

class ScreenPreviews {
  ScreenPreviews(this.directory);

  static const directoryName = 'screens';

  final _changes = StreamController<String>.broadcast();

  /// A tile reads its file once and the path never changes, so without this it would keep
  /// drawing whatever was there when it was first built.
  Stream<String> get changes => _changes.stream;

  static Future<ScreenPreviews> open() async {
    final support = await getApplicationSupportDirectory();
    return ScreenPreviews(Directory(p.join(support.path, directoryName)));
  }

  final Directory directory;

  File fileFor(String hostId) => File(p.join(directory.path, '$hostId.png'));

  Future<File> write(String hostId, Framebuffer framebuffer) async {
    final bytes = encodePng(downsampleFrame(framebuffer));
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    final file = await fileFor(hostId).writeAsBytes(bytes, flush: true);
    _changes.add(hostId);
    return file;
  }

  StoredPreview? read(String hostId) {
    final file = fileFor(hostId);
    if (!file.existsSync()) return null;
    final handle = file.openSync();
    final Uint8List head;
    try {
      head = handle.readSync(24);
    } finally {
      handle.closeSync();
    }
    final size = readPngSize(head);
    if (size == null) return null;
    return StoredPreview(
      file: file,
      bytes: file.readAsBytesSync(),
      width: size.width,
      height: size.height,
    );
  }

  Future<void> delete(String hostId) async {
    final file = fileFor(hostId);
    if (file.existsSync()) await file.delete();
    _changes.add(hostId);
  }

  void dispose() => _changes.close();
}

final screenPreviewsProvider = FutureProvider<ScreenPreviews>((ref) async {
  final previews = await ScreenPreviews.open();
  ref.onDispose(previews.dispose);
  return previews;
});

final screenPreviewProvider = FutureProvider.family<StoredPreview?, String>((
  ref,
  hostId,
) async {
  final previews = await ref.watch(screenPreviewsProvider.future);
  // Subscribed before the read, so a frame written between the two is not the one frame
  // this provider never hears about.
  final changes = previews.changes
      .where((changed) => changed == hostId)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  return previews.read(hostId);
});
