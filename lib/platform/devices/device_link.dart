import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../herdr_client.dart';
import '../host_keys.dart';
import '../shell/remote_shell.dart';
import '../ssh_settle.dart';

enum DeviceKind { android, simulator }

class HostDevice {
  const HostDevice({required this.kind, required this.id, required this.name});

  final DeviceKind kind;

  final String id;
  final String name;

  bool get pressable => kind == DeviceKind.android;

  @override
  bool operator ==(Object other) =>
      other is HostDevice && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

List<HostDevice> parseDeviceList(String output) {
  final devices = <HostDevice>[];
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^([AI]) (\S+) ?(.*)$').firstMatch(line.trim());
    if (match == null) continue;
    final id = match.group(2)!;
    final name = match.group(3)!.trim();
    devices.add(
      HostDevice(
        kind: match.group(1) == 'A' ? DeviceKind.android : DeviceKind.simulator,
        id: id,
        name: name.isEmpty ? id : name,
      ),
    );
  }
  return devices;
}

abstract final class DeviceCommands {
  static String list() => underSh(r'''
if command -v adb >/dev/null 2>&1; then
  adb devices </dev/null | while read -r s state; do
    [ "$state" = device ] || continue
    n=$(adb -s "$s" emu avd name </dev/null 2>/dev/null | head -n 1 | tr -d '\r')
    [ -n "$n" ] || n=$(adb -s "$s" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r')
    printf 'A %s %s\n' "$s" "$n"
  done
fi
if command -v xcrun >/dev/null 2>&1; then
  xcrun simctl list devices booted </dev/null 2>/dev/null |
    sed -n 's/^ *\(.*\) (\([0-9A-Fa-f-]\{36\}\)) (Booted).*/I \2 \1/p'
fi
''');

  static String capture(HostDevice device) => switch (device.kind) {
    DeviceKind.android =>
      'adb -s ${shellQuote(device.id)} exec-out screencap -p',
    DeviceKind.simulator =>
      'xcrun simctl io ${shellQuote(device.id)} screenshot --type=png -',
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
  if ! ${capture(device)} >"\$d/f.png" 2>"\$d/err" </dev/null || [ ! -s "\$d/f.png" ]; then
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

  Future<void> close();
}

typedef DeviceLinkOpener = Future<DeviceLink> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

class DeviceSsh implements DeviceLink {
  DeviceSsh._(this._socket, this._client);

  static const timeout = Duration(seconds: 10);

  final SSHSocket _socket;
  final SSHClient _client;
  var _closed = false;

  static Future<DeviceLink> open({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final socket = await _guard(
      () => SSHSocket.connect(address, port, timeout: timeout),
      verifier,
    );
    final client = SSHClient(
      socket,
      username: user,
      identities: SSHKeyPair.fromPem(privateKey),
      handshakeTimeout: timeout,
      authTimeout: timeout,
      keepAliveInterval: sshKeepAlive,
      onVerifyHostKey: verifier?.verify,
    );
    try {
      await _guard(() => client.authenticated, verifier);
      return DeviceSsh._(socket, client);
    } on HerdrFailure {
      unawaited(closeSsh(client, socket));
      rethrow;
    }
  }

  @override
  Future<List<HostDevice>> list() async {
    final result = await _guard(
      () => _client.runWithResult(DeviceCommands.list()),
    );
    return parseDeviceList(utf8.decode(result.stdout, allowMalformed: true));
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
            () => _client.execute(DeviceCommands.frames(device)),
          );
          if (cancelled) {
            opened.close();
            return;
          }
          session = opened;
          inner = opened.stdout
              .cast<List<int>>()
              .transform(const DeviceFrameDecoder())
              .listen(out.add, onError: out.addError, onDone: out.close);
        } catch (error, stack) {
          out.addError(error, stack);
          await out.close();
        }
      },
      onCancel: () async {
        cancelled = true;
        await inner?.cancel();
        session?.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> run(String command) async {
    await _guard(() => _client.runWithResult(command));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(closeSsh(_client, _socket));
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
