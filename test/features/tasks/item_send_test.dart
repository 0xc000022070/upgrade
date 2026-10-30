import '../../support/native_plugins.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agent_kind.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/shell/path_scan.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/features/tasks/item_sheet.dart';
import 'package:upgrade/features/tasks/item_tags.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

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
    directory: '~/src/upgrade',
    label: 'upgrade',
    createdAt: DateTime.utc(2026, 9, 3),
  ),
  host: _host,
);

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('workspace creation carries the path home was expanded in', () {
    // The `~` is expanded on the host first, by the one command that also proves the
    // directory is there.
    expect(
      HerdrCommands.resolveDirectory("~/src/upgrade with 'quote'"),
      contains(r'$HOME'),
    );
    expect(
      HerdrRequests.workspaceCreate(
        cwd: "/home/dev/src/upgrade with 'quote'",
        label: 'upgrade',
      ).params,
      containsPair('cwd', "/home/dev/src/upgrade with 'quote'"),
    );
  });

  test('the prompt is the title, a blank line, then one link per line', () {
    final prompt = sendPrompt(
      title: 'read the gate log',
      links: const ['https://a.example', 'https://b.example'],
    );
    expect(prompt, 'read the gate log\n\nhttps://a.example\nhttps://b.example');
    // No trailing newline to be read as an empty last link, and no framing.
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
      '/tmp/upgrade/a.png\n/tmp/upgrade/b.png',
    );
  });

  test('a drop with an image and no link still opens with the blank line', () {
    expect(
      sendPrompt(
        title: 'what is wrong here',
        links: const [],
        images: [RemoteFile('a.png', Uint8List(0))],
      ),
      'what is wrong here\n\n/tmp/upgrade/a.png',
    );
  });

  test('a prepared prompt leads and the title follows it as the item', () {
    expect(
      sendPrompt(
        title: 'auth refresh',
        prompt: 'move the session refresh off the UI thread',
        links: const [],
      ),
      'move the session refresh off the UI thread\n\nITEM\nauth refresh',
    );
  });

  test('links and images follow the item, not the prompt', () {
    expect(
      sendPrompt(
        title: 'auth refresh',
        prompt: 'tests first',
        links: const ['https://a.example'],
        images: [RemoteFile('a.png', Uint8List(0))],
      ),
      'tests first\n\nITEM\nauth refresh\n\n'
      'https://a.example\n/tmp/upgrade/a.png',
    );
  });

  test('every line of a multi-line prompt and title goes out', () {
    expect(
      sendPrompt(
        title: 'auth refresh\nthe one on hosts',
        prompt: 'read lib/auth\nthen move the refresh',
        links: const [],
      ),
      'read lib/auth\nthen move the refresh\n\n'
      'ITEM\nauth refresh\nthe one on hosts',
    );
  });

  test('a name is the file s own and cannot climb out of the directory', () {
    expect(
      RemoteFile.fromPath('/data/app/attachments/019-a.png', Uint8List(0)).name,
      '019-a.png',
    );
    expect(
      RemoteFile.fromPath('../../etc/passwd', Uint8List(0)).remotePath,
      '/tmp/upgrade/passwd',
    );
    expect(
      RemoteFile.fromPath("a b';rm -rf .png", Uint8List(0)).name,
      'a_b__rm_-rf_.png',
    );
    expect(RemoteFile.fromPath('/x/.hidden', Uint8List(0)).name, 'file.hidden');
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

    test('reviewed message replaces composed text without duplicating URLs', () async {
      String? outgoing;
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
            onPane,
            required verifier,
          }) async {
            outgoing = prompt;
            return const SpawnRefused(SpawnRefusal.noSession);
          })(
            sendId: 'send-1',
            target: _target(),
            itemId: await onlyTaskId(),
            kind: const ClaudeKind(),
            title: 'Original title',
            prompt: 'Original prompt',
            links: const ['https://a.example'],
            message: 'Reviewed instructions\n\nhttps://a.example',
            imagePaths: const ['/data/photo.png'],
          );
      expect(state, isA<SendFailed>());
      expect(
        outgoing,
        'Reviewed instructions\n\nhttps://a.example\n\n/tmp/upgrade/photo.png',
      );
    });

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
              directory: '~/src/upgrade',
              label: 'upgrade',
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
            onPane,
            required verifier,
          }) async {
            calls.add(_Call(kind.name, directory, prompt));
            verifiers.add(verifier);
            return const SpawnSent('wQ:p7', 'main');
          })(
            sendId: 'send-1',
            target: _target(),
            kind: const ClaudeKind(),
            itemId: itemId,
            title: 'read the gate log',
            links: const ['https://a.example'],
          );

      expect(state, isA<SendSent>());
      expect((state as SendSent).paneId, 'wQ:p7');
      expect(calls.single.kind, 'claude');
      expect(calls.single.directory, '~/src/upgrade');
      expect(calls.single.prompt, 'read the gate log\n\nhttps://a.example');

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
      expect(rows.single.label, 'upgrade');
      expect(rows.single.agent, 'claude');
      expect(rows.single.paneId, 'wQ:p7');
      expect(rows.single.herdrSession, 'main');
      expect(rows.single.id, 'send-1');
      expect(rows.single.status, DispatchStatus.sent);
      expect(rows.single.text, 'read the gate log\n\nhttps://a.example');

      final entries = await activity.watchRecent().first;
      final sent = entries.firstWhere(
        (entry) => entry.action == ActivityAction.sent,
      );
      expect(sent.title, 'read the gate log');
      expect(sent.context, 'nyx / upgrade');
      expect(sent.detail, 'wQ:p7');
    });

    test('a send for no item goes out as typed and is recorded', () async {
      final prompts = <String>[];
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
            onPane,
            required verifier,
          }) async {
            prompts.add(prompt);
            return const SpawnSent('wQ:p8', 'main');
          })(
            sendId: 'send-8',
            target: _target(),
            kind: const ClaudeKind(),
            title: 'fix the gate',
            links: const [],
            message: 'fix the gate\nthen rerun it',
          );

      expect(state, isA<SendSent>());
      expect(prompts.single, 'fix the gate\nthen rerun it');
      final row = (await db.select(db.dispatches).get()).single;
      expect(
        (row.id, row.itemId, row.body, row.status, row.paneId),
        (
          'send-8',
          null,
          'fix the gate\nthen rerun it',
          DispatchStatus.sent,
          'wQ:p8',
        ),
      );
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
              onPane,
              required verifier,
            }) async {
              calls.add(_Call(kind.name, directory, prompt, images));
              return const SpawnSent('wQ:p7', 'main');
            },
            readImage: (path) async {
              read.add(path);
              return Uint8List.fromList([path.length]);
            },
          )(
            sendId: 'send-1',
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
      expect(
        calls.single.prompt,
        'what is wrong here\n\nhttps://a.example\n'
        '/tmp/upgrade/first.png\n/tmp/upgrade/second.jpg',
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
              onPane,
              required verifier,
            }) async {
              dialled = true;
              return const SpawnSent('wQ:p7', 'main');
            },
            readImage: (path) async => throw const FileSystemException('gone'),
          )(
            sendId: 'send-1',
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
      final kept = (await db.select(db.dispatches).get()).single;
      expect(
        (kept.status, kept.failure),
        (DispatchStatus.failed, 'image unreadable'),
      );
    });

    test('a refused send is kept as failed and the item lists none', () async {
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
                onPane,
                required verifier,
              }) async => SpawnRefused(refusal),
            )(
              sendId: 'send-1',
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
      final kept = (await db.select(db.dispatches).get()).single;
      expect(kept.status, DispatchStatus.failed);
      expect(kept.failure, spawnRefusalReason(SpawnRefusal.values.last));
    });

    test(
      'a connection that never opened keeps the words the panel uses',
      () async {
        final itemId = await onlyTaskId();
        // The sender answers with a state rather than rethrowing, so each failure is read off
        // the state's line.
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
                  onPane,
                  required verifier,
                }) async => throw failure,
              )(
                sendId: 'send-1',
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
      },
    );

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
            onPane,
            required verifier,
          }) async {
            dialled = true;
            return const SpawnSent('wQ:p7', 'main');
          })(
            sendId: 'send-1',
            target: _target(),
            kind: const ClaudeKind(),
            itemId: itemId,
            title: 'read the gate log',
            links: const [],
          );
      expect(dialled, isFalse);
      expect((state as SendFailed).reason, 'key rejected');
    });

    test(
      'the record opens as sending and takes the pane once it exists',
      () async {
        final itemId = await onlyTaskId();
        DispatchStatus? during;
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
          onPane,
          required verifier,
        }) async {
          during = (await db.select(db.dispatches).get()).single.status;
          onPane?.call((session: 'work', pane: 'wQ:p9'));
          return const SpawnSent('wQ:p9', 'main');
        })(
          sendId: 'send-1',
          target: _target(),
          kind: const ClaudeKind(),
          itemId: itemId,
          title: 'read the gate log',
          links: const [],
          model: 'opus',
        );
        expect(during, DispatchStatus.sending);
        final row = (await db.select(db.dispatches).get()).single;
        expect(
          (row.status, row.herdrSession, row.paneId, row.model),
          (DispatchStatus.sent, 'work', 'wQ:p9', 'opus'),
        );
      },
    );
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

    Future<void> addPath({String label = 'upgrade', String? projectId}) => db
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
              required verifier,
            }) async => const ['~/src/upgrade'],
            fetchModels: ({
              required address,
              required port,
              required user,
              required privateKey,
              required kind,
              required verifier,
            }) async => const ['opus', 'sonnet'],
            keys: Ed25519Keys(privateKeys),
          ),
        ),
      ],
      child: MaterialApp(
        theme: testTheme,
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
      ).create(name: 'upgrade');
      final id = await TaskRepository(
        db,
        activity,
      ).create(title: 'ship the picker', projectId: project);
      await addPath();

      await tester.pumpWidget(app(id));
      await _drain(tester);

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
      ).create(name: 'upgrade');
      final id = await TaskRepository(
        db,
        activity,
      ).create(title: 'ship the picker', projectId: project);
      await addPath(projectId: project);

      await tester.pumpWidget(app(id));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(find.text('SEND TO'), findsNothing);
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.text('MODEL'), findsOneWidget);
      expect(find.byKey(const ValueKey('send-message')), findsOneWidget);

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
      ).create(name: 'upgrade');
      final id = await TaskRepository(
        db,
        activity,
      ).create(title: 'ship the picker', projectId: project);
      await addPath(label: 'gate');
      await addPath(label: 'upgrade', projectId: project);
      await addPath(label: 'monolith', projectId: project);

      await tester.pumpWidget(app(id));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(find.text('SEND TO'), findsOneWidget);
      expect(find.text('LINKED'), findsNWidgets(2));
      final loose = tester.getTopLeft(find.text('NYX / GATE')).dy;
      expect(tester.getTopLeft(find.text('NYX / UPGRADE')).dy, lessThan(loose));
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
                onPane,
                required verifier,
              }) async {
                seen = prompt;
                seenKind = kind.name;
                seenModel = model;
                return const SpawnSent('wQ:p7', 'main');
              },
        ),
      );
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);
      expect(find.text('SEND TO'), findsOneWidget);
      expect(find.text('NYX / UPGRADE'), findsOneWidget);

      await tester.tap(find.text('NYX / UPGRADE'));
      await _drain(tester);
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.text('MODEL'), findsOneWidget);
      await tester.tap(find.text('SONNET'));
      await _drain(tester);

      final message = find.byKey(const ValueKey('send-message'));
      expect(
        tester.widget<UpgradeField>(message).controller.text,
        'read the gate log\n\nhttps://a.example',
      );
      await tester.enterText(
        message,
        'Review the revised log\n\nhttps://a.example',
      );
      await tester.binding.handlePopRoute();
      await _drain(tester);
      expect(find.text('SEND TO'), findsOneWidget);
      await tester.tap(find.text('NYX / UPGRADE'));
      await _drain(tester);
      expect(
        tester.widget<UpgradeField>(message).controller.text,
        'Review the revised log\n\nhttps://a.example',
      );
      await tester.tap(find.text('SONNET'));
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(seenKind, 'claude');
      expect(seenModel, 'sonnet');
      expect(seen, 'Review the revised log\n\nhttps://a.example');
      expect(find.text('[ SENDING ]'), findsNothing);
      expect(find.byType(SentTag), findsOneWidget);
      expect(
        find.textContaining('NYX / UPGRADE · CLAUDE sonnet · wQ:p7 · '),
        findsOneWidget,
      );

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
                onPane,
                required verifier,
              }) async {
                attempts++;
                return attempts == 1
                    ? const SpawnRefused(SpawnRefusal.noDirectory)
                    : const SpawnSent('wQ:p9', 'main');
              },
        ),
      );
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);
      await tester.tap(find.text('NYX / UPGRADE'));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(
        find.text('NYX / UPGRADE · CLAUDE · no such directory'),
        findsOneWidget,
      );
      expect(find.text('FAILED'), findsOneWidget);

      await tester.tap(find.text('RETRY'));
      await _drain(tester);
      expect(attempts, 2);
      expect(find.text('[ SENDING ]'), findsNothing);
      expect(find.byType(SentTag), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a send runs on after the sheet lets go of it', (tester) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');
      await addPath();
      final answer = Completer<SpawnResult>();

      await tester.pumpWidget(
        app(
          id,
          send: ({
            required address,
            required port,
            required user,
            required privateKey,
            required kind,
            required directory,
            required prompt,
            images = const <RemoteFile>[],
            model,
            onPane,
            required verifier,
          }) => answer.future,
        ),
      );
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);
      await tester.tap(find.text('NYX / UPGRADE'));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(find.text('[ SENDING ]'), findsOneWidget);
      expect(find.text('NYX / UPGRADE · CLAUDE'), findsOneWidget);
      expect(find.byType(SendingTag), findsOneWidget);
      expect(find.text('RETRY'), findsNothing);

      answer.complete(const SpawnSent('wQ:p4', 'main'));
      await _drain(tester);
      expect(find.text('[ SENDING ]'), findsNothing);
      expect(find.byType(SentTag), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the sheet keeps what was sent, and the row is tagged', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');
      await addPath();
      final sends = DriftDispatchRepository(db, activity);
      await sends.start(
        id: 'send-1',
        itemId: id,
        pathId: 'path-upgrade',
        text: 'a drop',
        agent: 'claude',
      );
      await sends.pane('send-1', session: 'main', paneId: 'wQ:p7');
      await sends.sent('send-1', title: 'a drop');

      await tester.pumpWidget(app(id));
      await _drain(tester);

      expect(find.text('[ SENT ]'), findsOneWidget);
      expect(
        find.textContaining('NYX / UPGRADE · CLAUDE · wQ:p7 · '),
        findsOneWidget,
      );
      expect(find.byType(SentTag), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a prompt takes the strip and the dispatches stay listed', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final tasks = TaskRepository(db, activity);
      final id = await tasks.create(title: 'a drop');
      await tasks.setPrompt(id, 'read lib/auth first');
      await addPath();
      final sends = DriftDispatchRepository(db, activity);
      await sends.start(
        id: 'send-1',
        itemId: id,
        pathId: 'path-upgrade',
        text: 'a drop',
        agent: 'claude',
      );
      await sends.pane('send-1', session: 'main', paneId: 'wQ:p7');
      await sends.sent('send-1', title: 'a drop');

      await tester.pumpWidget(app(id));
      await _drain(tester);

      expect(find.byType(PromptTag), findsOneWidget);
      expect(find.byType(SentTag), findsNothing);
      expect(find.text('[ SENT ]'), findsOneWidget);
      expect(
        find.textContaining('NYX / UPGRADE · CLAUDE · wQ:p7 · '),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the tag is a word at the trailing edge', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(body: SentTag()),
        ),
      );
      expect(find.text('SENT'), findsOneWidget);
    });

    testWidgets('a prompt is written on its own panel and read back', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final id = await TaskRepository(db, activity).create(title: 'a drop');
      await addPath();

      await tester.pumpWidget(app(id));
      await _drain(tester);
      expect(find.text('PROMPT'), findsOneWidget);
      expect(find.text('[ PROMPT ]'), findsNothing);
      expect(find.byType(PromptTag), findsNothing);

      await tester.tap(find.text('PROMPT'));
      await _drain(tester);
      expect(find.text('SAVE'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _drain(tester);
      expect(find.text('SAVE'), findsOneWidget);
      expect(find.text('SEND'), findsNothing);

      await tester.enterText(find.byType(UpgradeField), 'read lib/auth first');
      await tester.tap(find.text('SAVE'));
      await _drain(tester);

      expect(find.text('[ PROMPT ]'), findsOneWidget);
      expect(find.text('read lib/auth first'), findsOneWidget);
      expect(find.text('EDIT PROMPT'), findsOneWidget);
      expect(find.byType(PromptTag), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('saving an empty field is how a prompt is deleted', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final tasks = TaskRepository(db, activity);
      final id = await tasks.create(title: 'a drop');
      await tasks.setPrompt(id, 'read lib/auth first');
      await addPath();

      await tester.pumpWidget(app(id));
      await _drain(tester);
      expect(find.text('[ PROMPT ]'), findsOneWidget);

      await tester.tap(find.text('EDIT PROMPT'));
      await _drain(tester);
      await tester.enterText(find.byType(UpgradeField), '   ');
      await tester.tap(find.text('SAVE'));
      await _drain(tester);

      expect(find.text('[ PROMPT ]'), findsNothing);
      expect(find.text('PROMPT'), findsOneWidget);
      expect(find.byType(PromptTag), findsNothing);
      expect((await db.select(db.tasks).get()).single.prompt, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the prepared prompt is what the agent is handed', (
      tester,
    ) async {
      final activity = ActivityRepository(db);
      final tasks = TaskRepository(db, activity);
      final id = await tasks.create(title: 'a drop');
      await tasks.setPrompt(id, 'move the refresh off the UI thread');
      await addPath();
      String? seen;

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
                onPane,
                required verifier,
              }) async {
                seen = prompt;
                return const SpawnSent('wQ:p7', 'main');
              },
        ),
      );
      await _drain(tester);

      await tester.tap(find.text('SEND'));
      await _drain(tester);
      await tester.tap(find.text('NYX / UPGRADE'));
      await _drain(tester);
      await tester.tap(find.text('SEND'));
      await _drain(tester);

      expect(seen, 'move the refresh off the UI thread\n\nITEM\na drop');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
