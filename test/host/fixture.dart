import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dazzle/platform/keys.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';

/// Where the `host` tier's machine is.
///
/// The NixOS guest from `nix run .#host-vm`, which `just test-host` brings up.
/// It is the only machine these tests may touch: its firewall rejects every
/// outbound packet, so a test that reached past it could not.
const hostVm = (address: '127.0.0.1', port: 2222, user: 'dev');

/// A port on the guest's address with nothing listening on it, for the
/// failures that are about a machine that does not answer.
const hostVmDeadPort = 2223;

/// The fixture key's private half, committed beside the VM config that trusts
/// it. Read from disk rather than pasted in, so the pair cannot drift apart.
String hostVmPrivateKey() =>
    File('nix/fixtures/host_vm_test_key').readAsStringSync();

/// A well-formed key the guest has never heard of, for the refusal that is
/// about the key and not about the connection.
Future<String> strangerPrivateKey() async {
  final keys = Ed25519Keys(MemoryPrivateKeyStore());
  await keys.generate(id: 'stranger', name: 'stranger');
  return (await keys.privateKey('stranger'))!;
}

/// Reads [connection] until [want] has gone by, and hands back everything seen
/// up to that point.
///
/// A remote writes when it feels like it: the prompt can arrive in one chunk
/// or in six, and the line a command prints can be split across the shell's
/// echo of the command itself. So the wait is on the whole transcript rather
/// than on any one chunk, and a timeout reports the transcript, which is the
/// difference between a failure that can be read and one that says `null`.
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

/// What the user typing [line] and pressing return puts on the wire.
void type(ShellConnection connection, String line) =>
    connection.write(utf8.encode('$line\n'));
