import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../herdr_client.dart';
import '../host_keys.dart';
import '../host_links.dart';
import '../shell/remote_shell.dart';
import '../ssh_settle.dart';

enum DeviceKind { android, simulator }

class HostDevice {
  const HostDevice({
    required this.kind,
    required this.id,
    required this.name,
    this.avd,
    this.runtime,
  });

  final DeviceKind kind;

  final String id;
  final String name;
  final String? avd;
  final String? runtime;

  bool get pressable => kind == DeviceKind.android;

  bool get managed => kind == DeviceKind.simulator || avd != null;

  @override
  bool operator ==(Object other) =>
      other is HostDevice && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

List<HostDevice> parseDeviceList(String output) {
  final devices = <HostDevice>[];
  final lines = const LineSplitter().convert(output);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line == '@simctl') {
      for (final sim in _simulators(lines.skip(i + 1).join('\n'))) {
        if (sim.state != 'Booted') continue;
        devices.add(
          HostDevice(
            kind: DeviceKind.simulator,
            id: sim.udid,
            name: sim.label,
            runtime: sim.runtime,
          ),
        );
      }
      break;
    }
    final match = RegExp(r'^([AE]) (\S+) ?(.*)$').firstMatch(line);
    if (match == null) continue;
    final id = match.group(2)!;
    final name = match.group(3)!.trim();
    final emulator = match.group(1) == 'E' && name.isNotEmpty;
    devices.add(
      HostDevice(
        kind: DeviceKind.android,
        id: id,
        name: name.isEmpty ? id : name,
        avd: emulator ? name : null,
      ),
    );
  }
  return devices;
}

class StoppedDevice {
  const StoppedDevice({
    required this.kind,
    required this.id,
    required this.name,
    this.runtime,
  });

  final DeviceKind kind;

  final String id;
  final String name;
  final String? runtime;

  @override
  bool operator ==(Object other) =>
      other is StoppedDevice && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

class StoppedListing {
  const StoppedListing({required this.tools, required this.devices});

  final Set<DeviceKind> tools;
  final List<StoppedDevice> devices;
}

StoppedListing parseStoppedList(String output) {
  final tools = <DeviceKind>{};
  final devices = <StoppedDevice>[];
  final lines = const LineSplitter().convert(output);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line == 'T A') tools.add(DeviceKind.android);
    if (line == 'T I') tools.add(DeviceKind.simulator);
    if (line.startsWith('E ')) {
      final name = line.substring(2).trim();
      if (name.isNotEmpty) {
        devices.add(
          StoppedDevice(kind: DeviceKind.android, id: name, name: name),
        );
      }
    }
    if (line == '@simctl') {
      for (final sim in _simulators(lines.skip(i + 1).join('\n'))) {
        if (sim.state != 'Shutdown') continue;
        devices.add(
          StoppedDevice(
            kind: DeviceKind.simulator,
            id: sim.udid,
            name: sim.label,
            runtime: sim.runtime,
          ),
        );
      }
      break;
    }
  }
  return StoppedListing(tools: tools, devices: devices);
}

String runtimeLabel(String runtime) {
  final tail = runtime.substring(runtime.lastIndexOf('.') + 1);
  final dash = tail.indexOf('-');
  if (dash < 0) return tail;
  final version = tail.substring(dash + 1).replaceAll('-', '.');
  return '${tail.substring(0, dash)} $version';
}

typedef _Simulator = ({
  String udid,
  String name,
  String state,
  String runtime,
  String label,
});

List<_Simulator> _simulators(String json) {
  if (json.trim().isEmpty) return const [];
  final found = <_Simulator>[];
  if (jsonDecode(json) case {'devices': final Map<String, Object?> runtimes}) {
    for (final MapEntry(key: runtime, value: devices) in runtimes.entries) {
      if (devices is! List<Object?>) continue;
      for (final device in devices) {
        if (device
            case {
              'udid': final String udid,
              'name': final String name,
              'state': final String state,
            }
            when device['isAvailable'] != false) {
          found.add((
            udid: udid,
            name: name,
            state: state,
            runtime: runtime,
            label: name,
          ));
        }
      }
    }
  }
  final counts = <String, int>{};
  for (final sim in found) {
    counts[sim.name] = (counts[sim.name] ?? 0) + 1;
  }
  return [
    for (final sim in found)
      counts[sim.name]! > 1
          ? (
              udid: sim.udid,
              name: sim.name,
              state: sim.state,
              runtime: sim.runtime,
              label: '${sim.name} · ${runtimeLabel(sim.runtime)}',
            )
          : sim,
  ];
}

