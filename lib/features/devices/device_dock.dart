import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../data/repositories/host_repository.dart';
import '../../platform/devices/device_link.dart';
import '../../platform/host_keys.dart';
import '../../platform/vnc/vnc_tunnel.dart';
import '../hosts/host_key_sheet.dart';
import '../screen/screen_controller.dart';
import 'device_controllers.dart';

const floatDecodeWidth = 360;

class DeviceSession {
  DeviceSession({required this.host, required this.controller});

  final Host host;
  DeviceScreenController controller;

  DeviceLink get link => controller.link;
  HostDevice get device => controller.device;
}

class DesktopSession {
  DesktopSession({required this.host, required this.controller});

  final Host host;
  final HostScreenController controller;
}

enum DockSurface { device, desktop }

class _Lease {
  _Lease(this.link);

  final DeviceLink link;
  int count = 1;
}

typedef DeviceGroupFactory = DevicesController Function(
  Host host,
  DeviceDock dock,
);

typedef DesktopFactory = HostScreenController Function(Host host);

class DeviceDock extends ChangeNotifier {
  DeviceDock({required this._group, required this._desktopOf});

  final DeviceGroupFactory _group;
  final DesktopFactory _desktopOf;
  final _leases = <String, _Lease>{};
  final _groups = <DevicesController>[];
  DeviceSession? _session;
  DesktopSession? _desktop;
  bool _floating = false;
  bool _collapsed = false;
  bool _desktopCollapsed = false;
  bool _desktopPaused = false;
  DockSurface? _expanded;
  int _decodeWidth = floatDecodeWidth;
  bool _away = false;
  bool _disposed = false;
  int _asks = 0;

  DeviceSession? get session => _session;
  DesktopSession? get desktop => _desktop;
  List<DevicesController> get groups => List.unmodifiable(_groups);
  bool get floating => _floating;
  bool get collapsed => _collapsed;
  bool get desktopCollapsed => _desktopCollapsed;
  bool get desktopPaused => _desktopPaused;
  DockSurface? get expanded => _expanded;
  bool get holding => _session != null || _desktop != null;
  int get asks => _asks;

  void ask() {
    _asks++;
    notifyListeners();
  }

  DeviceLink? borrow(String hostId) {
    final lease = _leases[hostId];
    if (lease == null) return null;
    if (lease.link.closed) {
      discard(hostId, lease.link);
      return null;
    }
    lease.count++;
    return lease.link;
  }

  DeviceLink adopt(String hostId, DeviceLink link) {
    final held = borrow(hostId);
    if (held != null) {
      unawaited(link.close());
      return held;
    }
    _leases[hostId] = _Lease(link);
    return link;
  }

  void release(String hostId, DeviceLink link) {
    final lease = _leases[hostId];
    if (lease == null || lease.link != link) return;
    if (--lease.count > 0) return;
    _leases.remove(hostId);
    unawaited(link.close());
  }

  void discard(String hostId, DeviceLink link) {
    final lease = _leases[hostId];
    if (lease?.link == link) _leases.remove(hostId);
    unawaited(link.close());
  }

  void show(Host host) {
    final group = _attach(host);
    _floating = true;
    _expanded = null;
    _collapse(true);
    notifyListeners();
    unawaited(group.refresh());
  }

  void attach(Iterable<Host> hosts) {
    final fresh = [
      for (final host in hosts)
        if (_groupOf(host.id) == null) _attach(host),
    ];
    if (fresh.isEmpty) return;
    notifyListeners();
    for (final group in fresh) {
      unawaited(group.refresh());
    }
  }

  DevicesController _attach(Host host) {
    final held = _groupOf(host.id);
    if (held != null) return held;
    final group = _group(host, this);
    _groups.add(group);
    group.addListener(notifyListeners);
    return group;
  }

  DevicesController? _groupOf(String hostId) {
    for (final group in _groups) {
      if (group.host.id == hostId) return group;
    }
    return null;
  }

  void summon() {
    _floating = true;
    _expanded = null;
    _sync();
    notifyListeners();
  }

  void tuck() {
    _floating = false;
    _collapsed = _session != null;
    _desktopCollapsed = _desktop != null;
    _sync();
    notifyListeners();
  }

  void select(DevicesController group, HostDevice device) {
    final link = group.link;
    if (link == null) return;
    final current = _session;
    if (current != null &&
        current.host.id == group.host.id &&
        current.device.id == device.id) {
      collapse(false);
      return;
    }
    if (current != null &&
        current.host.id == group.host.id &&
        current.link == link) {
      current.controller.dispose();
    } else {
      _end();
      borrow(group.host.id);
    }
    _collapsed = false;
    _session = DeviceSession(
      host: group.host,
      controller: _start(group.host, link, device),
    );
    notifyListeners();
  }

  void stopWatching(String hostId, HostDevice device) {
    final session = _session;
    if (session == null ||
        session.host.id != hostId ||
        session.device != device) {
      return;
    }
    endDevice();
  }

  void endDevice() {
    if (_session == null) return;
    _end();
    _collapse(false);
    notifyListeners();
  }

  void watchDesktop(Host host) {
    final current = _desktop;
    _floating = true;
    _expanded = null;
    _desktopCollapsed = false;
    if (current == null || current.host.id != host.id) {
      _endDesktop();
      final controller = _desktopOf(host);
      _desktop = DesktopSession(host: host, controller: controller);
      unawaited(controller.connect());
    }
    _sync();
    notifyListeners();
  }

