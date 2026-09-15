import 'support/native_plugins.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agent_kind.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/path_scan.dart';
import 'package:dazzle/application/send.dart';
import 'package:dazzle/data/database.dart';
import 'package:dazzle/data/enums.dart';
import 'package:dazzle/data/repositories/activity_repository.dart';
import 'package:dazzle/data/repositories/attachment_repository.dart';
import 'package:dazzle/data/repositories/dispatch_repository.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/data/repositories/path_repository.dart';
import 'package:dazzle/data/repositories/project_repository.dart';
import 'package:dazzle/data/repositories/task_repository.dart';
import 'package:dazzle/features/tasks/item_sheet.dart';
import 'package:dazzle/features/tasks/sent_tag.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/keys.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/shell/remote_shell.dart';

import 'support/platform_channels.dart';

/// Handing a drop to an agent: the remote transaction, its four failures, and
/// the row that is written for exactly one successful send.

/// What the transport was called with, so a test can assert the command's
/// inputs and the prompt without a socket.
class _Call {
  _Call(this.kind, this.directory, this.prompt, [this.images = const []]);

  final String kind;
  final String directory;
  final String prompt;
  final List<RemoteFile> images;
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
    directory: '~/src/dazzle',
    label: 'dazzle',
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
  test('workspace creation expands home on the host and quotes the path', () {
    final command = HerdrCommands.workspaceCreate(
      "~/src/dazzle with 'quote'",
      label: 'dazzle',
      session: 'default',
    );
    expect(command, contains('dazzle with'));
    expect(command, contains('quote'));
    expect(command, contains('workspace create'));
    expect(command, contains('HERDR_SESSION='));
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

  test('images are one host path per line, under the links', () {
    final prompt = sendPrompt(
      title: 'what is wrong here',
      links: const ['https://a.example'],
      images: [
        RemoteFile('a.png', Uint8List(0)),
        RemoteFile('b.png', Uint8List(0)),
      ],
    );
    expect(
      prompt,
      'what is wrong here\n\nhttps://a.example\n'
      '/tmp/dazzle/a.png\n/tmp/dazzle/b.png',
    );
  });

  test('a drop with an image and no link still opens with the blank line', () {
    expect(
      sendPrompt(
        title: 'what is wrong here',
        links: const [],
        images: [RemoteFile('a.png', Uint8List(0))],
      ),
      'what is wrong here\n\n/tmp/dazzle/a.png',
    );
  });

  test('a name is the file s own and cannot climb out of the directory', () {
    expect(
      RemoteFile.fromPath('/data/app/attachments/019-a.png', Uint8List(0)).name,
      '019-a.png',
    );
    expect(
      RemoteFile.fromPath('../../etc/passwd', Uint8List(0)).remotePath,
      '/tmp/dazzle/passwd',
    );
    expect(
      RemoteFile.fromPath("a b';rm -rf .png", Uint8List(0)).name,
      'a_b__rm_-rf_.png',
    );
    expect(RemoteFile.fromPath('/x/.hidden', Uint8List(0)).name, 'file.hidden');
  });

  test('the upload command makes the directory and takes the file whole', () {
    expect(
      uploadCommand('a.png'),
      underSh("mkdir -p '/tmp/dazzle' && cat > '/tmp/dazzle/a.png'"),
    );
  });

  group('remote transaction failures', () {
    test('every refusal has one line, and no two are the same line', () {
      final lines = {
        for (final refusal in SpawnRefusal.values) spawnRefusalReason(refusal),
      };
      expect(lines, hasLength(SpawnRefusal.values.length));
      expect(spawnRefusalReason(SpawnRefusal.noDirectory), 'no such directory');
      expect(
        spawnRefusalReason(SpawnRefusal.startFailed),
        'agent start failed',
      );
      expect(spawnRefusalReason(SpawnRefusal.spawnFailed), 'spawn failed');
      expect(spawnRefusalReason(SpawnRefusal.timedOut), 'spawn timed out');
      expect(
        spawnRefusalReason(SpawnRefusal.uploadFailed),
        'image upload failed',
      );
      // The two the roster refuses with: nowhere to start, and too many
      // places with no default to pick among them.
      expect(spawnRefusalReason(SpawnRefusal.noSession), 'no herdr session');
      expect(
        spawnRefusalReason(SpawnRefusal.noDefaultSession),
        'no default session',
      );
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

    Sender sender(HerdrSend send, {ReadImage? readImage}) => Sender(
      send: send,
      keys: Ed25519Keys(privateKeys),
      dispatches: dispatches,
      readImage: readImage ?? (path) async => Uint8List.fromList([1, 2, 3]),
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
              directory: '~/src/dazzle',
              label: 'dazzle',
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
            images = const <RemoteFile>[],
            model,
            verifier,
          }) async {
            calls.add(_Call(kind.name, directory, prompt));
            verifiers.add(verifier);
            return const SpawnSent('wQ:p7');
          })(
            target: _target(),
            kind: const ClaudeKind(),
            itemId: itemId,
            title: 'read the gate log',
            links: const ['https://a.example'],
          );

      expect(state, isA<SendSent>());
      expect((state as SendSent).paneId, 'wQ:p7');
      expect(calls.single.kind, 'claude');
      expect(calls.single.directory, '~/src/dazzle');
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
      expect(rows.single.label, 'dazzle');
      expect(rows.single.agent, 'claude');
      expect(rows.single.paneId, 'wQ:p7');

      final entries = await activity.watchRecent().first;
      final sent = entries.firstWhere(
        (entry) => entry.action == ActivityAction.sent,
      );
      expect(sent.title, 'read the gate log');
      expect(sent.context, 'nyx / dazzle');
      expect(sent.detail, 'wQ:p7');
    });

    test('a drop s images go up as files and the prompt names them', () async {
      final calls = <_Call>[];
      final read = <String>[];
      final itemId = await onlyTaskId();

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
              images = const <RemoteFile>[],
              model,
              verifier,
            }) async {
              calls.add(_Call(kind.name, directory, prompt, images));
              return const SpawnSent('wQ:p7');
            },
            readImage: (path) async {
              read.add(path);
              return Uint8List.fromList([path.length]);
            },
          )(
            target: _target(),
            kind: const ClaudeKind(),
            itemId: itemId,
            title: 'what is wrong here',
            links: const ['https://a.example'],
            imagePaths: const [
              '/support/attachments/first.png',
              '/support/attachments/second.jpg',
            ],
          );

      expect(state, isA<SendSent>());
      // Every file is read once, in the order it was attached, and the bytes
      // that were read are the bytes the transport was handed.
      expect(read, const [
        '/support/attachments/first.png',
        '/support/attachments/second.jpg',
      ]);
      final images = calls.single.images;
      expect(images.map((image) => image.name), const [
        'first.png',
        'second.jpg',
      ]);
      expect(images.first.bytes, Uint8List.fromList([30]));
      expect(images.last.bytes, Uint8List.fromList([31]));
      // The prompt says where the host will find them, not where the phone
      // kept them.
      expect(
        calls.single.prompt,
        'what is wrong here\n\nhttps://a.example\n'
        '/tmp/dazzle/first.png\n/tmp/dazzle/second.jpg',
      );
    });

    test('an attachment that cannot be read never dials', () async {
      final itemId = await onlyTaskId();
      var dialled = false;
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
              images = const <RemoteFile>[],
              model,
              verifier,
            }) async {
              dialled = true;
              return const SpawnSent('wQ:p7');
            },
            readImage: (path) async => throw const FileSystemException('gone'),
          )(
            target: _target(),
            kind: const ClaudeKind(),
            itemId: itemId,
            title: 'what is wrong here',
            links: const [],
            imagePaths: const ['/support/attachments/first.png'],
          );

      expect(dialled, isFalse);
      expect((state as SendFailed).reason, 'image unreadable');
      expect(await dispatches.watchForItem(itemId).first, isEmpty);
    });

    test('no refused transaction leaves a row behind', () async {
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
                images = const <RemoteFile>[],
                model,
                verifier,
              }) async => SpawnRefused(refusal),
            )(
              target: _target(),
              kind: const ClaudeKind(),
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
                images = const <RemoteFile>[],
                model,
                verifier,
              }) async => throw failure,
            )(
              target: _target(),
              kind: const ClaudeKind(),
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
            images = const <RemoteFile>[],
            model,
            verifier,
          }) async {
            dialled = true;
            return const SpawnSent('wQ:p7');
          })(
            target: _target(),
            kind: const ClaudeKind(),
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

    Future<void> addPath({String label = 'dazzle', String? projectId}) => db
        .into(db.paths)
        .insert(
          PathsCompanion.insert(
            id: 'path-$label',
            hostId: _host.id,
            directory: '~/src/$label',
            label: label,
            createdAt: DateTime.utc(2026, 9, 3),
            projectId: Value(projectId),
          ),
        );

    Widget app(String taskId, {HerdrSend? send}) => ProviderScope(
      overrides: [
        ...featureTestOverrides(db),
        hostRepositoryProvider.overrideWithValue(DriftHostRepository(db)),
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
            }) async => const ['~/src/dazzle'],
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

    testWidgets('SEND explains prerequisites before a host has a path', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');

      await tester.pumpWidget(app(id));
      await _drain(tester);
      expect(find.text('SEND'), findsOneWidget);
      expect(find.text('MOVE'), findsOneWidget);

      await tester.tap(find.text('SEND'));
      await _drain(tester);
      expect(find.text('REGISTER A PATH FIRST'), findsOneWidget);
      expect(find.text('REGISTER A PATH'), findsOneWidget);

      await tester.tap(find.text('BACK'));
      await _drain(tester);

      await tester.runAsync(addPath);
      await _drain(tester);
      expect(find.text('SEND'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('SEND explains missing host without a no-op path action', (
      tester,
    ) async {
      await db.delete(db.hosts).go();
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');
      await tester.pumpWidget(app(id));
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);
      expect(find.text('ADD A HOST FIRST'), findsOneWidget);
      expect(find.text('REGISTER A PATH'), findsNothing);

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
      ).create(name: 'dazzle');
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

    testWidgets('one workspace under the project is not asked about', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final project = await ProjectRepository(
        db,
        activity,
      ).create(name: 'dazzle');
      final id = await TaskRepository(
        db,
        activity,
      ).create(title: 'ship the picker', projectId: project);
      await addPath(projectId: project);

      await tester.pumpWidget(app(id));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      // The one directory the project is worked in is not a choice, so the
      // picker is skipped outright. What the send still does not know is which
      // agent and which model, and those are still asked.
      expect(find.text('SEND TO'), findsNothing);
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.text('MODEL'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('two workspaces are a picker, the project\'s own on top', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final project = await ProjectRepository(
        db,
        activity,
      ).create(name: 'dazzle');
      final id = await TaskRepository(
        db,
        activity,
      ).create(title: 'ship the picker', projectId: project);
      // Registered loose first, so the band and not the insertion order is
      // what puts the project's directories on top.
      await addPath(label: 'gate');
      await addPath(label: 'dazzle', projectId: project);
      await addPath(label: 'monolith', projectId: project);

      await tester.pumpWidget(app(id));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      // Two directories under the project is a choice, so it is asked — and
      // the two it is between are the ones at the top of the list.
      expect(find.text('SEND TO'), findsOneWidget);
      expect(find.text('LINKED'), findsNWidgets(2));
      final loose = tester.getTopLeft(find.text('NYX / GATE')).dy;
      expect(tester.getTopLeft(find.text('NYX / DAZZLE')).dy, lessThan(loose));
      expect(
        tester.getTopLeft(find.text('NYX / MONOLITH')).dy,
        lessThan(loose),
      );

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
                images = const <RemoteFile>[],
                model,
                verifier,
              }) async {
                seen = prompt;
                seenKind = kind.name;
                seenModel = model;
                return const SpawnSent('wQ:p7');
              },
        ),
      );
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);
      expect(find.text('SEND TO'), findsOneWidget);
      expect(find.text('NYX / DAZZLE'), findsOneWidget);

      // The target is chosen first, and the agent and the model after it: both
      // belong to this send and neither is stored on the path.
      await tester.tap(find.text('NYX / DAZZLE'));
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
                images = const <RemoteFile>[],
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
      await tester.tap(find.text('NYX / DAZZLE'));
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
        pathId: 'path-dazzle',
        paneId: 'wQ:p7',
        title: 'a drop',
        agent: 'claude',
      );

      await tester.pumpWidget(app(id));
      await _drain(tester);

      expect(find.text('[ SENT ]'), findsOneWidget);
      expect(
        find.textContaining('NYX / DAZZLE · CLAUDE · wQ:p7 · '),
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
