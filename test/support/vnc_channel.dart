import 'dart:async';
import 'dart:typed_data';

/// A stand-in for §39.32's `direct-tcpip` channel: bytes in one end, bytes out
/// the other, both readable by a test.
///
/// The client under test is the real one — only the ssh channel is scripted,
/// which is the boundary the app cannot cross without a host.
class FakeVncChannel {
  FakeVncChannel() {
    _outgoing.stream.listen(_sent.add);
  }

  final StreamController<List<int>> _incoming = StreamController<List<int>>();
  final StreamController<List<int>> _outgoing = StreamController<List<int>>();
  final BytesBuilder _sent = BytesBuilder();

  Stream<List<int>> get stream => _incoming.stream;
  StreamSink<List<int>> get sink => _outgoing.sink;

  /// Everything the client has written so far, in order.
  Uint8List get sent => Uint8List.fromList(_sent.toBytes());

  void feed(List<int> bytes) => _incoming.add(bytes);

  /// The far end going away: §39.32's `stream closed`.
  Future<void> endStream() => _incoming.close();

  Future<void> dispose() async {
    if (!_incoming.isClosed) await _incoming.close();
    if (!_outgoing.isClosed) await _outgoing.close();
  }
}

/// The bytes a 3.8 server sends before the first framebuffer update.
///
/// [securityTypes] is what the server offers; §39.32 takes `None` (1) and
/// nothing else.
List<int> serverHandshake({
  String version = 'RFB 003.008\n',
  List<int> securityTypes = const [1],
  int? securityResult = 0,
  int width = 1920,
  int height = 1080,
  String name = 'nyx',
}) {
  final out = <int>[...version.codeUnits];
  if (version == 'RFB 003.003\n') {
    // 3.3 names one type in a word, and does not offer a list.
    out.addAll(_u32(securityTypes.isEmpty ? 0 : securityTypes.first));
  } else {
    out
      ..add(securityTypes.length)
      ..addAll(securityTypes);
    if (version == 'RFB 003.008\n' && securityResult != null) {
      out.addAll(_u32(securityResult));
    }
  }
  out
    ..addAll(_u16(width))
    ..addAll(_u16(height))
    ..addAll(serverPixelFormat())
    ..addAll(_u32(name.length))
    ..addAll(name.codeUnits);
  return out;
}

/// The 16-byte `PIXEL_FORMAT` a wayvnc-shaped server reports: 32 bpp, depth 24,
/// little-endian BGRX.
List<int> serverPixelFormat() => [
  32,
  24,
  0,
  1,
  ..._u16(255),
  ..._u16(255),
  ..._u16(255),
  16,
  8,
  0,
  0,
  0,
  0,
];

/// A `FramebufferUpdate` header minus its message type, which the caller
/// writes so a test reads as the byte stream it is: padding, then the rect
/// count.
List<int> updateHeader(int rects) => [0, ..._u16(rects)];

List<int> rectHeader({
  required int x,
  required int y,
  required int width,
  required int height,
  required int encoding,
}) => [
  ..._u16(x),
  ..._u16(y),
  ..._u16(width),
  ..._u16(height),
  ..._s32(encoding),
];

List<int> _u16(int value) => [value >> 8 & 0xFF, value & 0xFF];

List<int> _u32(int value) => [
  value >> 24 & 0xFF,
  value >> 16 & 0xFF,
  value >> 8 & 0xFF,
  value & 0xFF,
];

List<int> _s32(int value) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setInt32(0, value);
  return out;
}

List<int> u16(int value) => _u16(value);
List<int> u32(int value) => _u32(value);
