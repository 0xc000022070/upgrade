import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import '../../data/repositories/host_repository.dart';
import '../../platform/host_keys.dart';
import '../../platform/vnc/framebuffer.dart';
import '../../platform/vnc/keysyms.dart';
import '../../platform/vnc/rfb_messages.dart';
import '../../platform/vnc/vnc_failure.dart';
import '../../platform/vnc/vnc_tunnel.dart';

/// The three states, which are the whole of what the breadcrumb's right-hand
/// side can say.
enum ScreenPhase { connecting, live, failed }

/// One update's worth of pixels as an image.
///
/// `bgra8888` is the format the framebuffer is already in, so this is an upload
/// and not a conversion — which is the whole reason the server is asked for
/// that pixel format. Top level so the measurement in the evidence times the
/// path the route runs and not a copy of it.
Future<ui.Image> decodeFramebuffer(Framebuffer framebuffer) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(framebuffer.pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: framebuffer.width,
    height: framebuffer.height,
    pixelFormat: ui.PixelFormat.bgra8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

/// One host's screen: the connection, the image on it, and the events going
/// back.
///
/// A [ChangeNotifier] rather than a Riverpod notifier because it is bound to a
/// route's lifetime exactly — the channel and the ssh connection close when
/// the route goes, and a provider that outlived the widget by a frame would
/// hold both open.
class HostScreenController extends ChangeNotifier {
  HostScreenController({
    required this.host,
    required this._readPrivateKey,
    this.pinHostKey,
    this.prompt,
    VncOpener? open,
  }) : _open = open ?? const VncTunnel().open;

  final Host host;
  final Future<String?> Function(String keyId) _readPrivateKey;

  /// Writes a key the user trusted, and asks them about one nobody has. Both
  /// null in a test, and a null [prompt] is what makes an unattended dial
  /// refuse an unpinned host rather than hang on a sheet nobody can see.
  final Future<void> Function(String hostId, PinnedHostKey key)? pinHostKey;
  final HostKeyPrompt? prompt;

  final VncOpener _open;

  /// The key trusted during this visit. [host] was read before the sheet
  /// answered, so without this a `RETRY` would ask about the same key again.
  PinnedHostKey? _pinned;

  VncConnection? _connection;
  StreamSubscription<Framebuffer>? _frames;

  ScreenPhase _phase = ScreenPhase.connecting;
  String? _reason;
  ui.Image? _image;
  Framebuffer? _lastFramebuffer;
  Size _framebufferSize = Size.zero;
  Duration? _lastFrame;
  bool _disposed = false;

  /// Guards against a `RETRY` tapped while the previous attempt is still in
  /// flight, which would leave two ssh connections open against one host.
  int _attempt = 0;

  ScreenPhase get phase => _phase;

  /// The reason line, already worded: `nyx unreachable`, `key rejected`,
  /// `tunnel refused`, `auth unsupported`, `stream closed`.
  String? get reason => _reason;

  ui.Image? get image => _image;
  Size get framebufferSize => _framebufferSize;

  /// The last update that became an image, which is what the route stores as
  /// this host's preview. The decoded one rather than the newest arrival: a
  /// frame that failed to decode was never on screen, so it is not what the
  /// tile should show.
  Framebuffer? get lastFramebuffer => _lastFramebuffer;

  /// How long the last update took to turn into an image. Measured on a 1080p
  /// update and kept on the controller, so the number in the evidence comes off
  /// a running app rather than a benchmark written beside it.
  Duration? get lastFrameTime => _lastFrame;

  Future<void> connect() async {
    final attempt = ++_attempt;
    _phase = ScreenPhase.connecting;
    _reason = null;
    notifyListeners();

    final privateKey = await _readPrivateKey(host.keyId);
    if (_disposed || attempt != _attempt) return;
    if (privateKey == null) {
      // The host names a key whose secret is gone from the keystore. There is
      // nothing to offer the host, which from here is a rejected key.
      _fail(VncKeyRejected('no private key stored for ${host.keyId}'));
      return;
    }

    try {
      final connection = await _open(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier(
          pinned: _pinned ?? host.hostKey,
          prompt: prompt,
          pin: (key) async {
            _pinned = key;
            await pinHostKey?.call(host.id, key);
          },
        ),
      );
      if (_disposed || attempt != _attempt) {
        await connection.close();
        return;
      }
      _connection = connection;
      _framebufferSize = Size(
        connection.serverInit.width.toDouble(),
        connection.serverInit.height.toDouble(),
      );
      _frames = connection.rfb.frames.listen(
        _onFrame,
        onError: (Object error) => _fail(error),
      );
      _phase = ScreenPhase.live;
      notifyListeners();
      // The pump runs unawaited: it lives as long as the connection, and every
      // way it can end already reports itself through [frames].
      unawaited(connection.rfb.run());
      // One non-incremental request first.
      await connection.rfb.requestUpdate(incremental: false);
    } catch (error) {
      if (_disposed || attempt != _attempt) return;
      _fail(error);
    }
  }

  /// The reason line's `RETRY`. There is no reconnect loop; this is the only
  /// way back.
  Future<void> retry() async {
    await _teardown();
    if (_disposed) return;
    await connect();
  }

  Future<void> _onFrame(Framebuffer framebuffer) async {
    final connection = _connection;
    if (_disposed || connection == null) return;
    final watch = Stopwatch()..start();
    final image = await _decode(framebuffer);
    watch.stop();
    if (_disposed || connection != _connection) {
      image?.dispose();
      return;
    }
    if (image != null) {
      // The previous frame's 8 MB goes back the moment the next one is ready,
      // rather than when the next GC gets to it.
      _image?.dispose();
      _image = image;
      _lastFramebuffer = framebuffer;
      _lastFrame = watch.elapsed;
      _framebufferSize = Size(
        framebuffer.width.toDouble(),
        framebuffer.height.toDouble(),
      );
      notifyListeners();
      _log(
        '${framebuffer.width}x${framebuffer.height} in '
        '${watch.elapsedMicroseconds / 1000}ms',
      );
    }
    // The next request goes as soon as this update is painted, and the
    // client's own 24 fps cap decides whether it waits first.
    await connection.rfb.requestUpdate();
  }

  Future<ui.Image?> _decode(Framebuffer framebuffer) async {
    try {
      return await decodeFramebuffer(framebuffer);
    } catch (error) {
      _log('decode failed: $error');
      return null;
    }
  }

  /// Tap moves the pointer and left-clicks.
  void click(Offset at, {int button = RfbButtons.left}) {
    _pointer(at, RfbButtons.none);
    _pointer(at, button);
    _pointer(at, RfbButtons.none);
  }

  /// Long press right-clicks.
  void rightClick(Offset at) => click(at, button: RfbButtons.right);

  /// The long-press drag: button 1 stays down while the pointer moves.
  void drag(Offset at, {required bool down}) =>
      _pointer(at, down ? RfbButtons.left : RfbButtons.none);

  /// One button 4/5 press-release per 40 px at fit, where nothing pans.
  void wheel(Offset at, {required bool up}) {
    final button = up ? RfbButtons.wheelUp : RfbButtons.wheelDown;
    _pointer(at, button);
    _pointer(at, RfbButtons.none);
  }

  void _pointer(Offset at, int buttonMask) {
    _connection?.rfb.sendPointer(
      x: at.dx.round(),
      y: at.dy.round(),
      buttonMask: buttonMask,
    );
  }

  /// Typing: a keysym press and release per character, under whatever sticky
  /// modifiers the strip has armed.
  void typeCharacter(
    String character, {
    Set<StickyModifier> sticky = const {},
  }) {
    sendKeysym(Keysyms.forCharacter(character), sticky: sticky);
  }

  void sendKeysym(int keysym, {Set<StickyModifier> sticky = const {}}) {
    final rfb = _connection?.rfb;
    if (rfb == null) return;
    for (final modifier in sticky) {
      rfb.sendKey(modifier.keysym, down: true);
    }
    rfb
      ..sendKey(keysym, down: true)
      ..sendKey(keysym, down: false);
    // Released in the reverse order they went down, so a host watching the
    // sequence sees a chord and not two overlapping keys.
    for (final modifier in sticky.toList().reversed) {
      rfb.sendKey(modifier.keysym, down: false);
    }
  }

  void _fail(Object error) {
    if (_disposed) return;
    final failure = asVncFailure(error);
    _log(failure?.detail ?? error);
    _phase = ScreenPhase.failed;
    _reason =
        failure?.reason(host.name) ?? const VncStreamClosed().reason(host.name);
    notifyListeners();
    // The connection is dropped, not kept for the retry: a retry opens a fresh
    // one, and holding a dead client would keep its zlib stream alive with it.
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    final frames = _frames;
    final connection = _connection;
    _frames = null;
    _connection = null;
    await frames?.cancel();
    await connection?.close();
  }

  /// One debug line per host, named after this feature.
  void _log(Object message) => debugPrint('hotline.vnc ${host.name}: $message');

  @override
  void dispose() {
    _disposed = true;
    // Leaving the route closes the channel and the ssh connection.
    unawaited(_teardown());
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
