@Tags(['host'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';

import 'fixture.dart';

void main() {
  final tunnel = ShellTunnel();

  late String key;

  setUpAll(() => key = hostVmPrivateKey());

  Future<ShellConnection> open({
    String? command,
    int columns = 80,
    int rows = 24,
  }) => tunnel.open(
    reason: UserAction(UserIntent.fromGesture()),
    address: hostVm.address,
    port: hostVm.port,
    user: hostVm.user,
    privateKey: key,
    columns: columns,
    rows: rows,
    command: command,
    verifier: trustGuest(),
  );

  test('the fixture key opens the guest login shell', () async {
    final connection = await open();
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    // The guest's prompt is `%n@%m:%~%#`, so its own hostname is the one string no echo of
    // ours could have produced.
    await readUntil(connection, 'upgrade-host');
    expect(connection.transport, ShellTransport.ssh);
    expect(connection.continuity, ShellContinuity.plain);
  });

  test('the pty is opened at the size the view asked for', () async {
    final connection = await open(command: 'stty size', columns: 100, rows: 30);
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    // Rows then columns, which is the order stty prints and the reverse of the order the
    // request carries them in.
    expect(await readUntil(connection, '30 100'), contains('30 100'));
  });

  test('a window change reaches the remote mid-session', () async {
    final connection = await open(columns: 80, rows: 24);
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
    await readUntil(connection, 'upgrade-host');

    connection.resize(120, 40);
    type(connection, 'stty size');

    expect(await readUntil(connection, '40 120'), contains('40 120'));
  });

  test('the command\'s own exit code comes back on the channel', () async {
    final connection = await open(command: 'exit 7');
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    expect(await connection.exitCode, 7);
  });

  test('an exec channel runs beside the shell without disturbing it', () async {
    final connection = await open();
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
    final prompt = await readUntil(connection, 'upgrade-host');

    final result = (await connection.channels.exec(
      'printf beside',
      timeout: remoteCommandDeadline,
    ))!;

    expect(result.exitCode, 0);
    expect(result.out, 'beside');
    expect(prompt, isNot(contains('beside')));
  });

  test('what a command reads on stdin is what was written to it', () async {
    final connection = await open();
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    final result = (await connection.channels.exec(
      'cat',
      stdin: Uint8List.fromList('one\ntwo\n'.codeUnits),
      timeout: remoteCommandDeadline,
    ))!;

    expect(result.ok, isTrue);
    expect(result.out, 'one\ntwo\n');
  });

  test('a key the guest has never seen is key rejected', () async {
    final stranger = await strangerPrivateKey();

    await expectLater(
      tunnel.open(
        reason: UserAction(UserIntent.fromGesture()),
        address: hostVm.address,
        port: hostVm.port,
        user: hostVm.user,
        privateKey: stranger,
        columns: 80,
        rows: 24,
        verifier: trustGuest(),
      ),
      throwsA(
        isA<ShellFailure>().having(
          (failure) => failure.kind,
          'kind',
          ShellFailureKind.keyRejected,
        ),
      ),
    );
  });

  test('a port with nothing behind it is unreachable', () async {
    await expectLater(
      tunnel.open(
        reason: UserAction(UserIntent.fromGesture()),
        address: hostVm.address,
        port: hostVmDeadPort,
        user: hostVm.user,
        privateKey: key,
        columns: 80,
        rows: 24,
        verifier: trustGuest(),
      ),
      throwsA(
        isA<ShellFailure>().having(
          (failure) => failure.kind,
          'kind',
          ShellFailureKind.unreachable,
        ),
      ),
    );
  });

  test('a name with no address behind it is unresolved', () async {
    await expectLater(
      tunnel.open(
        reason: UserAction(UserIntent.fromGesture()),
        address: 'no-such-host.invalid',
        port: hostVm.port,
        user: hostVm.user,
        privateKey: key,
        columns: 80,
        rows: 24,
        verifier: trustGuest(),
      ),
      throwsA(
        isA<ShellFailure>().having(
          (failure) => failure.kind,
          'kind',
          ShellFailureKind.unresolved,
        ),
      ),
    );
  });
}
