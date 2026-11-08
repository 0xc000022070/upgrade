import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/data/pinned_host_key.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/vnc/framebuffer.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';
import 'package:upgrade/platform/vnc/rfb_messages.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';
import 'package:upgrade/platform/vnc/vnc_server.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';
import 'package:upgrade/brand.dart';

sealed class ScreenPhase {
  const ScreenPhase();
}

final class ScreenConnecting extends ScreenPhase {
  const ScreenConnecting();
}

final class ScreenLive extends ScreenPhase {
  const ScreenLive();
}

final class ScreenFailed extends ScreenPhase {
  const ScreenFailed(this.reason, {this.editHost = false});

  final String reason;
  final bool editHost;
}

/// `bgra8888` is the format the framebuffer is already in, so this is an upload and not a
/// conversion — which is the whole reason the server is asked for that pixel format. Top
/// level so the measurement in the evidence times the path the route runs.
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

/// A [ChangeNotifier] rather than a Riverpod notifier because it is bound to a route's
/// lifetime exactly: the channel and the ssh connection close when the route goes, and a
/// provider that outlived the widget by a frame would hold both open.
class HostScreenController extends ChangeNotifier {
  HostScreenController({
    required this.host,
    required this._readPrivateKey,
    this.keyPins,
    this.prompt,
    required this._open,
  });

  final Host host;
  final Future<String?> Function(String keyId) _readPrivateKey;

  /// Both null in a test, and a null [prompt] is what makes an unattended dial refuse an
  /// unpinned host rather than hang on a sheet nobody can see.
  final HostKeyPins? keyPins;
  final HostKeyPrompt? prompt;

  final VncOpener _open;

  VncConnection? _connection;
  StreamSubscription<Framebuffer>? _frames;

  ScreenPhase _phase = const ScreenConnecting();
  final _painted = ValueNotifier<ui.Image?>(null);
  ui.Image? _image;
  int _frameCount = 0;
  bool _away = false;
  bool _stalled = false;
  Timer? _park;
  bool _parked = false;

  bool _attended = false;
  bool _resumeAttended = false;
  Framebuffer? _lastFramebuffer;
  Size _framebufferSize = Size.zero;
  bool _disposed = false;

  static const _summaryEvery = Duration(seconds: 10);
  final _summaryWindow = Stopwatch();
  int _summaryFrames = 0;
  int _summaryMicros = 0;
  int _summaryMaxMicros = 0;

  /// Guards against a `RETRY` tapped while the previous attempt is still in flight, which
  /// would leave two ssh connections open against one host.
  int _attempt = 0;

  ScreenPhase get phase => _phase;

  ui.Image? get image => _image;
  ValueListenable<ui.Image?> get frames => _painted;

  int get frameCount => _frameCount;

  Size get framebufferSize => _framebufferSize;

  /// The decoded one rather than the newest arrival: a frame that failed to decode was
  /// never on screen.
  Framebuffer? get lastFramebuffer => _lastFramebuffer;

  VncServer get server => VncServer.named(_connection?.serverInit.name ?? '');

  bool _outputFailed = false;

  bool get outputFailed => _outputFailed;

  /// The stream follows on its own: the server announces the new output's size and the
  /// client takes it as a desktop resize.
  Future<void> cycleOutput() async {
    final connection = _connection;
    if (connection == null) return;
    var failed = false;
    try {
      await server.cycleOutput(connection.run);
    } catch (error) {
      _log('output cycle failed: $error');
      failed = true;
    }
    if (_disposed || connection != _connection || failed == _outputFailed) {
      return;
    }
    _outputFailed = failed;
    notifyListeners();
  }

  Future<void> connect() => _connect(attended: true);

  Future<void> _connect({required bool attended}) async {
    final attempt = ++_attempt;
    _attended = attended;
    _stalled = false;
    _phase = const ScreenConnecting();
    notifyListeners();

    final privateKey = await _readPrivateKey(host.keyId);
    if (_disposed || attempt != _attempt) return;
    if (privateKey == null) {
      // The host names a key whose secret is gone from the keystore. There is nothing to offer
      // the host, which from here is a rejected key.
      _fail(HostFailure.keyRejected('no private key stored for ${host.keyId}'));
      return;
    }

    try {
      final connection = await _open(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        vncUsername: host.vncUsername,
        password: host.vncPassword,
        verifier:
            keyPins?.verifier(
              host.id,
              host.hostKey,
              prompt: attended ? _asked : null,
            ) ??
            HostKeyVerifier(
              pinned: host.hostKey,
              prompt: attended ? _asked : null,
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
      _phase = const ScreenLive();
      notifyListeners();
      // The pump runs unawaited: it lives as long as the connection, and every way it can end
      // already reports itself through [frames].
      unawaited(connection.rfb.run());
      // One non-incremental request first.
      await connection.rfb.requestUpdate(incremental: false);
    } catch (error) {
      if (_disposed || attempt != _attempt) return;
      _fail(error);
    }
  }

  int _asking = 0;

  Future<bool> _asked(HostKeyOffer offer, PinnedHostKey? pinned) async {
    _asking++;
    try {
      return await prompt?.call(offer, pinned) ?? false;
    } finally {
      _asking--;
    }
  }

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
      final size = Size(
        framebuffer.width.toDouble(),
        framebuffer.height.toDouble(),
      );
      final reshaped = _image == null || size != _framebufferSize;
      final previous = _image;
      _image = image;
      _painted.value = image;
      // The previous frame's 8 MB goes back the moment the next one is ready, rather than when
      // the next GC gets to it.
      previous?.dispose();
      _lastFramebuffer = framebuffer;
      _frameCount++;
      _framebufferSize = size;
      if (reshaped) notifyListeners();
      _summarize(framebuffer, watch.elapsedMicroseconds);
    }
    if (_away) {
      _stalled = true;
      return;
    }
    // The next request goes as soon as this update is painted, and the client's own 24 fps
    // cap decides whether it waits first.
    await connection.rfb.requestUpdate();
  }

