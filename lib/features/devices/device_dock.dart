import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../data/repositories/host_repository.dart';
import '../../platform/devices/device_link.dart';
import '../../platform/host_keys.dart';
import '../hosts/host_key_sheet.dart';
import 'device_controllers.dart';

const floatDecodeWidth = 360;

class DeviceSession {
  DeviceSession({
    required this.host,
    required this.link,
    required this.controller,
  });

  final Host host;
  final DeviceLink link;
  DeviceScreenController controller;

  HostDevice get device => controller.device;
}

class _Lease {
  _Lease(this.link);

  final DeviceLink link;
  int count = 1;
}

typedef DeviceGroupFactory = DevicesController Function(
  Host host,
  DeviceDock dock,
);

class DeviceDock extends ChangeNotifier {
  DeviceDock({required this._group});

  final DeviceGroupFactory _group;
  final _leases = <String, _Lease>{};
  final _groups = <DevicesController>[];
  DeviceSession? _session;
  bool _floating = false;
  bool _collapsed = false;
  int _decodeWidth = floatDecodeWidth;
  bool _away = false;
  bool _disposed = false;

  DeviceSession? get session => _session;
  List<DevicesController> get groups => List.unmodifiable(_groups);
  bool get floating => _floating;
  bool get collapsed => _collapsed;

  DeviceLink? borrow(String hostId) {
    final lease = _leases[hostId];
    if (lease == null) return null;
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
    final held = _groupOf(host.id);
    final group = held ?? _group(host, this);
    if (held == null) {
      _groups.add(group);
      group.addListener(notifyListeners);
    }
    _floating = true;
    _collapse(true);
    notifyListeners();
    unawaited(group.refresh());
  }

  DevicesController? _groupOf(String hostId) {
    for (final group in _groups) {
      if (group.host.id == hostId) return group;
    }
    return null;
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
      link: link,
      controller: _start(group.host, link, device),
    );
    notifyListeners();
  }

  void float() {
    if (_groups.isEmpty && _session == null) return;
    _floating = true;
    _session?.controller.decodeWidth = _decodeWidth;
    _collapse(false);
    notifyListeners();
  }

  void collapse(bool collapsed) {
    if (_collapse(collapsed)) notifyListeners();
  }

  bool _collapse(bool collapsed) {
    if (_collapsed == collapsed) return false;
    _collapsed = collapsed;
    unawaited(_session?.controller.setAway(_away || _collapsed));
    return true;
  }

  void decodeAt(int width) {
    _decodeWidth = width;
    if (_floating) _session?.controller.decodeWidth = width;
  }

  void expand() {
    if (_session == null) return;
    _floating = false;
    _collapse(false);
    _session?.controller.decodeWidth = null;
    notifyListeners();
  }

  void close() {
    _end();
    for (final group in _groups) {
      group.dispose();
    }
    _groups.clear();
    _floating = false;
    _collapse(false);
    if (!_disposed) notifyListeners();
  }

  void setAway(bool away) {
    if (_away == away) return;
    _away = away;
    unawaited(_session?.controller.setAway(_away || _collapsed));
  }

  DeviceScreenController _start(Host host, DeviceLink link, HostDevice device) {
    final controller = DeviceScreenController(
      hostName: host.name,
      link: link,
      device: device,
    );
    if (_floating) controller.decodeWidth = _decodeWidth;
    unawaited(controller.setAway(_away || _collapsed));
    return controller;
  }

  void _end() {
    final session = _session;
    if (session == null) return;
    _session = null;
    session.controller.dispose();
    release(session.host.id, session.link);
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

final deviceLinkOpenerProvider = Provider<DeviceLinkOpener>(
  (ref) => DeviceSsh.open,
);

final deviceDockProvider = Provider<DeviceDock>((ref) {
  final keys = ref.read(ed25519KeysProvider);
  final hosts = ref.read(hostRepositoryProvider);
  final open = ref.read(deviceLinkOpenerProvider);
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
  );
  ref.onDispose(dock.dispose);
  return dock;
});
