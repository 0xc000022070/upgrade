import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/host_repository.dart';
import '../../platform/devices/device_link.dart';
import 'device_controllers.dart';

const floatDecodeWidth = 360;

class DeviceSession {
  DeviceSession({
    required this.host,
    required this.link,
    required this.devices,
    required this.controller,
  });

  final Host host;
  final DeviceLink link;
  final List<HostDevice> devices;
  DeviceScreenController controller;

  HostDevice get device => controller.device;
}

class _Lease {
  _Lease(this.link);

  final DeviceLink link;
  int count = 1;
}

class DeviceDock extends ChangeNotifier {
  final _leases = <String, _Lease>{};
  DeviceSession? _session;
  bool _floating = false;
  bool _away = false;
  bool _disposed = false;

  DeviceSession? get session => _session;
  bool get floating => _floating;

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

  DeviceScreenController open(
    Host host,
    DeviceLink link,
    HostDevice device,
    List<HostDevice> devices,
  ) {
    final current = _session;
    if (current != null && current.host.id == host.id && current.link == link) {
      current.controller.dispose();
    } else {
      _end();
      borrow(host.id);
    }
    _session = DeviceSession(
      host: host,
      link: link,
      devices: devices,
      controller: _start(host, link, device),
    );
    _floating = false;
    notifyListeners();
    return _session!.controller;
  }

  void next() {
    final session = _session;
    if (session == null || session.devices.length < 2) return;
    final at = session.devices.indexOf(session.device);
    final device = session.devices[(at + 1) % session.devices.length];
    session.controller.dispose();
    session.controller = _start(session.host, session.link, device);
    notifyListeners();
  }

  void float() {
    final session = _session;
    if (session == null) return;
    _floating = true;
    session.controller.decodeWidth = floatDecodeWidth;
    notifyListeners();
  }

  void expand() {
    _floating = false;
    _session?.controller.decodeWidth = null;
    notifyListeners();
  }

  void close() {
    _end();
    _floating = false;
    if (!_disposed) notifyListeners();
  }

  void setAway(bool away) {
    if (_away == away) return;
    _away = away;
    unawaited(_session?.controller.setAway(away));
  }

  DeviceScreenController _start(Host host, DeviceLink link, HostDevice device) {
    final controller = DeviceScreenController(
      hostName: host.name,
      link: link,
      device: device,
    );
    if (_floating) controller.decodeWidth = floatDecodeWidth;
    unawaited(controller.setAway(_away));
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
    _end();
    for (final lease in _leases.values) {
      unawaited(lease.link.close());
    }
    _leases.clear();
    super.dispose();
  }
}

final deviceDockProvider = Provider<DeviceDock>((ref) {
  final dock = DeviceDock();
  ref.onDispose(dock.dispose);
  return dock;
});