class CatalogEntry {
  const CatalogEntry({required this.id, required this.name, this.supports});

  final String id;
  final String name;
  final Set<String>? supports;
}

class DeviceCatalog {
  const DeviceCatalog({
    required this.available,
    required this.profiles,
    required this.images,
  });

  final bool available;
  final List<CatalogEntry> profiles;
  final List<CatalogEntry> images;

  List<CatalogEntry> get offered {
    final named = {for (final image in images) ...?image.supports};
    if (images.every((image) => image.supports == null)) return profiles;
    return [
      for (final profile in profiles)
        if (named.contains(profile.id)) profile,
    ];
  }

  List<CatalogEntry> imagesFor(String? profile) => [
    for (final image in images)
      if (profile == null ||
          image.supports == null ||
          image.supports!.contains(profile))
        image,
  ];
}

DeviceCatalog parseAndroidCatalog(String output) {
  final profiles = <CatalogEntry>[];
  final images = <CatalogEntry>[];
  var available = true;
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trim();
    if (line == 'X') available = false;
    final match = RegExp(r'^([PS]) (\S+)$').firstMatch(line);
    if (match == null) continue;
    final id = match.group(2)!;
    final entries = match.group(1) == 'P' ? profiles : images;
    if (entries.any((entry) => entry.id == id)) continue;
    entries.add(CatalogEntry(id: id, name: id));
  }
  return DeviceCatalog(
    available: available,
    profiles: profiles,
    images: images,
  );
}

DeviceCatalog parseSimulatorCatalog(String output) {
  if (output.trim() == 'X') {
    return const DeviceCatalog(available: false, profiles: [], images: []);
  }
  final types = output.indexOf('@devicetypes');
  final runtimes = output.indexOf('@runtimes');
  if (types < 0 || runtimes < types) {
    throw const FormatException('no simulator catalog');
  }
  final typeJson = jsonDecode(
    output.substring(types + '@devicetypes'.length, runtimes),
  );
  final runtimeJson = jsonDecode(
    output.substring(runtimes + '@runtimes'.length),
  );
  final profiles = <CatalogEntry>[
    if (typeJson case {'devicetypes': final List<Object?> list})
      for (final type in list)
        if (type case {
          'identifier': final String id,
          'name': final String name,
        })
          CatalogEntry(id: id, name: name),
  ];
  final images = <CatalogEntry>[
    if (runtimeJson case {'runtimes': final List<Object?> list})
      for (final runtime in list)
        if (runtime
            case {'identifier': final String id, 'name': final String name}
            when runtime['isAvailable'] != false)
          CatalogEntry(
            id: id,
            name: name,
            supports: switch (runtime['supportedDeviceTypes']) {
              final List<Object?> types => {
                for (final type in types)
                  if (type case {'identifier': final String id}) id,
              },
              _ => null,
            },
          ),
  ];
  return DeviceCatalog(available: true, profiles: profiles, images: images);
}

class NewDevice {
  const NewDevice({
    required this.kind,
    required this.name,
    required this.profile,
    required this.image,
  });

  final DeviceKind kind;
  final String name;
  final String profile;
  final String image;
}

final avdNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');

typedef DeviceOutcome = ({bool ok, String? serial, String? error});

DeviceOutcome parseOutcome(String output) {
  final lines = const LineSplitter().convert(output);
  for (final raw in lines.reversed) {
    final line = raw.trim();
    if (line == 'OK') return (ok: true, serial: null, error: null);
    if (line.startsWith('B ')) {
      return (ok: true, serial: line.substring(2).trim(), error: null);
    }
    if (line == 'E' || line.startsWith('E ')) {
      final message = line.substring(1).trim();
      return (
        ok: false,
        serial: null,
        error: message.isEmpty ? 'failed' : message,
      );
    }
  }
  return (ok: false, serial: null, error: 'no answer');
}

const _avdOf = r'''
avd() {
  n=$(adb -s "$1" emu avd name </dev/null 2>/dev/null | head -n 1 | tr -d '\r')
  [ -n "$n" ] || n=$(adb -s "$1" shell getprop ro.boot.qemu.avd_name </dev/null 2>/dev/null | tr -d '\r')
  printf '%s' "$n"
}
''';

