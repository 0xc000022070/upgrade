import 'byte_reader.dart';
import 'framebuffer.dart';
import 'rfb_messages.dart';
import 'zrle.dart';

/// A rect's header: where the rect goes and how big it is. Read before the
/// encoding number, because the encoding is what decides whether anything
/// follows it at all.
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

/// Everything a rect decoder needs that outlives the rect.
///
/// The zlib stream is the reason this is a handle and not a byte list: ZRLE
/// inflates against one stream for the whole connection, so a rect cannot be
/// decoded from its own bytes alone.
class RectTarget {
  RectTarget({
    required this.reader,
    required this.framebuffer,
    required this.zrle,
  });

  final ByteReader reader;
  final Framebuffer framebuffer;
  final ZrleDecoder zrle;

  /// Set by the one pseudo-encoding that invalidates every coordinate the
  /// server has sent so far. The read loop asks for the whole screen on the
  /// next request when it sees this.
  bool resized = false;
}

/// One rect encoding: its wire number, and how to read a rect of it.
///
/// The client used to keep two lists of these — the preference order it sent
/// in `SetEncodings` and the arms of the switch that decoded a rect — with
/// nothing tying them together. Offering one that had no arm ended the stream
/// on the first rect of it; writing an arm for one that was never offered was
/// code the server could not reach. Here the offer is derived from the
/// registry, so neither is expressible.
sealed class RectEncoding {
  const RectEncoding();

  /// Every encoding this client reads, most wanted first.
  static const all = <RectEncoding>[
    ZrleRect(),
    CopyRectRect(),
    RawRect(),
    DesktopSizeRect(),
  ];

  /// The `SetEncodings` list, in preference order.
  static final List<int> offer = [for (final encoding in all) encoding.code];

  /// The encoding a rect header named, or null for one this client never
  /// offered — which means the reader is no longer rect-aligned.
  static RectEncoding? of(int code) {
    for (final encoding in all) {
      if (encoding.code == code) return encoding;
    }
    return null;
  }

  /// The wire number, in a rect header and in `SetEncodings` alike.
  int get code;

  /// Reads the rest of the rect off [into]'s reader and lands it.
  Future<void> read(RfbRect rect, RectTarget into);
}

/// Uncompressed pixels in the format `SetPixelFormat` asked for. The one
/// encoding every RFB server has.
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

/// A region already on screen, named by where it was rather than sent again.
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

/// Run-length tiles over the connection's zlib stream: what wayvnc sends for
/// everything that is not a window drag.
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

/// Not a rect: the server's new geometry, carried in the header's own width
/// and height with no data behind it.
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
