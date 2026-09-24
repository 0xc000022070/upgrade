import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../application/reason_lines.dart';
import '../../data/repositories/host_repository.dart';
import '../../platform/devices/device_link.dart';
import '../../platform/herdr_client.dart';
import '../../platform/host_keys.dart';
import 'device_dock.dart';

sealed class DevicesPhase {
  const DevicesPhase();
}

final class DevicesLoading extends DevicesPhase {
  const DevicesLoading();
}

final class DevicesListed extends DevicesPhase {
  const DevicesListed(this.devices);

  final List<HostDevice> devices;
}

final class DevicesFailed extends DevicesPhase {
  const DevicesFailed(this.reason);

  final String reason;
}

class DevicesController extends ChangeNotifier {
  DevicesController({
    required this.host,
    required this.dock,
    required this._readPrivateKey,
    this.pinHostKey,
    this.prompt,
    DeviceLinkOpener? open,
  }) : _open = open ?? DeviceSsh.open;

  final Host host;
  final DeviceDock dock;
  final Future<String?> Function(String keyId) _readPrivateKey;
  final Future<void> Function(String hostId, PinnedHostKey key)? pinHostKey;
  final HostKeyPrompt? prompt;
  final DeviceLinkOpener _open;

  PinnedHostKey? _pinned;
  DeviceLink? _link;
  DevicesPhase _phase = const DevicesLoading();
  bool _disposed = false;
  int _attempt = 0;

  DevicesPhase get phase => _phase;
  DeviceLink? get link => _link;

  Future<void> refresh() async {
    final attempt = ++_attempt;
    _phase = const DevicesLoading();
    notifyListeners();
    try {
      final link = _link ?? await _connect();
      if (link == null || _disposed || attempt != _attempt) return;
      final devices = await link.list();
      if (_disposed || attempt != _attempt) return;
      _phase = DevicesListed(devices);
      notifyListeners();
    } catch (error) {
      if (_disposed || attempt != _attempt) return;
      _fail(error);
    }
  }

  Future<DeviceLink?> _connect() async {
    final held = dock.borrow(host.id);
    if (held != null) {
      _link = held;
      return held;
    }
    final privateKey = await _readPrivateKey(host.keyId);
    if (_disposed) return null;
    if (privateKey == null) {
      _fail(const HerdrKeyRejected('no private key stored'));
      return null;
    }
    final link = await _open(
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
    if (_disposed) {
      await link.close();
      return null;
    }
    return _link = dock.adopt(host.id, link);
  }

  void _fail(Object error) {
    final failure = asHerdrFailure(error);
    debugPrint('dazzle.devices ${host.name}: ${failure?.detail ?? error}');
    _phase = DevicesFailed(
      failure?.reason(host.name) ?? ReasonLine.streamClosed.words,
    );
    notifyListeners();
    final link = _link;
    _link = null;
    if (link != null) dock.discard(host.id, link);
  }

  @override
  void dispose() {
    _disposed = true;
    final link = _link;
    _link = null;
    if (link != null) dock.release(host.id, link);
    super.dispose();
  }
}

sealed class DevicePhase {
  const DevicePhase();
}

final class DeviceWaiting extends DevicePhase {
  const DeviceWaiting();
}

final class DeviceLive extends DevicePhase {
  const DeviceLive();
}

final class DevicePaused extends DevicePhase {
  const DevicePaused();
}

final class DeviceFailed extends DevicePhase {
  const DeviceFailed(this.reason);

  final String reason;
}

enum DeviceKey {
  back('BACK', '4'),
  home('HOME', '3'),
  recents('RECENTS', '187');

  const DeviceKey(this.label, this.keycode);

  final String label;
  final String keycode;
}

class DeviceScreenController extends ChangeNotifier {
  DeviceScreenController({
    required this.hostName,
    required this.link,
    required this.device,
  });

  static const longPress = Duration(milliseconds: 600);
  static const shortestDrag = Duration(milliseconds: 100);
  static const longestDrag = Duration(seconds: 2);

