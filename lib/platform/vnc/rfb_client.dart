import 'dart:async';
import 'dart:typed_data';

import 'byte_reader.dart';
import 'framebuffer.dart';
import 'rfb_messages.dart';
import 'vnc_auth.dart';
import 'vnc_failure.dart';
import 'zrle.dart';

/// The RFB client, over any pair of byte streams.
///
/// It owns no socket, which is the whole reason `dart_rfb` is not used here:
/// the stream this reads is a `direct-tcpip` channel inside the host's ssh
/// connection, and in the tests it is a scripted list of bytes.
class RfbClient {
  RfbClient({
    required Stream<List<int>> incoming,
    required this._outgoing,
    this._password,
  }) : // Eagerly, in the constructor body's place: a server that sends its
       // version line the instant the channel opens must not race a reader
       // that has not subscribed yet.
       _reader = ByteReader(incoming);

  final StreamSink<List<int>> _outgoing;

  /// Offered only to a server with no `None` on its list. Null means the
  /// host row has none, which makes such a server `password needed`.
  final String? _password;
  final ByteReader _reader;
  final ZrleDecoder _zrle = ZrleDecoder();
  final StreamController<Framebuffer> _frames =
      StreamController<Framebuffer>.broadcast();

  Framebuffer? _framebuffer;
  RfbServerInit? _serverInit;
  RfbVersion? _version;
  bool _closed = false;
  Stopwatch? _sinceRequest;

  /// A `DesktopSize` invalidates every coordinate the server has sent,
  /// so the next request after one asks for the whole screen again.
  bool _needsFullUpdate = false;

  /// One event per `FramebufferUpdate`, after every rect in it has landed.
  /// "One image per update, never one per rect" is this stream: the
  /// listener turns the framebuffer into an image and asks for the next update.
  Stream<Framebuffer> get frames => _frames.stream;

  Framebuffer get framebuffer => _framebuffer!;
  RfbServerInit get serverInit => _serverInit!;
  RfbVersion get version => _version!;

  /// Version, security, `ClientInit`, `ServerInit`, then the two format
  /// messages. Returns what the server said it is showing.
  Future<RfbServerInit> handshake() async {
    final greeting = await _reader.read(12);
    final version = RfbVersion.negotiate(String.fromCharCodes(greeting));
    _version = version;
    _send(RfbClientMessages.versionReply(version));
    await _security(version);
    _send(RfbClientMessages.clientInit());
    final init = await _readServerInit();
    _serverInit = init;
    _framebuffer = Framebuffer(init.width, init.height);
    _send(RfbClientMessages.setPixelFormat());
    _send(RfbClientMessages.setEncodings());
    return init;
  }

  Future<void> _security(RfbVersion version) async {
    if (version == RfbVersion.v3_3) {
      // 3.3 does not offer a list: the server names one type and that is the
      // whole negotiation. Type 0 is a refusal, with the reason after it.
      final type = await _reader.readU32();
      if (type == Rfb.securityInvalid) {
        throw VncAuthUnsupported(await _readReason());
      }
      await _authenticate(version, _choose([type]));
      return;
    }
    final count = await _reader.readU8();
    if (count == 0) {
      // A refusal, not an empty list: the reason string follows and is the
      // best thing this app can put in the debug log.
      throw VncAuthUnsupported(await _readReason());
    }
    final type = _choose(await _reader.read(count));
    _send(RfbClientMessages.securityChoice(type));
    await _authenticate(version, type);
  }

  /// `None` whenever it is offered, whatever password the row holds; the
  /// password only where `None` is not. Neither on the list is the one case
  /// that stays `auth unsupported`.
  int _choose(List<int> types) {
    if (types.contains(Rfb.securityNone)) return Rfb.securityNone;
    final offered = 'server offers ${types.join(',')}';
    if (types.contains(Rfb.securityVncAuth)) {
      if (_password == null) throw VncPasswordNeeded(offered);
      return Rfb.securityVncAuth;
    }
    throw VncAuthUnsupported(offered);
  }

  /// The exchange the chosen type asks for, then the `SecurityResult` where
  /// one follows: after `None` only under 3.8, after a password under every
  /// version. Only 3.8 puts a reason string behind a failure.
  Future<void> _authenticate(RfbVersion version, int type) async {
    if (type == Rfb.securityNone && version != RfbVersion.v3_8) return;
    if (type == Rfb.securityVncAuth) {
      final challenge = await _reader.read(16);
      _send(vncAuthResponse(_password!, challenge));
    }
    final result = await _reader.readU32();
    if (result == 0) return;
    final reason = version == RfbVersion.v3_8
        ? await _readReason()
        : 'security result $result';
    if (type == Rfb.securityVncAuth) throw VncAuthRejected(reason);
    throw VncAuthUnsupported(reason);
  }

  Future<String> _readReason() async {
    final length = await _reader.readU32();
    if (length == 0) return '';
    return String.fromCharCodes(await _reader.read(length));
  }