  static const parkAfter = Duration(seconds: 5);

  void setAway(bool away) {
    _away = away;
    _park?.cancel();
    _park = null;
    if (away) {
      _park = Timer(parkAfter, _parkNow);
      return;
    }
    if (_parked) {
      _parked = false;
      unawaited(_connect(attended: _resumeAttended));
      return;
    }
    if (!_stalled) return;
    _stalled = false;
    unawaited(
      _connection?.rfb.requestUpdate().catchError(
        (Object error) => _log('resume request failed: $error'),
      ),
    );
  }

  void _parkNow() {
    _park = null;
    if (_disposed || !_away) return;
    final dialing = _connection == null;
    if (dialing && _phase is! ScreenConnecting) return;
    // A dial on the host-key sheet waits on the person, and parking it would ask again.
    if (_asking > 0) return;
    _parked = true;
    _resumeAttended = dialing && _attended;
    _attempt++;
    _log('parked while away');
    unawaited(_teardown());
  }

  Future<ui.Image?> _decode(Framebuffer framebuffer) async {
    try {
      return await decodeFramebuffer(framebuffer);
    } catch (error) {
      _log('decode failed: $error');
      return null;
    }
  }

  void click(Offset at, {int button = RfbButtons.left}) {
    _pointer(at, RfbButtons.none);
    _pointer(at, button);
    _pointer(at, RfbButtons.none);
  }

  void rightClick(Offset at) => click(at, button: RfbButtons.right);

  void drag(Offset at, {required bool down}) =>
      _pointer(at, down ? RfbButtons.left : RfbButtons.none);

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
    // Released in the reverse order they went down, so a host watching the sequence sees a
    // chord and not two overlapping keys.
    for (final modifier in sticky.toList().reversed) {
      rfb.sendKey(modifier.keysym, down: false);
    }
  }

  void _fail(Object error) {
    if (_disposed) return;
    final failure = asVncFailure(error) ?? HostFailure.streamClosed('$error');
    _log(failure.detail ?? error);
    _phase = ScreenFailed(
      failure.reason(host.name, address: host.address),
      editHost: const {
        HostFailureKind.passwordNeeded,
        HostFailureKind.usernameNeeded,
        HostFailureKind.authRejected,
      }.contains(failure.kind),
    );
    notifyListeners();
    // The connection is dropped, not kept for the retry: a retry opens a fresh one, and
    // holding a dead client would keep its zlib stream alive with it.
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    final frames = _frames;
    final connection = _connection;
    _frames = null;
    _connection = null;
    _outputFailed = false;
    await frames?.cancel();
    await connection?.close();
  }

  void _summarize(Framebuffer framebuffer, int micros) {
    if (!_summaryWindow.isRunning) _summaryWindow.start();
    _summaryFrames++;
    _summaryMicros += micros;
    if (micros > _summaryMaxMicros) _summaryMaxMicros = micros;
    if (_summaryWindow.elapsed < _summaryEvery) return;
    _log(
      '$_summaryFrames frames ${framebuffer.width}x${framebuffer.height} in '
      '${_summaryWindow.elapsed.inSeconds}s, avg '
      '${(_summaryMicros / _summaryFrames / 1000).toStringAsFixed(1)}ms, max '
      '${(_summaryMaxMicros / 1000).toStringAsFixed(1)}ms',
    );
    _summaryWindow.reset();
    _summaryFrames = 0;
    _summaryMicros = 0;
    _summaryMaxMicros = 0;
  }

  void _log(Object message) =>
      debugPrint('$appSlug.vnc ${host.name}: $message');

  @override
  void dispose() {
    _disposed = true;
    _park?.cancel();
    _park = null;
    unawaited(_teardown());
    _painted.dispose();
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
