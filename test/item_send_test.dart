import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/path_scan.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/application/send.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/activity_repository.dart';
import 'package:hotline/data/repositories/attachment_repository.dart';
import 'package:hotline/data/repositories/dispatch_repository.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/path_repository.dart';
import 'package:hotline/data/repositories/project_repository.dart';
import 'package:hotline/data/repositories/task_repository.dart';
import 'package:hotline/features/tasks/item_sheet.dart';
import 'package:hotline/features/tasks/sent_tag.dart';
import 'package:hotline/platform/herdr_client.dart';
import 'package:hotline/platform/keys.dart';
import 'package:hotline/platform/host_keys.dart';

import 'support/platform_channels.dart';

/// Handing a drop to an agent: the verb on the wire, the four answers the gate
/// can give, and the row that is written for exactly one of them.

/// What the transport was called with, so a test can assert the command's
/// inputs and the prompt without a socket.
class _Call {
  _Call(this.kind, this.directory, this.prompt);

  final String kind;
  final String directory;
  final String prompt;
}

Host _host = const Host(
  id: 'host-1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'luisnquin',
  keyId: 'key-1',
);

PathTarget _target() => PathTarget(
  path: AgentPath(
    id: 'path-1',
    hostId: _host.id,
    directory: '~/src/hotline',
    label: 'hotline',
    createdAt: DateTime.utc(2026, 9, 3),
  ),
  host: _host,
);

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('the verb is the gate command, unquoted', () {
    expect(
      HerdrCommands.spawn('claude', null, '~/src/hotline'),
      'agent spawn claude - ~/src/hotline',
    );
  });

  test('the prompt is the title, a blank line, then one link per line', () {
    final prompt = sendPrompt(
      title: 'read the gate log',
      links: const ['https://a.example', 'https://b.example'],
    );
    expect(prompt, 'read the gate log\n\nhttps://a.example\nhttps://b.example');
    // What goes on stdin is this string and nothing more: no trailing newline
    // to be read as an empty last link, and no framing.
    expect(utf8.encode(prompt), utf8.encode(prompt));
    expect(utf8.decode(utf8.encode(prompt)), prompt);
  });

  test('a drop with no links is its title alone', () {
    expect(
      sendPrompt(title: 'read the gate log', links: const []),
      'read the gate log',
    );
  });

  group('what the gate answered', () {
    test('exit 0 with a pane line is a send', () {
      final result = HerdrClient.readSpawn(
        exitCode: 0,
        stdout: 'wQ:p7\n',
        stderr: '',
      );
      expect(result, isA<SpawnSent>());
      expect((result as SpawnSent).paneId, 'wQ:p7');
    });

    test('exit 0 with nothing said is not a send', () {
      final result = HerdrClient.readSpawn(exitCode: 0, stdout: '', stderr: '');
      expect(
        result,
        isA<SpawnRefused>().having(
          (r) => r.refusal,
          'refusal',
          SpawnRefusal.spawnFailed,
        ),
      );
    });

    test('a refused directory is told apart from any other refusal', () {
      expect(
        HerdrClient.readSpawn(
          exitCode: 1,
          stdout: '',
          stderr: 'denied: dir ~/src/hotline\n',
        ),
        isA<SpawnRefused>().having(
          (r) => r.refusal,
          'refusal',
          SpawnRefusal.noDirectory,
        ),
      );
      expect(
        HerdrClient.readSpawn(
          exitCode: 1,
          stdout: '',
          stderr: 'denied: kind gemini\n',
        ),
        isA<SpawnRefused>().having(
          (r) => r.refusal,
          'refusal',
          SpawnRefusal.gateRefused,
        ),
      );
    });

    test('a non-zero exit the gate did not explain is a failed spawn', () {
      expect(
        HerdrClient.readSpawn(
          exitCode: 127,
          stdout: '',
          stderr: 'agent: command not found\n',
        ),
        isA<SpawnRefused>().having(
          (r) => r.refusal,
          'refusal',
          SpawnRefusal.spawnFailed,
        ),
      );
    });

    test('every refusal has one line, and they are four different lines', () {
      final lines = {
        for (final refusal in SpawnRefusal.values) spawnRefusalReason(refusal),
      };
      expect(lines, hasLength(SpawnRefusal.values.length));
      expect(spawnRefusalReason(SpawnRefusal.noDirectory), 'no such directory');
      expect(spawnRefusalReason(SpawnRefusal.gateRefused), 'gate refused');
      expect(spawnRefusalReason(SpawnRefusal.spawnFailed), 'spawn failed');
      expect(spawnRefusalReason(SpawnRefusal.timedOut), 'spawn timed out');
    });
  });

  group('the send', () {
    late AppDatabase db;
    late DispatchRepository dispatches;
    late ActivityRepository activity;
    late MemoryPrivateKeyStore privateKeys;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      activity = ActivityRepository(db);
      dispatches = DriftDispatchRepository(db, activity);
      privateKeys = MemoryPrivateKeyStore();
      await privateKeys.write('key-1', 'PEM');
      await TaskRepository(db, activity).create(title: 'read the gate log');
      await db
          .into(db.keys)
          .insert(
            KeysCompanion.insert(
              id: 'key-1',
              name: 'nyx',
              publicKey: 'ssh-ed25519 AAAATEST',
              fingerprint: 'SHA256:key-1',
              createdAt: DateTime.utc(2026),
            ),
          );
      await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              id: _host.id,
              name: _host.name,
              address: _host.address,
              user: _host.user,
              keyId: _host.keyId,
            ),
          );
    });

    tearDown(() => db.close());

    Future<String> onlyTaskId() async {
      final rows = await db.select(db.tasks).get();
      return rows.single.id;
    }

    Sender sender(HerdrSend send) => Sender(
      send: send,
      keys: Ed25519Keys(privateKeys),
      dispatches: dispatches,
    );

    test('a pane id is a row, and the row says where it went', () async {
      final calls = <_Call>[];
      final verifiers = <HostKeyVerifier?>[];
      final itemId = await onlyTaskId();
      await db
          .into(db.paths)
          .insert(
            PathsCompanion.insert(
              id: 'path-1',
              hostId: _host.id,
              directory: '~/src/hotline',
              label: 'hotline',
              createdAt: DateTime.utc(2026, 9, 3),
            ),
          );

      final state =
          await sender(({
            required address,
            required port,
            required user,
            required privateKey,
            required kind,
            required directory,
            required prompt,
            model,
            verifier,
          }) async {
            calls.add(_Call(kind, directory, prompt));
            verifiers.add(verifier);
            return const SpawnSent('wQ:p7');
          })(
            target: _target(),
            kind: 'claude',
            itemId: itemId,
            title: 'read the gate log',
            links: const ['https://a.example'],
          );

      expect(state, isA<SendSent>());
      expect((state as SendSent).paneId, 'wQ:p7');
      expect(calls.single.kind, 'claude');
      expect(calls.single.directory, '~/src/hotline');
      expect(calls.single.prompt, 'read the gate log\n\nhttps://a.example');

      // A send goes out from a list the user tapped, not from a route showing
      // a fingerprint, so an unpinned host is refused here as it is on every
      // other path nobody is watching.
      final verifier = verifiers.single!;
      expect(verifier.prompt, isNull);
      expect(
        await verifier.verifyFingerprint('ssh-ed25519', 'SHA256:whatever'),
        isFalse,
      );
      expect(verifier.refusal, HostKeyRefusal.unverified);

      final rows = await dispatches.watchForItem(itemId).first;
      expect(rows, hasLength(1));
      expect(rows.single.hostName, 'nyx');
      expect(rows.single.label, 'hotline');
      expect(rows.single.agent, 'claude');
      expect(rows.single.paneId, 'wQ:p7');

      final entries = await activity.watchRecent().first;
      final sent = entries.firstWhere(
        (entry) => entry.action == ActivityAction.sent,
      );
      expect(sent.title, 'read the gate log');
      expect(sent.context, 'nyx / hotline');
      expect(sent.detail, 'wQ:p7');
    });

    test('nothing the gate refused leaves a row behind', () async {
      final itemId = await onlyTaskId();
      for (final refusal in SpawnRefusal.values) {
        final state =
            await sender(
              ({
                required address,
                required port,
                required user,
                required privateKey,
                required kind,
                required directory,
                required prompt,
                model,
                verifier,
              }) async => SpawnRefused(refusal),
            )(
              target: _target(),
              kind: 'claude',
              itemId: itemId,
              title: 'read the gate log',
              links: const [],
            );
        expect(state, isA<SendFailed>());
        expect((state as SendFailed).reason, spawnRefusalReason(refusal));
      }
      expect(await dispatches.watchForItem(itemId).first, isEmpty);
      expect(await dispatches.watchSentItems().first, isEmpty);
    });

    test('a connection that never opened keeps the words the panel uses', () async {
      final itemId = await onlyTaskId();
      // The sender answers with a state rather than rethrowing, so each failure
      // is read off the state's line.
      Future<String> reasonFor(HerdrFailure failure) async {
        final state =
            await sender(
              ({
                required address,
                required port,
                required user,
                required privateKey,
                required kind,
                required directory,
                required prompt,
                model,
                verifier,
              }) async => throw failure,
            )(
              target: _target(),
              kind: 'claude',
              itemId: itemId,
              title: 'read the gate log',
              links: const [],
            );
        return (state as SendFailed).reason;
      }

      expect(await reasonFor(const HerdrUnreachable()), 'nyx unreachable');
      expect(await reasonFor(const HerdrUnresolved()), 'nyx unresolved');
      expect(await reasonFor(const HerdrKeyRejected()), 'key rejected');
      expect(await reasonFor(const HerdrProtocolMismatch(22)), 'protocol 22');
      expect(await dispatches.watchForItem(itemId).first, isEmpty);
    });

    test('a host whose key is gone never dials', () async {
      final itemId = await onlyTaskId();
      await privateKeys.delete('key-1');
      var dialled = false;
      final state =
          await sender(({
            required address,
            required port,
            required user,
            required privateKey,
            required kind,
            required directory,
            required prompt,
            model,
            verifier,
          }) async {
            dialled = true;
            return const SpawnSent('wQ:p7');
          })(
            target: _target(),
            kind: 'claude',
            itemId: itemId,
            title: 'read the gate log',
            links: const [],
          );
      expect(dialled, isFalse);
      expect((state as SendFailed).reason, 'key rejected');
    });
  });

  group('the quick view', () {
    late AppDatabase db;
    late MemoryPrivateKeyStore privateKeys;

    setUp(() async {
      stubDeviceChannels();
      db = AppDatabase(NativeDatabase.memory());
      privateKeys = MemoryPrivateKeyStore();
      await privateKeys.write('key-1', 'PEM');
      await db
          .into(db.keys)
          .insert(
            KeysCompanion.insert(
              id: 'key-1',
              name: 'nyx',
              publicKey: 'ssh-ed25519 AAAATEST',
              fingerprint: 'SHA256:key-1',
              createdAt: DateTime.utc(2026),
            ),
          );
      await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              id: _host.id,
              name: _host.name,
              address: _host.address,
              user: _host.user,
              keyId: _host.keyId,
            ),
          );
    });

    tearDown(() => db.close());

    Future<void> addPath({String label = 'hotline'}) => db
        .into(db.paths)
        .insert(
          PathsCompanion.insert(
            id: 'path-$label',
            hostId: _host.id,
            directory: '~/src/$label',
            label: label,
            createdAt: DateTime.utc(2026, 9, 3),
          ),
        );

    Widget app(String taskId, {HerdrSend? send}) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        privateKeyStoreProvider.overrideWithValue(privateKeys),
        if (send != null) herdrSendProvider.overrideWithValue(send),
        pathScannerProvider.overrideWithValue(
          PathScanner(
            fetch: ({
              required address,
              required port,
              required user,
              required privateKey,
              verifier,
            }) async => const ['~/src/hotline'],
            fetchModels: ({
              required address,
              required port,
              required user,
              required privateKey,
              required kind,
              verifier,
            }) async => const ['opus', 'sonnet'],
            keys: Ed25519Keys(privateKeys),
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: ItemSheet(taskId: taskId)),
      ),
    );

    testWidgets('SEND is absent until a host has a path', (tester) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');

      await tester.pumpWidget(app(id));
      await _drain(tester);
      expect(find.text('SEND'), findsNothing);
      expect(find.text('MOVE'), findsOneWidget);

      await tester.runAsync(addPath);
      await _drain(tester);
      expect(find.text('SEND'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('an item filed under a project can still be sent', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final project = await ProjectRepository(
        db,
        activity,
      ).create(name: 'hotline');
      final id = await TaskRepository(
        db,
        activity,
      ).create(title: 'ship the picker', projectId: project);
      await addPath();

      await tester.pumpWidget(app(id));
      await _drain(tester);

      // The project's own state verbs are there, and SEND with them: filing
      // an item is not what decides whether an agent can pick it up.
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('SEND'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the picker offers host and label, and the send says where it '
        'landed', (tester) async {
      final activity = ActivityRepository(db);
      final tasks = TaskRepository(db, activity);
      final id = await tasks.create(title: 'read the gate log');
      await AttachmentRepository(db).create(
        itemId: id,
        kind: AttachmentKind.url,
        value: 'https://a.example',
      );
      await addPath();

      String? seen;
      String? seenKind;
      String? seenModel;
      await tester.pumpWidget(
        app(
          id,
          send:
              ({
                required address,
                required port,
                required user,
                required privateKey,
                required kind,
                required directory,
                required prompt,
                model,
                verifier,
              }) async {
                seen = prompt;
                seenKind = kind;
                seenModel = model;
                return const SpawnSent('wQ:p7');
              },
        ),
      );
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);
      expect(find.text('SEND TO'), findsOneWidget);
      expect(find.text('NYX / HOTLINE'), findsOneWidget);

      // The target is chosen first, and the agent and the model after it: both
      // belong to this send and neither is stored on the path.
      await tester.tap(find.text('NYX / HOTLINE'));
      await _drain(tester);
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.text('MODEL'), findsOneWidget);
      await tester.tap(find.text('SONNET'));
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(seenKind, 'claude');
      expect(seenModel, 'sonnet');
      expect(seen, 'read the gate log\n\nhttps://a.example');
      expect(find.text('SENT · wQ:p7'), findsOneWidget);
      expect(find.text('CLOSE'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a refusal is one line and a retry', (tester) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');
      await addPath();
      var attempts = 0;

      await tester.pumpWidget(
        app(
          id,
          send:
              ({
                required address,
                required port,
                required user,
                required privateKey,
                required kind,
                required directory,
                required prompt,
                model,
                verifier,
              }) async {
                attempts++;
                return attempts == 1
                    ? const SpawnRefused(SpawnRefusal.noDirectory)
                    : const SpawnSent('wQ:p9');
              },
        ),
      );
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);
      await tester.tap(find.text('NYX / HOTLINE'));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(find.text('no such directory'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);

      await tester.tap(find.text('RETRY'));
      await _drain(tester);
      expect(attempts, 2);
      expect(find.text('SENT · wQ:p9'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the sheet keeps what was sent, and the row is tagged', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');
      await addPath();
      await DriftDispatchRepository(db, activity).record(
        itemId: id,
        pathId: 'path-hotline',
        paneId: 'wQ:p7',
        title: 'a drop',
        agent: 'claude',
      );

      await tester.pumpWidget(app(id));
      await _drain(tester);

      expect(find.text('[ SENT ]'), findsOneWidget);
      expect(
        find.textContaining('NYX / HOTLINE · CLAUDE · wQ:p7 · '),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the tag is a word at the trailing edge', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SentTag())),
      );
      expect(find.text('SENT'), findsOneWidget);
    });
  });
}
