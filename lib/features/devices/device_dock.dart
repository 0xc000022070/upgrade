import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/devices/device_link.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';
import 'package:upgrade/features/hosts/host_key_sheet.dart';
import 'package:upgrade/features/screen/screen_controller.dart';
import 'package:upgrade/features/devices/device_controllers.dart';

const floatDecodeWidth = 360;

sealed class DockSession {
  DockSession(this.host);

  Host host;
}

final class DeviceSession extends DockSession {
  DeviceSession(super.host, {required this.hold, required this.controller});

  LinkHold hold;
  final DeviceScreenController controller;

  DeviceLink get link => hold.link;
  HostDevice get device => controller.device;
}

final class DesktopSession extends DockSession {
  DesktopSession(super.host, {required this.controller});

  final HostScreenController controller;
}

enum DockSurface { device, desktop }

/// One share of a host's device link: it closes on the last release, or at
/// once on any discard. Repeating either call does nothing.
class LinkHold {
  LinkHold._(this._lease);

  factory LinkHold.open(DeviceLink link) => _Lease(link).hold()!;

  final _Lease _lease;
  bool _done = false;

  DeviceLink get link => _lease.link;

  LinkHold? share() => _done ? null : _lease.hold();

  void release() {
    if (_done) return;
    _done = true;
    _lease.drop();
  }

  void discard() {
    if (_done) return;
    _done = true;
    _lease.end();
  }
}

class _Lease {
  _Lease(this.link);

  final DeviceLink link;
  int _holders = 0;
  bool _over = false;

  LinkHold? hold() {
    if (_over || link.closed) return null;
    _holders++;
    return LinkHold._(this);
  }

  void drop() {
    if (--_holders <= 0) end();
  }

  void end() {
    if (_over) return;
    _over = true;
    unawaited(link.close());
  }
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
  DockSurface? _pip;
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
  DockSurface? get pip => _pip;
  bool get holding => _session != null || _desktop != null;
  int get asks => _asks;

  void ask() {
    _asks++;
    notifyListeners();
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

  /// Follows the saved hosts: whatever the dock holds for a host takes its
  /// latest record, and everything held for a deleted host ends.
  void syncHosts(Iterable<Host> hosts) {
    final byId = {for (final host in hosts) host.id: host};
    var changed = false;
    for (final session in _sessions) {
      final host = byId[session.host.id];
      if (host == null) {
        _endSession(session);
      } else if (!identical(host, session.host)) {
        session.host = host;
      } else {
        continue;
      }
      changed = true;
    }
    for (final group in [..._groups]) {
      final host = byId[group.host.id];
      if (host == null) {
        _groups.remove(group);
        group.dispose();
      } else if (!identical(host, group.host)) {
        group.host = host;
      } else {
        continue;
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }

  DockSession? sessionOn(DockSurface surface) => switch (surface) {
    DockSurface.device => _session,
    DockSurface.desktop => _desktop,
  };

  List<DockSession> get _sessions => [
    for (final surface in DockSurface.values) ?sessionOn(surface),
  ];

  void _endSession(DockSession session) => switch (session) {
    DeviceSession() => _end(),
    DesktopSession() => _endDesktop(),
  };

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
    final current = _session;
    if (current != null &&
        current.host.id == group.host.id &&
        current.device.id == device.id) {
      collapse(false);
      return;
    }
    final LinkHold hold;
    if (current != null &&
        current.host.id == group.host.id &&
        current.link == group.link) {
      current.controller.dispose();
      hold = current.hold;
    } else {
      final shared = group.share();
      if (shared == null) return;
      _end();
      hold = shared;
    }
    _collapsed = false;
    _session = DeviceSession(
      group.host,
      hold: hold,
      controller: _start(group.host, hold.link, device),
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
      _desktop = DesktopSession(host, controller: controller);
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
    _sessions.forEach(_endSession);
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

  void pipFor(DockSurface? surface) {
    if (_pip == surface) return;
    _pip = surface;
    if (surface == DockSurface.desktop) _desktopPaused = false;
    _sync();
    notifyListeners();
  }

  void revive() {
    for (final group in _groups) {
      group.revive();
    }
  }

  bool get _deviceAway =>
      _pip != DockSurface.device &&
      (_away || _collapsed || (!_floating && _expanded != DockSurface.device));

  bool get _desktopAway =>
      _pip != DockSurface.desktop &&
      (_away ||
          _desktopCollapsed ||
          _desktopPaused ||
          (!_floating && _expanded != DockSurface.desktop));

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
    final session = _session;
    if (session?.controller != controller) return null;
    if (session!.link == dead) session.hold.discard();
    final group = _groupOf(host.id);
    final fresh = (await group?.reconnect(dead))?.share();
    if (fresh == null) return null;
    if (_session != session) {
      fresh.release();
      return null;
    }
    final old = session.hold;
    session.hold = fresh;
    old.release();
    return fresh.link;
  }

  void _end() {
    final session = _session;
    if (session == null) return;
    _session = null;
    _collapse(false);
    session.controller.dispose();
    session.hold.release();
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
    required verifier,
  }) async {
    Future<HostLease> lease(HostKeyVerifier verifier, HostUse use) =>
        links.lease(
          address: address,
          port: port,
          user: user,
          privateKey: privateKey,
          verifier: verifier,
          use: use,
        );
    (await lease(verifier, HostUse.devices)).release();
    final trusted = HostKeyVerifier.pinnedOnly(
      verifier.verified ?? verifier.pinned,
    );
    return DeviceSsh.leasing((use) => lease(trusted, use));
  };
});

final vncOpenerProvider = Provider<VncOpener>(
  (ref) => VncTunnel(ref.read(hostLinksProvider)).open,
);

final screenPipProvider = StateProvider<DockSurface?>((ref) => null);

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
  ref
    ..listen<AsyncValue<List<Host>>>(hostsProvider, (_, hosts) {
      if (hosts.value case final value?) dock.syncHosts(value);
    })
    ..onDispose(dock.dispose);
  return dock;
});
