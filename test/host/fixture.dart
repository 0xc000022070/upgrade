import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/keys.dart';
import 'package:striked/platform/shell/shell_connection.dart';

/// The NixOS guest from `nix run .#host-vm`, which `just test-host` brings up. It is the
/// only machine these tests may touch: its firewall rejects every outbound packet.
const hostVm = (address: '127.0.0.1', port: 2222, user: 'dev');

const hostVmDeadPort = 2223;

/// Read from disk rather than pasted in, so the pair cannot drift apart.
String hostVmPrivateKey() =>
    File('nix/host-vm/fixtures/host_vm_test_key').readAsStringSync();

HostKeyVerifier trustGuest() => HostKeyVerifier(prompt: (_, _) async => true);

Future<String> strangerPrivateKey() async {
  final keys = Ed25519Keys(MemoryPrivateKeyStore());
  await keys.generate(id: 'stranger', name: 'stranger');
  return (await keys.privateKey('stranger'))!;
}

/// A remote writes when it feels like it: the prompt can arrive in one chunk or in six,
/// and a command's output can be split across the shell's echo of the command itself.
Future<String> readUntil(
  ShellConnection connection,
  Pattern want, {
  Duration timeout = const Duration(seconds: 20),
}) {
  final seen = StringBuffer();
  final found = Completer<String>();
  final subscription = connection.output.listen(
    (bytes) {
      seen.write(utf8.decode(bytes, allowMalformed: true));
      if (seen.toString().contains(want) && !found.isCompleted) {
        found.complete(seen.toString());
      }
    },
    onDone: () {
      if (!found.isCompleted) {
        found.completeError(
          StateError('the channel ended before `$want`, having said:\n$seen'),
        );
      }
    },
  );
  return found.future
      .timeout(
        timeout,
        onTimeout: () =>
            throw TimeoutException('never saw `$want`, having read:\n$seen'),
      )
      .whenComplete(subscription.cancel);
}

void type(ShellConnection connection, String line) =>
    connection.write(utf8.encode('$line\n'));
