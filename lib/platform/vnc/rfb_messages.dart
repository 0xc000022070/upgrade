import 'dart:typed_data';

abstract final class Rfb {
  static const encodingRaw = 0;
  static const encodingCopyRect = 1;
  static const encodingZrle = 16;
  static const encodingDesktopSize = -223;

  static const securityInvalid = 0;
  static const securityNone = 1;
  static const securityVncAuth = 2;

  static const messageSetPixelFormat = 0;
  static const messageSetEncodings = 2;
  static const messageFramebufferUpdateRequest = 3;
  static const messageKeyEvent = 4;
  static const messagePointerEvent = 5;

  static const serverFramebufferUpdate = 0;
  static const serverSetColourMapEntries = 1;
  static const serverBell = 2;
  static const serverCutText = 3;

  static const bytesPerPixel = 4;

  /// 24 fps, wayvnc's cap on nyx. A request that cannot be answered only costs a round
  /// trip.
  static const frameInterval = Duration(microseconds: 41667);
}

class RfbPixelFormat {
  const RfbPixelFormat({
    required this.bitsPerPixel,
    required this.depth,
    required this.bigEndian,
    required this.trueColour,
    required this.redMax,
    required this.greenMax,
    required this.blueMax,
    required this.redShift,
    required this.greenShift,
    required this.blueShift,
  });

  /// In memory that is B, G, R, X per pixel, which is Flutter's `bgra8888` — so a rect
  /// lands in the framebuffer without a swizzle and the only byte this app writes itself
  /// is the alpha the server does not send.
  static const bgrx = RfbPixelFormat(
    bitsPerPixel: 32,
    depth: 24,
    bigEndian: false,
    trueColour: true,
    redMax: 255,
    greenMax: 255,
    blueMax: 255,
    redShift: 16,
    greenShift: 8,
    blueShift: 0,
  );

  final int bitsPerPixel;
  final int depth;
  final bool bigEndian;
  final bool trueColour;
  final int redMax;
  final int greenMax;
  final int blueMax;
  final int redShift;
  final int greenShift;
  final int blueShift;

  factory RfbPixelFormat.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    return RfbPixelFormat(
      bitsPerPixel: data.getUint8(0),
      depth: data.getUint8(1),
      bigEndian: data.getUint8(2) != 0,
      trueColour: data.getUint8(3) != 0,
      redMax: data.getUint16(4),
      greenMax: data.getUint16(6),
      blueMax: data.getUint16(8),
      redShift: data.getUint8(10),
      greenShift: data.getUint8(11),
      blueShift: data.getUint8(12),
    );
  }

  void writeInto(ByteData out, int offset) {
    out
      ..setUint8(offset, bitsPerPixel)
      ..setUint8(offset + 1, depth)
      ..setUint8(offset + 2, bigEndian ? 1 : 0)
      ..setUint8(offset + 3, trueColour ? 1 : 0)
      ..setUint16(offset + 4, redMax)
      ..setUint16(offset + 6, greenMax)
      ..setUint16(offset + 8, blueMax)
      ..setUint8(offset + 10, redShift)
      ..setUint8(offset + 11, greenShift)
      ..setUint8(offset + 12, blueShift)
      ..setUint8(offset + 13, 0)
      ..setUint8(offset + 14, 0)
      ..setUint8(offset + 15, 0);
  }
}

class RfbServerInit {
  const RfbServerInit({
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.name,
  });

  final int width;
  final int height;
  final RfbPixelFormat pixelFormat;
  final String name;
}

/// This client speaks 3.8 and accepts 3.3 and 3.7 by their own rules, and the rules that
/// differ are two: how the security type is chosen, and whether a `SecurityResult`
/// follows a `None` that was accepted.
enum RfbVersion {
  v3_3(3, 3),
  v3_7(3, 7),
  v3_8(3, 8);

  const RfbVersion(this.major, this.minor);

  final int major;
  final int minor;

  String get handshake => 'RFB ${_pad(major)}.${_pad(minor)}\n';

  static String _pad(int value) => value.toString().padLeft(3, '0');

  /// Anything the server names that is not one of the three reads as 3.3, the floor every
  /// RFB server understands.
  static RfbVersion negotiate(String line) {
    final match = RegExp(r'^RFB (\d{3})\.(\d{3})\n?$').firstMatch(line);
    if (match == null) return RfbVersion.v3_3;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    if (major < 3 || (major == 3 && minor < 7)) return RfbVersion.v3_3;
    if (major == 3 && minor == 7) return RfbVersion.v3_7;
    return RfbVersion.v3_8;
  }
}

abstract final class RfbClientMessages {
  static Uint8List versionReply(RfbVersion version) =>
      Uint8List.fromList(version.handshake.codeUnits);

  static Uint8List securityChoice(int type) => Uint8List.fromList([type]);

  /// Shared: the host's other viewers are never taken down.
  static Uint8List clientInit({bool shared = true}) =>
      Uint8List.fromList([shared ? 1 : 0]);

  static Uint8List setPixelFormat([
    RfbPixelFormat format = RfbPixelFormat.bgrx,
  ]) {
    final out = Uint8List(20);
    final data = ByteData.sublistView(out);
    data.setUint8(0, Rfb.messageSetPixelFormat);
    format.writeInto(data, 4);
    return out;
  }

  static Uint8List setEncodings(List<int> encodings) {
    final out = Uint8List(4 + encodings.length * 4);
    final data = ByteData.sublistView(out);
    data
      ..setUint8(0, Rfb.messageSetEncodings)
      ..setUint16(2, encodings.length);
    for (var i = 0; i < encodings.length; i++) {
      data.setInt32(4 + i * 4, encodings[i]);
    }
    return out;
  }

  static Uint8List framebufferUpdateRequest({
    required bool incremental,
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    final out = Uint8List(10);
    ByteData.sublistView(out)
      ..setUint8(0, Rfb.messageFramebufferUpdateRequest)
      ..setUint8(1, incremental ? 1 : 0)
      ..setUint16(2, x)
      ..setUint16(4, y)
      ..setUint16(6, width)
      ..setUint16(8, height);
    return out;
  }

  static Uint8List pointerEvent({
    required int buttonMask,
    required int x,
    required int y,
  }) {
    final out = Uint8List(6);
    ByteData.sublistView(out)
      ..setUint8(0, Rfb.messagePointerEvent)
      ..setUint8(1, buttonMask)
      ..setUint16(2, x)
      ..setUint16(4, y);
    return out;
  }

  static Uint8List keyEvent({required int keysym, required bool down}) {
    final out = Uint8List(8);
    ByteData.sublistView(out)
      ..setUint8(0, Rfb.messageKeyEvent)
      ..setUint8(1, down ? 1 : 0)
      ..setUint32(4, keysym);
    return out;
  }
}

/// Four of the eight are used: the two clicks and the two wheel directions, which the
/// protocol carries as buttons 4 and 5.
abstract final class RfbButtons {
  static const none = 0;
  static const left = 1;
  static const middle = 2;
  static const right = 4;
  static const wheelUp = 8;
  static const wheelDown = 16;
}
