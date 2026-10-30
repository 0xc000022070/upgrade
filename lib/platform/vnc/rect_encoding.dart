import 'package:upgrade/platform/vnc/byte_reader.dart';
import 'package:upgrade/platform/vnc/framebuffer.dart';
import 'package:upgrade/platform/vnc/rfb_messages.dart';
import 'package:upgrade/platform/vnc/zrle.dart';

class RfbRect {
  const RfbRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

/// The zlib stream is the reason this is a handle and not a byte list: ZRLE inflates
/// against one stream for the whole connection, so a rect cannot be decoded from its own
/// bytes alone.
class RectTarget {
  RectTarget({
    required this.reader,
    required this.framebuffer,
    required this.zrle,
  });

  final ByteReader reader;
  final Framebuffer framebuffer;
  final ZrleDecoder zrle;

  /// Set by the one pseudo-encoding that invalidates every coordinate the server has sent
  /// so far.
  bool resized = false;
}

/// The offer is derived from the registry, so an encoding offered with no arm to decode
/// it — which ended the stream on its first rect — is not expressible.
sealed class RectEncoding {
  const RectEncoding();

  static const all = <RectEncoding>[
    ZrleRect(),
    CopyRectRect(),
    RawRect(),
    DesktopSizeRect(),
  ];

  static final List<int> offer = [for (final encoding in all) encoding.code];

  /// Null for one this client never offered, which means the reader is no longer
  /// rect-aligned.
  static RectEncoding? of(int code) {
    for (final encoding in all) {
      if (encoding.code == code) return encoding;
    }
    return null;
  }

  int get code;

  Future<void> read(RfbRect rect, RectTarget into);
}

final class RawRect extends RectEncoding {
  const RawRect();

  @override
  int get code => Rfb.encodingRaw;

  @override
  Future<void> read(RfbRect rect, RectTarget into) async {
    final data = await into.reader.read(
      rect.width * rect.height * Rfb.bytesPerPixel,
    );
    into.framebuffer.blitRaw(data, rect.x, rect.y, rect.width, rect.height);
  }
}

final class CopyRectRect extends RectEncoding {
  const CopyRectRect();

  @override
  int get code => Rfb.encodingCopyRect;

  @override
  Future<void> read(RfbRect rect, RectTarget into) async {
    final sourceX = await into.reader.readU16();
    final sourceY = await into.reader.readU16();
    into.framebuffer.copyRect(
      sourceX: sourceX,
      sourceY: sourceY,
      x: rect.x,
      y: rect.y,
      w: rect.width,
      h: rect.height,
    );
  }
}

final class ZrleRect extends RectEncoding {
  const ZrleRect();

  @override
  int get code => Rfb.encodingZrle;

  @override
  Future<void> read(RfbRect rect, RectTarget into) async {
    final length = await into.reader.readU32();
    final compressed = await into.reader.read(length);
    into.zrle.decodeRect(
      into.framebuffer,
      into.zrle.inflate(compressed),
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    );
  }
}

final class DesktopSizeRect extends RectEncoding {
  const DesktopSizeRect();

  @override
  int get code => Rfb.encodingDesktopSize;

  @override
  Future<void> read(RfbRect rect, RectTarget into) async {
    into.framebuffer.resize(rect.width, rect.height);
    into.resized = true;
  }
}
