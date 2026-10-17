import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:striked/application/agents/reason_lines.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/devices/device_link.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/features/devices/device_dock.dart';

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

sealed class DeviceBoot {
  const DeviceBoot(this.device);

  final StoppedDevice device;
}

final class BootRunning extends DeviceBoot {
  const BootRunning(super.device);
}

final class BootFailed extends DeviceBoot {
  const BootFailed(super.device, this.reason);

  final String reason;
}

sealed class DeviceWork {
  const DeviceWork();
}

final class WorkRunning extends DeviceWork {
  const WorkRunning();
}

final class WorkFailed extends DeviceWork {
  const WorkFailed(this.reason);

  final String reason;
}

String workKey(HostDevice device) => '${device.kind.name}:${device.id}';

class DevicesController extends ChangeNotifier {
  DevicesController({
    required this.host,
    required this.dock,
    required this._readPrivateKey,
    required this._open,
    this.pinHostKey,
    this.prompt,
    this.bootLimit = defaultBootLimit,
  });

  static const defaultBootLimit = Duration(minutes: 3);

  Host host;
  final DeviceDock dock;
  final Future<String?> Function(String keyId) _readPrivateKey;
  final Future<void> Function(String hostId, PinnedHostKey key)? pinHostKey;
  final HostKeyPrompt? prompt;
  final Duration bootLimit;
  final DeviceLinkOpener _open;

  PinnedHostKey? _pinned;
  DeviceLink? _link;
  DevicesPhase _phase = const DevicesLoading();
  bool _disposed = false;
  int _attempt = 0;
  final _boots = <DeviceBoot>[];
  final _work = <String, DeviceWork>{};

  Future<DeviceLink?>? _dialling;

  DevicesPhase get phase => _phase;
  DeviceLink? get link => _link?.closed ?? true ? null : _link;
  List<DeviceBoot> get boots => List.unmodifiable(_boots);
  DeviceWork? workOn(HostDevice device) => _work[workKey(device)];

  List<HostDevice> get shown {
    final phase = _phase;
    if (phase is! DevicesListed) return const [];
    return [
      for (final device in phase.devices)
        if (!_boots.any((boot) => _bootOf(boot, device))) device,
    ];
  }

  bool _bootOf(DeviceBoot boot, HostDevice device) =>
      boot.device.kind == device.kind &&
      boot.device.id ==
          (device.kind == DeviceKind.android ? device.avd : device.id);

  void revive() {
    if (_link?.closed ?? false) unawaited(refresh());
  }

  Future<DeviceLink> _ready() async {
    final link = _live() ?? await _connect();
    if (link == null) throw const HerdrUnreachable('no device link');
    return link;
  }

  Future<StoppedListing> stopped() async {
    final link = await _ready();
    final listing = parseStoppedList(await link.read(DeviceCommands.stopped()));
    final running = {
      for (final boot in _boots)
        if (boot is BootRunning) boot.device,
    };
    return StoppedListing(
      tools: listing.tools,
      devices: [
        for (final device in listing.devices)
          if (!running.contains(device)) device,
      ],
    );
  }

  Future<void> boot(StoppedDevice device, {required bool cold}) async {
    if (_boots.any((boot) => boot is BootRunning && boot.device == device)) {
      return;
    }
    _boots
      ..removeWhere((boot) => boot.device == device)
      ..add(BootRunning(device));
    notifyListeners();
    String? reason;
    try {
      final link = await _ready();
      if (_disposed) return;
      final outcome = parseOutcome(
        await link.read(
          DeviceCommands.boot(device, cold: cold),
          limit: bootLimit,
        ),
      );
      reason = outcome.ok ? null : outcome.error;
    } on TimeoutException {
      reason = ReasonLine.bootTimedOut.words;
    } catch (error) {
      reason = _reason(error);
    }
    if (_disposed) return;
    final index = _boots.indexWhere(
      (boot) => boot is BootRunning && boot.device == device,
    );
    if (index < 0) return;
    if (reason == null) {
      _boots.removeAt(index);
      notifyListeners();
      await _relist();
      return;
    }
    _boots[index] = BootFailed(device, reason);
    notifyListeners();
  }