  Future<RfbServerInit> _readServerInit() async {
    final width = await _reader.readU16();
    final height = await _reader.readU16();
    final format = RfbPixelFormat.parse(await _reader.read(16));
    final nameLength = await _reader.readU32();
    final name = nameLength == 0
        ? ''
        : String.fromCharCodes(await _reader.read(nameLength));
    return RfbServerInit(
      width: width,
      height: height,
      pixelFormat: format,
      name: name,
    );
  }

  /// Reads server messages until the stream ends or [close] is called.
  ///
  /// Errors land on [frames] rather than being thrown here: the caller is a
  /// widget's controller, and a reason line on the screen is what is asked
  /// for in every one of these cases.
  Future<void> run() async {
    try {
      while (!_closed) {
        await _readMessage();
      }
    } catch (error, stack) {
      if (_closed) return;
      final failure = asVncFailure(error) ?? error;
      if (!_frames.isClosed) _frames.addError(failure, stack);
    }
  }

  Future<void> _readMessage() async {
    final type = await _reader.readU8();
    switch (type) {
      case Rfb.serverFramebufferUpdate:
        await _readFramebufferUpdate();
      case Rfb.serverSetColourMapEntries:
        // Read and dropped: this client asked for true colour, so
        // a colour map is only something to stay in frame over.
        await _reader.skip(1);
        await _reader.readU16();
        final colours = await _reader.readU16();
        await _reader.skip(colours * 6);
      case Rfb.serverBell:
        break;
      case Rfb.serverCutText:
        await _reader.skip(3);
        final length = await _reader.readU32();
        await _reader.skip(length);
      default:
        // Anything else means the reader is no longer message-aligned, and
        // every byte after it would be read as garbage.
        throw VncStreamClosed('server message type $type');
    }
  }

  Future<void> _readFramebufferUpdate() async {
    await _reader.skip(1);
    final rects = await _reader.readU16();
    final target = _framebuffer!;
    for (var i = 0; i < rects; i++) {
      final x = await _reader.readU16();
      final y = await _reader.readU16();
      final width = await _reader.readU16();
      final height = await _reader.readU16();
      final encoding = await _reader.readS32();
      switch (encoding) {
        case Rfb.encodingRaw:
          final data = await _reader.read(width * height * Rfb.bytesPerPixel);
          target.blitRaw(data, x, y, width, height);
        case Rfb.encodingCopyRect:
          final sourceX = await _reader.readU16();
          final sourceY = await _reader.readU16();
          target.copyRect(
            sourceX: sourceX,
            sourceY: sourceY,
            x: x,
            y: y,
            w: width,
            h: height,
          );
        case Rfb.encodingZrle:
          final length = await _reader.readU32();
          final compressed = await _reader.read(length);
          _zrle.decodeRect(
            target,
            _zrle.inflate(compressed),
            x: x,
            y: y,
            width: width,
            height: height,
          );
        case Rfb.encodingDesktopSize:
          // The pseudo-rect carries the new geometry in its width and height
          // and no data at all.
          target.resize(width, height);
          _needsFullUpdate = true;
        default:
          throw VncStreamClosed('rect encoding $encoding');
      }
    }
    if (!_frames.isClosed) _frames.add(target);
  }

  /// One non-incremental request first, incremental after, and at most
  /// 24 a second. The caller sends the next one once it has painted the last
  /// update, so this is where the cap lives rather than in a timer.
  Future<void> requestUpdate({bool incremental = true}) async {
    final target = _framebuffer;
    if (_closed || target == null) return;
    final watch = _sinceRequest;
    if (watch != null && watch.elapsed < Rfb.frameInterval) {
      await Future<void>.delayed(Rfb.frameInterval - watch.elapsed);
      if (_closed) return;
    }
    _sinceRequest = Stopwatch()..start();
    final full = _needsFullUpdate || !incremental;
    _needsFullUpdate = false;
    _send(
      RfbClientMessages.framebufferUpdateRequest(
        incremental: !full,
        x: 0,
        y: 0,
        width: target.width,
        height: target.height,
      ),
    );
  }

  void sendPointer({required int x, required int y, required int buttonMask}) {
    final target = _framebuffer;
    if (target == null) return;
    _send(
      RfbClientMessages.pointerEvent(
        buttonMask: buttonMask,
        x: x.clamp(0, target.width - 1),
        y: y.clamp(0, target.height - 1),
      ),
    );
  }

  void sendKey(int keysym, {required bool down}) =>
      _send(RfbClientMessages.keyEvent(keysym: keysym, down: down));

  void _send(Uint8List bytes) {
    if (_closed) return;
    _outgoing.add(bytes);
  }

  /// Leaving the route closes the channel. Everything opened here is
  /// closed here, and the frame stream is shut before the channel so a rect
  /// half-read at teardown does not surface as a reason line.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _zrle.close();
    await _frames.close();
    await _reader.close();
    try {
      await _outgoing.close();
    } catch (_) {
      // A channel the far end already dropped throws on close. There is
      // nothing left to release.
    }
  }
}