  final String hostName;
  final DeviceLink link;
  final HostDevice device;

  StreamSubscription<DeviceFrame>? _frames;
  DevicePhase _phase = const DeviceWaiting();
  ui.Image? _image;
  ui.Size _nativeSize = ui.Size.zero;
  bool _disposed = false;

  /// Frames decode off the stream's order; a slow decode must not paint over a newer one.
  int _sequence = 0;
  int _shown = 0;

  DevicePhase get phase => _phase;
  ui.Image? get image => _image;
  ui.Size get nativeSize => _nativeSize;

  bool _held = false;
  bool _away = false;
  int _run = 0;

  bool get held => _held;

  void start() {
    final run = ++_run;
    _phase = const DeviceWaiting();
    notifyListeners();
    _frames = link
        .frames(device)
        .listen(
          (frame) => _onFrame(frame, run),
          onError: (Object error) => _fail(error, run),
          onDone: () => _fail(const DeviceCaptureFailed('loop ended'), run),
          cancelOnError: true,
        );
  }

  Future<void> retry() async {
    _held = false;
    await _halt();
    if (_disposed || _away) return;
    start();
  }

  Future<void> pause() async {
    _held = true;
    await _halt();
  }

  void resume() {
    _held = false;
    _go();
  }

  Future<void> setAway(bool away) async {
    _away = away;
    if (away) {
      await _halt();
    } else {
      _go();
    }
  }

  void _go() {
    if (_disposed || _held || _away || _frames != null) return;
    start();
  }

  Future<void> _halt() async {
    _run++;
    final frames = _frames;
    _frames = null;
    if (_disposed) return;
    if (_phase is! DeviceFailed) {
      _phase = const DevicePaused();
      notifyListeners();
    }
    await frames?.cancel();
  }

  Future<void> _onFrame(DeviceFrame frame, int run) async {
    final sequence = ++_sequence;
    ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(frame.bytes);
      image = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (error) {
      debugPrint(
        'dazzle.devices $hostName ${device.id}: decode failed: $error',
      );
      return;
    }
    if (_disposed || run != _run || sequence < _shown) {
      image.dispose();
      return;
    }
    _shown = sequence;
    _image?.dispose();
    _image = image;
    _nativeSize = ui.Size(frame.width.toDouble(), frame.height.toDouble());
    _phase = const DeviceLive();
    notifyListeners();
  }

  void tap(ui.Offset at) =>
      _send(DeviceCommands.tap(device, at.dx.round(), at.dy.round()));

  void press(ui.Offset at) => _swipe(at, at, longPress);

  void drag(ui.Offset from, ui.Offset to, Duration took) {
    final clamped = took < shortestDrag
        ? shortestDrag
        : took > longestDrag
        ? longestDrag
        : took;
    _swipe(from, to, clamped);
  }

  void key(DeviceKey key) => _send(DeviceCommands.key(device, key.keycode));

  void _swipe(ui.Offset from, ui.Offset to, Duration duration) => _send(
    DeviceCommands.swipe(
      device,
      from.dx.round(),
      from.dy.round(),
      to.dx.round(),
      to.dy.round(),
      duration,
    ),
  );

  void _send(String command) {
    if (!device.pressable || _phase is! DeviceLive) return;
    unawaited(
      link.run(command).catchError((Object error) {
        debugPrint('dazzle.devices $hostName ${device.id}: input: $error');
      }),
    );
  }

  /// `cancelOnError` has already cancelled the subscription, and cancelling it a second
  /// time from `RETRY` would wait on a teardown that is not coming.
  void _fail(Object error, int run) {
    if (run != _run) return;
    _frames = null;
    if (_disposed) return;
    debugPrint('dazzle.devices $hostName ${device.id}: $error');
    _phase = DeviceFailed(
      asHerdrFailure(error)?.reason(hostName) ?? ReasonLine.streamClosed.words,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_frames?.cancel());
    _frames = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