  Future<void> shutDown(HostDevice device) =>
      _act(device, DeviceCommands.shutDown(device));

  Future<void> delete(HostDevice device) {
    final android = device.kind == DeviceKind.android;
    return _act(
      device,
      DeviceCommands.delete(
        kind: device.kind,
        id: android ? device.avd ?? device.id : device.id,
        serial: android ? device.id : null,
      ),
    );
  }

  Future<void> _act(HostDevice device, String command) async {
    final key = workKey(device);
    if (_work[key] is WorkRunning) return;
    _work[key] = const WorkRunning();
    notifyListeners();
    dock.stopWatching(host.id, device);
    String? reason;
    try {
      final link = await _ready();
      final outcome = parseOutcome(await link.read(command));
      reason = outcome.ok ? null : outcome.error;
    } catch (error) {
      reason = _reason(error);
    }
    if (_disposed) return;
    if (reason == null) {
      _work.remove(key);
      await _relist();
      return;
    }
    _work[key] = WorkFailed(reason);
    notifyListeners();
  }

  Future<String?> deleteStopped(StoppedDevice device) =>
      _answer(DeviceCommands.delete(kind: device.kind, id: device.id));

  Future<String?> create(NewDevice device) =>
      _answer(DeviceCommands.create(device));

  Future<DeviceCatalog> catalog(DeviceKind kind) async {
    final link = await _ready();
    final out = await link.read(DeviceCommands.catalog(kind));
    return switch (kind) {
      DeviceKind.android => parseAndroidCatalog(out),
      DeviceKind.simulator => parseSimulatorCatalog(out),
    };
  }

  Future<String?> _answer(String command) async {
    try {
      final link = await _ready();
      final outcome = parseOutcome(await link.read(command));
      return outcome.ok ? null : outcome.error;
    } catch (error) {
      return _reason(error);
    }
  }

  String reasonFor(Object error) => _reason(error);

  String _reason(Object error) {
    debugPrint('striked.devices ${host.name}: $error');
    return asHerdrFailure(error)?.reason(host.name) ??
        ReasonLine.streamClosed.words;
  }

  Future<void> _relist() async {
    final attempt = _attempt;
    try {
      final link = await _ready();
      final devices = await link.list();
      if (_disposed || attempt != _attempt) return;
      _phase = DevicesListed(devices);
      _boots.removeWhere(
        (boot) =>
            boot is BootFailed &&
            devices.any((device) => _bootOf(boot, device)),
      );
      notifyListeners();
    } catch (error) {
      if (_disposed || attempt != _attempt) return;
      _fail(error);
    }
  }

