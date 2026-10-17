import 'package:striked/application/drops/item_search.dart';
import 'package:striked/data/database.dart';
import 'package:striked/data/repositories/activity_repository.dart';
import 'package:striked/data/repositories/attachment_repository.dart';
import 'package:striked/data/repositories/project_repository.dart';
import 'package:striked/data/repositories/task_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  late TaskRepository tasks;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final activity = ActivityRepository(db);
    projects = ProjectRepository(db, activity);
    tasks = TaskRepository(db, activity);
  });

  tearDown(() => db.close());

  Future<List<String>> search(
    String query,
    Set<SearchMark> marks, {
    bool filed = true,
  }) async => searchItems(
    await tasks.watchSearch(filed: filed).first,
    query,
    marks,
  ).map((hit) => hit.task.title).toList();

  test('leaves out items under a hidden project, and every filed one without Projects', () async {
    final parent = await projects.create(name: 'Parent');
    final child = await projects.create(name: 'Child', parentId: parent);
    final live = await projects.create(name: 'Live');
    await tasks.create(title: 'under child', projectId: child);
    await tasks.create(title: 'live', projectId: live);
    await tasks.create(title: 'unfiled');
    await projects.archive(parent);

    expect(await search('', {}), unorderedEquals(['live', 'unfiled']));
    expect(await search('', {}, filed: false), ['unfiled']);
  });

  test(
    'words come from text, prompt or link; marks read attachments and sends',
    () async {
      final at = DateTime.utc(2026, 9, 29);
      await tasks.create(
        title: 'router for the vpn',
        attachments: const [NewAttachment.url('https://tailscale.com/kb')],
        at: at,
      );
      final shot = await tasks.create(
        title: 'screenshot bug',
        attachments: const [NewAttachment.image('attachments/b.png')],
        at: at.add(const Duration(minutes: 1)),
      );
      await db
          .into(db.dispatches)
          .insert(
            DispatchesCompanion.insert(
              id: 'd1',
              itemId: shot,
              pathId: 'p1',
              paneId: 'pane',
              sentAt: at,
            ),
          );
      final prompted = await tasks.create(
        title: 'plain',
        at: at.add(const Duration(minutes: 2)),
      );
      await tasks.setPrompt(prompted, 'Refactor the VPN config');

      expect(await search('VPN router', {}), ['router for the vpn']);
      expect(await search('vpn', {}), ['plain', 'router for the vpn']);
      expect(await search('tailscale', {}), ['router for the vpn']);
      expect(await search('', {SearchMark.attachment}), [
        'screenshot bug',
        'router for the vpn',
      ]);
      expect(await search('', {SearchMark.image, SearchMark.sent}), [
        'screenshot bug',
      ]);
      expect(await search('', {SearchMark.link}), ['router for the vpn']);
      expect(await search('', {SearchMark.prompt}), ['plain']);
    },
  );

  test('open and done put each other out', () {
    final lit = toggleMark({
      SearchMark.open,
      SearchMark.image,
    }, SearchMark.done);
    expect(lit, {SearchMark.image, SearchMark.done});
  });
}