  void collapseDesktop(bool collapsed) {
    if (_desktopCollapsed == collapsed) return;
    _desktopCollapsed = collapsed;
    _sync();
    notifyListeners();
  }

  void pauseDesktop(bool paused) {
    if (_desktopPaused == paused) return;
    _desktopPaused = paused;
    _sync();
    notifyListeners();
  }

  void expandDesktop() {
    if (_desktop == null) return;
    _floating = false;
    _expanded = DockSurface.desktop;
    _desktopCollapsed = false;
    _desktopPaused = false;
    _sync();
    notifyListeners();
  }

  void endDesktop() {
    if (_desktop == null) return;
    _endDesktop();
    notifyListeners();
  }

  void float() {
    if (_groups.isEmpty && !holding) return;
    _floating = true;
    _expanded = null;
    _session?.controller.decodeWidth = _decodeWidth;
    _collapsed = false;
    _sync();
    notifyListeners();
  }

  void collapse(bool collapsed) {
    if (_collapse(collapsed)) notifyListeners();
  }

  bool _collapse(bool collapsed) {
    if (_collapsed == collapsed) return false;
    _collapsed = collapsed;
    _sync();
    return true;
  }

  void decodeAt(int width) {
    _decodeWidth = width;
    if (_floating) _session?.controller.decodeWidth = width;
  }

  void expand() {
    if (_session == null) return;
    _floating = false;
    _expanded = DockSurface.device;
    _collapsed = false;
    _sync();
    _session?.controller.decodeWidth = null;
    notifyListeners();
  }

  void close() {
    _end();
    _endDesktop();
    for (final group in _groups) {
      group.dispose();
    }
    _groups.clear();
    _floating = false;
    _expanded = null;
    _collapsed = false;
    if (!_disposed) notifyListeners();
  }

  void setAway(bool away) {
    if (_away == away) return;
    _away = away;
    if (!away) revive();
    _sync();
  }

  void revive() {
    for (final group in _groups) {
      group.revive();
    }
  }

  bool get _deviceAway =>
      _away || _collapsed || (!_floating && _expanded != DockSurface.device);

  bool get _desktopAway =>
      _away ||
      _desktopCollapsed ||
      _desktopPaused ||
      (!_floating && _expanded != DockSurface.desktop);

  void _sync() {
    unawaited(_session?.controller.setAway(_deviceAway));
    _desktop?.controller.setAway(_desktopAway);
  }

  DeviceScreenController _start(Host host, DeviceLink link, HostDevice device) {
    late final DeviceScreenController controller;
    controller = DeviceScreenController(
      hostName: host.name,
      link: link,
      device: device,
      reopen: (dead) => _reopen(host, controller, dead),
    );
    if (_floating) controller.decodeWidth = _decodeWidth;
    unawaited(controller.setAway(_deviceAway));
    return controller;
  }

  Future<DeviceLink?> _reopen(
    Host host,
    DeviceScreenController controller,
    DeviceLink dead,
  ) async {
    final group = _groupOf(host.id);
    if (group == null) return null;
    final fresh = await group.reconnect(dead);
    if (fresh == null || _session?.controller != controller) return null;
    return borrow(host.id);
  }

  void _end() {
    final session = _session;
    if (session == null) return;
    _session = null;
    session.controller.dispose();
    release(session.host.id, session.link);
  }

  void _endDesktop() {
    final desktop = _desktop;
    _desktop = null;
    _desktopCollapsed = false;
    _desktopPaused = false;
    desktop?.controller.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    for (final lease in _leases.values) {
      unawaited(lease.link.close());
    }
    _leases.clear();
    super.dispose();
  }
}

final deviceLinkOpenerProvider = Provider<DeviceLinkOpener>((ref) {
  final links = ref.read(hostLinksProvider);
  return ({
    required address,
    required port,
    required user,
    required privateKey,
    verifier,
  }) async => DeviceSsh.borrowed(
    await links.lease(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
    ),
  );
});

final vncOpenerProvider = Provider<VncOpener>(
  (ref) => VncTunnel(ref.read(hostLinksProvider)).open,
);

final deviceDockProvider = Provider<DeviceDock>((ref) {
  final keys = ref.read(ed25519KeysProvider);
  final hosts = ref.read(hostRepositoryProvider);
  final open = ref.read(deviceLinkOpenerProvider);
  final openVnc = ref.read(vncOpenerProvider);
  Future<bool> prompt(Host host, HostKeyOffer offer, PinnedHostKey? pinned) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return Future.value(false);
    return askHostKey(context, host: host, offer: offer, pinned: pinned);
  }

  final dock = DeviceDock(
    group: (host, dock) => DevicesController(
      host: host,
      dock: dock,
      readPrivateKey: keys.privateKey,
      pinHostKey: hosts.pinHostKey,
      prompt: (offer, pinned) => prompt(host, offer, pinned),
      open: open,
    ),
    desktopOf: (host) => HostScreenController(
      host: host,
      readPrivateKey: keys.privateKey,
      pinHostKey: hosts.pinHostKey,
      prompt: (offer, pinned) => prompt(host, offer, pinned),
      open: openVnc,
    ),
  );
  ref.onDispose(dock.dispose);
  return dock;
});
