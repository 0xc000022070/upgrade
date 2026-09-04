import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repositories/activity_repository.dart';
import '../data/repositories/goal_repository.dart';
import '../data/repositories/host_repository.dart';
import '../data/repositories/key_repository.dart';
import '../data/repositories/attachment_repository.dart';
import '../data/repositories/dispatch_repository.dart';
import '../data/repositories/note_repository.dart';
import '../data/repositories/path_repository.dart';
import '../data/repositories/project_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/shell_tab_repository.dart';
import '../data/repositories/task_repository.dart';
import '../data/views.dart';
import '../platform/keys.dart';
import 'agents.dart';

/// Overridden in main() with the opened (and, in debug, seeded) database, so
/// no screen ever has to wait on an async database handle.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

/// Everything that has to be swapped to run the app against a
/// real database, in one list, because they are swapped together or not at all.
///
/// The key and host providers are declared in `agents.dart` over in-memory
/// implementations so the AGENTS and Settings screens can be built and tested
/// without a database. That default is the wrong one for the app, and nothing
/// about reading it says so — the app comes up looking like it works and forgets
/// every key on restart. Overriding here means the swap is a compile-time fact
/// of `main()` rather than a thing to remember.
///
/// [privateKeyStoreProvider] already defaults to the keystore-backed store, so
/// its override changes nothing today. It is listed anyway: the three belong to
/// one decision, and a future change to that default should not silently become
/// a change to what the app stores private keys in.
List<Override> databaseOverrides(AppDatabase db) => [
  databaseProvider.overrideWithValue(db),
  keyRepositoryProvider.overrideWith(
    (ref) => DriftKeyRepository(ref.watch(databaseProvider)),
  ),
  hostRepositoryProvider.overrideWith(
    (ref) => DriftHostRepository(ref.watch(databaseProvider)),
  ),
  privateKeyStoreProvider.overrideWith((ref) => const SecurePrivateKeyStore()),
];

final activityRepositoryProvider = Provider(
  (ref) => ActivityRepository(ref.watch(databaseProvider)),
);

final projectRepositoryProvider = Provider(
  (ref) => ProjectRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  ),
);

final goalRepositoryProvider = Provider(
  (ref) => GoalRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  ),
);

final attachmentRepositoryProvider = Provider(
  (ref) => AttachmentRepository(ref.watch(databaseProvider)),
);

final taskRepositoryProvider = Provider(
  (ref) => TaskRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  ),
);

final settingsRepositoryProvider = Provider(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final shellTabRepositoryProvider = Provider<ShellTabRepository>(
  (ref) => DriftShellTabRepository(ref.watch(databaseProvider)),
);

/// Concrete and not swappable the way the host and key repositories are: paths
/// only ever exist under a host that has been saved, so there is no screen that
/// can be built without a database to hold them.
final pathRepositoryProvider = Provider<PathRepository>(
  (ref) => DriftPathRepository(ref.watch(databaseProvider)),
);

/// Every send that happened. Split from [pathRepositoryProvider] because the
/// two are read from different places: the picker wants targets, the sheet and
/// the rows want history.
final dispatchRepositoryProvider = Provider<DispatchRepository>(
  (ref) => DriftDispatchRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  ),
);

final noteRepositoryProvider = Provider(
  (ref) => NoteRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  ),
);

/// Every screen reads a drift `watch` stream, so a write anywhere repaints the
/// views that depend on the touched tables without any manual invalidation.
final nextActionProvider = StreamProvider<NextAction?>(
  (ref) => ref.watch(taskRepositoryProvider).watchNextAction(),
);

final blockedTasksProvider = StreamProvider<List<BlockedTask>>(
  (ref) => ref.watch(taskRepositoryProvider).watchBlocked(),
);

final dropsProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchDrops(),
);

/// The send picker's rows. Empty is the answer that hides SEND altogether, so
/// this is watched by the quick view and not only by the picker.
final pathTargetsProvider = StreamProvider<List<PathTarget>>(
  (ref) => ref.watch(pathRepositoryProvider).watchTargets(),
);

/// One stream for every row that might carry the tag, rather than a query per
/// drop: Home draws the whole list at once.
final sentItemsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(dispatchRepositoryProvider).watchSentItems(),
);

final itemDispatchesProvider = StreamProvider.family<List<Dispatch>, String>(
  (ref, itemId) => ref.watch(dispatchRepositoryProvider).watchForItem(itemId),
);

final recentActivityProvider = StreamProvider<List<ActivityEntry>>(
  (ref) => ref.watch(activityRepositoryProvider).watchRecent(),
);

final projectsProvider = StreamProvider<List<Project>>(
  (ref) => ref.watch(projectRepositoryProvider).watchAll(),
);

final projectSummariesProvider = StreamProvider<List<ProjectSummary>>(
  (ref) => ref.watch(projectRepositoryProvider).watchSummaries(),
);

final archivedProjectSummariesProvider = StreamProvider<List<ProjectSummary>>(
  (ref) => ref.watch(projectRepositoryProvider).watchArchivedSummaries(),
);

final projectProvider = StreamProvider.family<Project?, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchById(id),
);

/// Three families, because a project detail asks three
/// hierarchy questions: what is under me, what is my number over the subtree,
/// and what is the path down to me.
final projectChildrenProvider =
    StreamProvider.family<List<ProjectSummary>, String>(
      (ref, id) => ref.watch(projectRepositoryProvider).watchChildren(id),
    );

final projectSummaryProvider = StreamProvider.family<ProjectSummary?, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchSummary(id),
);

final projectAncestorsProvider =
    StreamProvider.family<List<ProjectCrumb>, String>(
      (ref, id) => ref.watch(projectRepositoryProvider).watchAncestors(id),
    );

final projectTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchByProject(id),
);

final projectNotesProvider = StreamProvider.family<List<Note>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).watchForProject(id),
);

final projectDropsProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchProjectDrops(id),
);

final projectGoalsProvider = StreamProvider.family<List<GoalSummary>, String>(
  (ref, id) => ref.watch(goalRepositoryProvider).watchSummaries(id),
);

final goalTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchByGoal(id),
);

final taskProvider = StreamProvider.family<Task?, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchById(id),
);

final itemAttachmentsProvider = StreamProvider.family<List<Attachment>, String>(
  (ref, id) => ref.watch(attachmentRepositoryProvider).watchForItem(id),
);

final taskMatesProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchMates(id),
);

final pairCandidatesProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchPairCandidates(id),
);

final itemLocationProvider = StreamProvider.family<ItemLocation, String>(
  (ref, id) => ref.watch(databaseProvider).watchItemLocation(id),
);

/// The `[ STATIC ]` setting. A stream and not a one-shot read: the value
/// is changed on one screen and obeyed on every other, and the driver behind
/// the settings route has to stop the moment the row is written.
final staticEnabledProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.staticEnabled, orElse: true),
);