const _fail = r'''
fail() {
  m=$(printf '%s\n' "$1" | grep -E 'Error|ERROR' | tail -n 1)
  [ -n "$m" ] || m=$(printf '%s\n' "$1" | grep . | tail -n 1)
  printf 'E %s\n' "$(printf '%s' "${m:-failed}" | head -c 200 | tr '\n' ' ')"
}
''';

const _stop = r'''
stop() {
  adb -s "$1" emu kill </dev/null >/dev/null 2>&1
  i=0
  while adb devices </dev/null 2>/dev/null | awk -v s="$1" '$1 == s && $2 == "device" { f = 1 } END { exit !f }'; do
    i=$((i + 1))
    [ "$i" -ge 30 ] && return 1
    sleep 1
  done
  return 0
}
''';

const _listBody = r'''
if command -v adb >/dev/null 2>&1; then
  adb devices </dev/null | while read -r s state; do
    [ "$state" = device ] || continue
    n=$(avd "$s")
    if [ -n "$n" ]; then
      printf 'E %s %s\n' "$s" "$n"
      continue
    fi
    n=$(adb -s "$s" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r')
    printf 'A %s %s\n' "$s" "$n"
  done
fi
if command -v xcrun >/dev/null 2>&1; then
  echo '@simctl'
  xcrun simctl list devices -j </dev/null 2>/dev/null
fi
''';

const _stoppedBody = r'''
if command -v emulator >/dev/null 2>&1; then
  echo 'T A'
  up=
  if command -v adb >/dev/null 2>&1; then
    up=$(adb devices </dev/null 2>/dev/null | while read -r s state; do
      [ "$state" = device ] && avd "$s" && echo
    done)
  fi
  emulator -list-avds </dev/null 2>/dev/null | while IFS= read -r n; do
    case $n in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    printf '%s\n' "$up" | grep -qxF -- "$n" && continue
    printf 'E %s\n' "$n"
  done
fi
if command -v xcrun >/dev/null 2>&1; then
  echo 'T I'
  echo '@simctl'
  xcrun simctl list devices -j </dev/null 2>/dev/null
fi
''';

const _bootStart = r'''
command -v emulator >/dev/null 2>&1 || { echo 'E no emulator'; exit 0; }
command -v adb >/dev/null 2>&1 || { echo 'E no adb'; exit 0; }
d=$(mktemp -d) || { echo 'E no temporary directory'; exit 0; }
trap 'rm -rf "$d"' EXIT
trap 'exit 0' HUP INT TERM PIPE
detach() {
  if command -v setsid >/dev/null 2>&1; then setsid "$@"
  else perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@"; fi
}
detach sh -c 'emulator "$@" 2>&1 | { head -c 65536 >"$0"; cat >/dev/null; }' "$d/log" -avd "$name" -no-window -no-audio''';

const _bootWait = r''' </dev/null >/dev/null 2>&1 &
pid=$!
while :; do
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "$(tail -n 5 "$d/log")"
    exit 0
  fi
  for s in $(adb devices </dev/null 2>/dev/null | awk '$2 == "device" && $1 ~ /^emulator-/ { print $1 }'); do
    [ "$(avd "$s")" = "$name" ] || continue
    [ "$(adb -s "$s" shell getprop sys.boot_completed </dev/null 2>/dev/null | tr -d '\r')" = 1 ] || continue
    printf 'B %s\n' "$s"
    exit 0
  done
  sleep 2
done
''';

const _catalogAndroid = r'''
command -v avdmanager >/dev/null 2>&1 || { echo 'X'; exit 0; }
avdmanager list device -c </dev/null 2>/dev/null | grep -E '^[A-Za-z0-9._-]+$' | sed 's/^/P /'
sdk=${ANDROID_SDK_ROOT:-$ANDROID_HOME}
if [ -z "$sdk" ] && e=$(command -v emulator); then sdk=$(dirname "$(dirname "$e")"); fi
found=
for dir in "$sdk"/system-images/*/*/*; do
  [ -n "$sdk" ] && [ -d "$dir" ] || continue
  found=1
  printf 'S %s\n' "$(printf 'system-images/%s' "${dir#"$sdk"/system-images/}" | tr / ';')"
done
if [ -z "$found" ] && command -v sdkmanager >/dev/null 2>&1; then
  sdkmanager --list_installed </dev/null 2>/dev/null | sed -n 's/^ *\(system-images;[^ |]*\).*/S \1/p'
fi
''';