  Future<void> refresh() async {
    final attempt = ++_attempt;
    _phase = const DevicesLoading();
    _boots.removeWhere((boot) => boot is BootFailed);
    _work.removeWhere((_, work) => work is WorkFailed);
    notifyListeners();
    try {
      final link = _live() ?? await _connect();
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

  Future<DeviceLink?> reconnect(DeviceLink dead) async {
    if (_link == dead) _link = null;
    dock.discard(host.id, dead);
    final link = _live() ?? await _connect();
    return _disposed ? null : link;
  }

  DeviceLink? _live() {
    final link = _link;
    if (link == null || !link.closed) return link;
    _link = null;
    dock.discard(host.id, link);
    return null;
  }

  Future<DeviceLink?> _connect() =>
      _dialling ??= _dial().whenComplete(() => _dialling = null);

  Future<DeviceLink?> _dial() async {
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
    debugPrint('striked.devices ${host.name}: ${failure?.detail ?? error}');
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
    _boots.clear();
    _work.clear();
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
    required this._link,
    required this.device,
    this.reopen,
  });

  static const longPress = Duration(milliseconds: 600);
  static const shortestDrag = Duration(milliseconds: 100);
  static const longestDrag = Duration(seconds: 2);

  final String hostName;
  final HostDevice device;
  final Future<DeviceLink?> Function(DeviceLink dead)? reopen;

  DeviceLink _link;
  DeviceLink get link => _link;

  StreamSubscription<DeviceFrame>? _frames;
  DevicePhase _phase = const DeviceWaiting();
  ui.Image? _image;
  ui.Size _nativeSize = ui.Size.zero;
  bool _disposed = false;

  ({DeviceFrame frame, int run})? _next;
  bool _decoding = false;

  int? decodeWidth;

  DevicePhase get phase => _phase;
  ui.Image? get image => _image;
  ui.Size get nativeSize => _nativeSize;

  bool _held = false;
  bool _away = false;
  bool _lost = false;
  bool _returned = false;
  bool _reopening = false;
  int _run = 0;

  bool get held => _held;

  void start() {
    final run = ++_run;
    _phase = const DeviceWaiting();
    notifyListeners();
    _frames = _link
        .frames(device)
        .listen(
          (frame) => _onFrame(frame, run),
          onError: (Object error) => _fail(error, run),
          onDone: () => _fail(const DeviceCaptureFailed('loop ended'), run),
          cancelOnError: true,
        );
  }

  Future<void> retry() async {
    if (_reopening) return;
    _held = false;
    await _halt();
    if (_disposed || _away) return;
    _lost || _link.closed ? await _relive() : start();
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
    _returned = _away && !away;
    _away = away;
    if (away) {
      await _halt();
    } else {
      _go();
    }
  }

  void _go() {
    if (_disposed || _held || _away || _frames != null || _reopening) return;
    if (_link.closed) _lost = true;
    _lost ? unawaited(_relive()) : start();
  }

  Future<void> _relive() async {
    final reopen = this.reopen;
    if (reopen == null) return start();
    final run = ++_run;
    _returned = false;
    _reopening = true;
    _phase = const DeviceWaiting();
    notifyListeners();
    final DeviceLink? fresh;
    try {
      fresh = await reopen(_link);
    } catch (error) {
      _fail(error, run);
      return;
    } finally {
      _reopening = false;
    }
    if (_disposed) return;
    if (fresh == null) {
      _fail(const HerdrUnreachable('nothing to reopen'), run);
      return;
    }
    _link = fresh;
    _lost = false;
    if (!_held && !_away && _frames == null) start();
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

  void _onFrame(DeviceFrame frame, int run) {
    _next = (frame: frame, run: run);
    if (!_decoding) unawaited(_decodeLatest());
  }

  Future<void> _decodeLatest() async {
    _decoding = true;
    try {
      while (!_disposed) {
        final next = _next;
        if (next == null) break;
        _next = null;
        await _decode(next.frame, next.run);
      }
    } finally {
      _decoding = false;
    }
  }

  Future<void> _decode(DeviceFrame frame, int run) async {
    if (run != _run) return;
    ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(
        frame.bytes,
        targetWidth: decodeWidth,
      );
      image = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (error) {
      debugPrint(
        'striked.devices $hostName ${device.id}: decode failed: $error',
      );
      return;
    }
    if (_disposed || run != _run) {
      image.dispose();
      return;
    }
    _image?.dispose();
    _image = image;
    _returned = false;
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
      _link.run(command).catchError((Object error) {
        debugPrint('striked.devices $hostName ${device.id}: input: $error');
      }),
    );
  }

  /// `cancelOnError` has already cancelled the subscription, and cancelling it a second
  /// time from `RETRY` would wait on a teardown that is not coming.
  void _fail(Object error, int run) {
    if (run != _run) return;
    _frames = null;
    if (_disposed) return;
    debugPrint('striked.devices $hostName ${device.id}: $error');
    final failure = asHerdrFailure(error);
    _lost = failure is HerdrUnreachable;
    if (_lost && _returned && reopen != null) {
      unawaited(_relive());
      return;
    }
    _phase = DeviceFailed(
      failure?.reason(hostName) ?? ReasonLine.streamClosed.words,
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
