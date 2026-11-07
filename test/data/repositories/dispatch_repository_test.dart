import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/activity_repository.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';

void main() {
  late AppDatabase db;
  late ActivityRepository activity;
  late DriftDispatchRepository sends;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    activity = ActivityRepository(db);
    sends = DriftDispatchRepository(db, activity);
    await db
        .into(db.hosts)
        .insert(
          HostsCompanion.insert(
            id: 'host-1',
            name: 'oak',
            address: '100.64.0.1',
            user: 'luis',
            keyId: 'key-1',
          ),
        );
    await db
        .into(db.paths)
        .insert(
          PathsCompanion.insert(
            id: 'path-1',
            hostId: 'host-1',
            directory: '~/src/upgrade',
            label: 'upgrade',
            createdAt: DateTime.utc(2026, 9, 3),
          ),
        );
  });
  tearDown(() => db.close());

  Future<void> start(String id, {String? itemId}) => sends.start(
    id: id,
    itemId: itemId,
    pathId: 'path-1',
    text: 'fix the gate\n\nthen run it',
    agent: 'codex',
    model: 'gpt-5',
  );

  test('a send runs sending, failed, and starts over on a retry', () async {
    await start('s1');
    var send = (await sends.watchAll().first).single;
    expect(
      (send.status, send.text, send.firstLine, send.hostName),
      (
        DispatchStatus.sending,
        'fix the gate\n\nthen run it',
        'fix the gate',
        'oak',
      ),
    );

    await sends.pane('s1', session: 'main', paneId: 'wQ:p1');
    await sends.failed('s1', 'spawn timed out');
    send = (await sends.watchOne('s1').first)!;
    expect(
      (send.status, send.failure, send.paneId),
      (DispatchStatus.failed, 'spawn timed out', 'wQ:p1'),
    );

    await start('s1');
    send = (await sends.watchOne('s1').first)!;
    expect(
      (send.status, send.failure, send.paneId),
      (DispatchStatus.sending, null, null),
    );
    await sends.sent('s1', title: 'fix the gate');
    expect((await sends.watchOne('s1').first)!.status, DispatchStatus.sent);
    expect(await activity.watchRecent().first, isEmpty);
  });

  test('an item counts only the sends that reached their pane', () async {
    await start('s1', itemId: 'item-1');
    await start('s2', itemId: 'item-1');
    await sends.failed('s1', 'key rejected');
    await sends.sent('s2', title: 'fix the gate');

    expect((await sends.watchForItem('item-1').first).map((send) => send.id), [
      's2',
    ]);
    expect(await sends.watchSentItems().first, {'item-1'});
    expect(
      (await activity.watchRecent().first).single.context,
      'oak / upgrade',
    );
  });

  test('past the cap the oldest unlisted go and item sends stay', () async {
    await start('item-send', itemId: 'item-1');
    for (var i = 0; i <= DriftDispatchRepository.kept; i++) {
      await start('s${i.toString().padLeft(4, '0')}');
    }
    final ids = {for (final send in await sends.watchAll().first) send.id};
    expect(ids, hasLength(DriftDispatchRepository.kept + 1));
    expect(ids, contains('item-send'));
    expect(ids, isNot(contains('s0000')));
    expect(ids, contains('s0001'));
  });

  test('a state is written once per change', () async {
    await start('s1');
    await sends.seen('s1', 'working');
    await sends.seen('s1', 'working');
    await sends.seen('s1', 'done');
    final send = (await sends.watchOne('s1').first)!;
    expect(send.states.map((seen) => seen.state), ['working', 'done']);
    expect(send.lastSeen, 'done');
  });

  test('a session key sticks to the record and a delete removes it', () async {
    await start('s1');
    await sends.linkSession('s1', 'claude:abc');
    expect((await sends.watchOne('s1').first)!.engineSession, 'claude:abc');
    await sends.delete('s1');
    expect(await sends.watchOne('s1').first, isNull);
  });

  test('a states column that is not a list reads as none', () {
    expect(DriftDispatchRepository.decodeStates('{"state":1}'), isEmpty);
    expect(DriftDispatchRepository.decodeStates('not json'), isEmpty);
    final at = DateTime.utc(2026, 10, 1, 12);
    expect(
      DriftDispatchRepository.decodeStates(
        DriftDispatchRepository.encodeStates([(state: 'blocked', at: at)]),
      ),
      [(state: 'blocked', at: at)],
    );
  });
}