const _catalogSimulator = r'''
command -v xcrun >/dev/null 2>&1 || { echo 'X'; exit 0; }
echo '@devicetypes'
xcrun simctl list devicetypes -j </dev/null 2>/dev/null
echo '@runtimes'
xcrun simctl list runtimes -j </dev/null 2>/dev/null
''';

String _set(Map<String, String> values) => [
  for (final MapEntry(:key, :value) in values.entries)
    '$key=${shellQuote(value)}\n',
].join();

abstract final class DeviceCommands {
  static String list() => underSh('$_avdOf$_listBody');

  static String stopped() => underSh('$_avdOf$_stoppedBody');

  static String boot(StoppedDevice device, {required bool cold}) =>
      switch (device.kind) {
        DeviceKind.simulator => underSh(
          '${_set({'id': device.id})}$_fail'
          r'if out=$(xcrun simctl boot "$id" 2>&1 </dev/null); then echo OK; else fail "$out"; fi',
        ),
        DeviceKind.android => underSh(
          '${_set({'name': device.id})}$_avdOf$_fail$_bootStart'
          '${cold ? ' -no-snapshot-load' : ''}$_bootWait',
        ),
      };

  static String shutDown(HostDevice device) => switch (device.kind) {
    DeviceKind.simulator => underSh(
      '${_set({'id': device.id})}$_fail'
      r'if out=$(xcrun simctl shutdown "$id" 2>&1 </dev/null); then echo OK; else fail "$out"; fi',
    ),
    DeviceKind.android => underSh(
      '${_set({'serial': device.id})}$_stop'
      r'''if stop "$serial"; then echo OK; else echo 'E still running'; fi''',
    ),
  };

  static String delete({
    required DeviceKind kind,
    required String id,
    String? serial,
  }) => switch (kind) {
    DeviceKind.simulator => underSh(
      '${_set({'id': id})}$_fail'
      r'''
xcrun simctl shutdown "$id" </dev/null >/dev/null 2>&1
if out=$(xcrun simctl delete "$id" 2>&1 </dev/null); then echo OK; else fail "$out"; fi
''',
    ),
    DeviceKind.android => underSh(
      '${_set({'name': id, 'serial': serial ?? ''})}$_fail$_stop'
      r'''
command -v avdmanager >/dev/null 2>&1 || { echo 'E no avdmanager'; exit 0; }
if [ -n "$serial" ] && ! stop "$serial"; then echo 'E still running'; exit 0; fi
if out=$(avdmanager delete avd -n "$name" 2>&1 </dev/null); then echo OK; else fail "$out"; fi
''',
    ),
  };

  static String catalog(DeviceKind kind) => switch (kind) {
    DeviceKind.android => underSh(_catalogAndroid),
    DeviceKind.simulator => underSh(_catalogSimulator),
  };

  static String create(NewDevice device) => switch (device.kind) {
    DeviceKind.android => underSh(
      '${_set({'name': device.name, 'image': device.image, 'profile': device.profile})}$_fail'
      r'''
command -v avdmanager >/dev/null 2>&1 || { echo 'E no avdmanager'; exit 0; }
if out=$(echo no | avdmanager create avd -n "$name" -k "$image" -d "$profile" 2>&1); then echo OK; else fail "$out"; fi
''',
    ),
    DeviceKind.simulator => underSh(
      '${_set({'name': device.name, 'type': device.profile, 'runtime': device.image})}$_fail'
      r'''
if out=$(xcrun simctl create "$name" "$type" "$runtime" 2>&1 </dev/null); then echo OK; else fail "$out"; fi
''',
    ),
  };

  /// A path, not `-`: Xcode 27's `simctl` writes `-` as a file named `-` instead of
  /// stdout, and a path works on every `simctl` back to Xcode 8.2.
  static String capture(HostDevice device, String to) => switch (device.kind) {
    DeviceKind.android =>
      'adb -s ${shellQuote(device.id)} exec-out screencap -p >$to',
    DeviceKind.simulator =>
      'xcrun simctl io ${shellQuote(device.id)} screenshot --type=png $to',
  };

  static String frames(HostDevice device) => underSh('''
d=\$(mktemp -d) || exit 1
trap 'rm -rf "\$d"' EXIT
trap 'exit 0' HUP INT TERM PIPE
jpeg=
command -v sips >/dev/null 2>&1 && jpeg=1
last=
idle=0
while :; do
  if ! ${capture(device, r'"$d/f.png"')} 2>"\$d/err" </dev/null || [ ! -s "\$d/f.png" ]; then
    printf 'E %s\\n' "\$(head -c 200 "\$d/err" | tr '\\n' ' ')"
    exit 3
  fi
  sum=\$(cksum <"\$d/f.png")
  if [ "\$sum" != "\$last" ]; then
    last=\$sum
    set -- \$(od -An -tu1 -j16 -N8 "\$d/f.png")
    w=\$(( (\$1 << 24) + (\$2 << 16) + (\$3 << 8) + \$4 ))
    h=\$(( (\$5 << 24) + (\$6 << 16) + (\$7 << 8) + \$8 ))
    f=\$d/f.png
    if [ -n "\$jpeg" ] && sips -s format jpeg -s formatOptions 60 -Z 1200 "\$d/f.png" --out "\$d/f.jpg" >/dev/null 2>&1; then
      f=\$d/f.jpg
    fi
    printf 'F %s %s %s\\n' "\$w" "\$h" "\$(wc -c <"\$f" | tr -d ' ')"
    cat "\$f"
    idle=0
  else
    idle=\$((idle + 1))
    if [ "\$idle" -ge 8 ]; then
      idle=0
      printf 'K\\n'
    fi
  fi
  sleep 0.2
done
''');

  static String tap(HostDevice device, int x, int y) =>
      _input(device, 'tap $x $y');

  static String swipe(
    HostDevice device,
    int x1,
    int y1,
    int x2,
    int y2,
    Duration duration,
  ) => _input(device, 'swipe $x1 $y1 $x2 $y2 ${duration.inMilliseconds}');

  static String key(HostDevice device, String keycode) =>
      _input(device, 'keyevent $keycode');

  static String _input(HostDevice device, String args) =>
      'adb -s ${shellQuote(device.id)} shell input $args';
}

class DeviceFrame {
  const DeviceFrame({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;

  final Uint8List bytes;
}

class DeviceCaptureFailed implements Exception {
  const DeviceCaptureFailed(this.message);

  final String message;

  @override
  String toString() => 'DeviceCaptureFailed($message)';
}

class DeviceFrameDecoder extends StreamTransformerBase<List<int>, DeviceFrame> {
  const DeviceFrameDecoder();

  @override
  Stream<DeviceFrame> bind(Stream<List<int>> stream) {
    late final StreamController<DeviceFrame> out;
    StreamSubscription<List<int>>? source;
    final buffer = BytesBuilder(copy: false);
    var pending = Uint8List(0);
    ({int width, int height, int length})? header;

    void drain() {
      while (true) {
        final expected = header;
        if (expected != null) {
          if (pending.length < expected.length) return;
          out.add(
            DeviceFrame(
              width: expected.width,
              height: expected.height,
              bytes: Uint8List.sublistView(pending, 0, expected.length),
            ),
          );
          pending = Uint8List.sublistView(pending, expected.length);
          header = null;
          continue;
        }
        final newline = pending.indexOf(0x0A);
        if (newline < 0) return;
        final line = latin1.decode(Uint8List.sublistView(pending, 0, newline));
        pending = Uint8List.sublistView(pending, newline + 1);
        final parts = line.split(' ');
        switch (parts.first) {
          case 'F' when parts.length == 4:
            final width = int.tryParse(parts[1]);
            final height = int.tryParse(parts[2]);
            final length = int.tryParse(parts[3]);
            if (width == null || height == null || length == null) {
              out.addError(DeviceCaptureFailed('bad header: $line'));
              return;
            }
            header = (width: width, height: height, length: length);
          case 'E':
            out.addError(DeviceCaptureFailed(line.substring(1).trim()));
          case 'K' || '':
            break;
          default:
            out.addError(DeviceCaptureFailed('bad header: $line'));
            return;
        }
      }
    }

    out = StreamController<DeviceFrame>(
      onListen: () {
        source = stream.listen(
          (chunk) {
            buffer.add(chunk);
            final expected = header;
            if (expected != null &&
                pending.length + buffer.length < expected.length) {
              return;
            }
            final arrived = buffer.takeBytes();
            pending = pending.isEmpty
                ? arrived
                : (BytesBuilder(copy: false)
                        ..add(pending)
                        ..add(arrived))
                      .takeBytes();
            drain();
          },
          onError: out.addError,
          onDone: out.close,
        );
      },
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () => source?.cancel(),
    );
    return out.stream;
  }
}

abstract interface class DeviceLink {
  Future<List<HostDevice>> list();

  Stream<DeviceFrame> frames(HostDevice device);

  Future<void> run(String command);

  Future<String> read(String command, {Duration? limit});

  bool get closed;

  Future<void> close();
}

typedef DeviceLinkOpener = Future<DeviceLink> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
});

class DeviceSsh implements DeviceLink {
  @visibleForTesting
  DeviceSsh.over(SSHSocket socket, this._client)
    : _letGo = (() => unawaited(closeSsh(_client, socket))),
      _suspect = _trusted;

  DeviceSsh.borrowed(HostLease lease)
    : _client = lease.client,
      _letGo = lease.release,
      _suspect = lease.suspect;

  static const timeout = Duration(seconds: 10);

  final SSHClient _client;
  final void Function() _letGo;
  final void Function() _suspect;
  final _execs = <SSHSession>{};
  var _closed = false;

  @override
  Future<List<HostDevice>> list() async {
    final stdout = await _doubting(() => _run(DeviceCommands.list()));
    return parseDeviceList(utf8.decode(stdout, allowMalformed: true));
  }

  Future<SSHSession> _exec(String command) async {
    if (_closed) throw const HerdrUnreachable('device link closed');
    final SSHSession session;
    try {
      session = await _client.execute(command);
    } on SSHChannelOpenError catch (error) {
      throw HerdrBusy('$error');
    }
    if (_closed) {
      endExec(session);
      throw const HerdrUnreachable('device link closed');
    }
    _execs.add(session);
    return session;
  }

  static void _trusted() {}

  void _doubt() {
    if (!_closed) _suspect();
  }

  Future<T> _doubting<T>(Future<T> Function() body) async {
    try {
      return await _guard(body);
    } on HerdrBusy {
      rethrow;
    } catch (_) {
      _doubt();
      rethrow;
    }
  }

  void _end(SSHSession session) {
    _execs.remove(session);
    endExec(session);
  }

  Future<Uint8List> _run(String command) async {
    final session = await _exec(command);
    try {
      return await _drain(session);
    } finally {
      _end(session);
    }
  }

  static Future<Uint8List> _drain(SSHSession session) async {
    final out = BytesBuilder(copy: false);
    await Future.wait([
      session.stdout.cast<List<int>>().forEach(out.add),
      session.stderr.cast<List<int>>().drain<void>(),
      session.stdin.close(),
    ]);
    await session.done;
    return out.takeBytes();
  }

  @override
  Future<String> read(String command, {Duration? limit}) async {
    final session = await _doubting(() => _exec(command));
    var settled = false;
    Future<Uint8List> drained() async {
      try {
        return await _guard(() => _drain(session));
      } catch (_) {
        if (!settled) _doubt();
        rethrow;
      }
    }

    final pending = drained();
    try {
      final out = limit == null ? await pending : await pending.timeout(limit);
      return utf8.decode(out, allowMalformed: true);
    } on TimeoutException {
      pending.ignore();
      rethrow;
    } finally {
      settled = true;
      _end(session);
    }
  }

  @override
  Stream<DeviceFrame> frames(HostDevice device) {
    SSHSession? session;
    StreamSubscription<DeviceFrame>? inner;
    var cancelled = false;
    late final StreamController<DeviceFrame> out;
    out = StreamController<DeviceFrame>(
      onListen: () async {
        try {
          final opened = await _guard(
            () => _exec(DeviceCommands.frames(device)),
          );
          if (cancelled) {
            _end(opened);
            return;
          }
          session = opened;
          inner = opened.stdout
              .cast<List<int>>()
              .transform(const DeviceFrameDecoder())
              .listen(
                out.add,
                onError: (Object error, StackTrace stack) {
                  _doubt();
                  out.addError(error, stack);
                },
                onDone: () {
                  _doubt();
                  out.close();
                },
              );
        } catch (error, stack) {
          if (!cancelled && error is! HerdrBusy) _doubt();
          out.addError(error, stack);
          await out.close();
        }
      },
      onCancel: () async {
        cancelled = true;
        await inner?.cancel();
        if (session case final session?) _end(session);
      },
    );
    return out.stream;
  }

  @override
  Future<void> run(String command) async {
    await _doubting(() => _run(command));
  }

  @override
  bool get closed => _closed || _client.isClosed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final exec in [..._execs]) {
      _end(exec);
    }
    _letGo();
  }
}

Future<T> _guard<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asHerdrFailure(error, verifier?.refusal) ?? error;
  }
}
