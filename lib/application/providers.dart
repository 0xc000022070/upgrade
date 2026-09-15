import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/plugin_api.dart';
import '../data/plugin_host_api.dart';
import '../platform/plugins/manifest.dart';
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
import 'shell_font.dart';
import 'native_plugins.dart';

final pluginDataGateProvider = Provider<PluginDataGate?>((ref) {
  final actor = ref.watch(currentPluginProvider);
  return actor == null
      ? null
      : PluginDataGate(
          ref.watch(databaseProvider),
          ref.watch(pluginAuthorityProvider),
          actor,
        );
}, dependencies: [currentPluginProvider]);

PluginDataGate _gateFor(Ref ref, String service) {
  final scoped = ref.watch(pluginDataGateProvider);
  if (scoped != null) return scoped;
  ref.watch(effectivePluginsProvider);
  final authority = ref.watch(pluginAuthorityProvider);
  final owner = authority.providerOf(service);
  if (owner == null) throw PluginException('The $service plugin is disabled');
  return PluginDataGate(ref.watch(databaseProvider), authority, owner);
}

final attachmentDataGateProvider = Provider<PluginDataGate>(
  (ref) => _gateFor(ref, 'attachments'),
  dependencies: [pluginDataGateProvider],
);

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

final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  final backend = ProjectRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  );
  return PluginProjectApi(backend, _gateFor(ref, 'projects'));
}, dependencies: [pluginDataGateProvider]);

final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  final backend = GoalRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  );
  return PluginGoalApi(backend, _gateFor(ref, 'goals'));
}, dependencies: [pluginDataGateProvider]);

final attachmentRepositoryProvider = Provider<AttachmentRepository>((ref) {
  final backend = AttachmentRepository(ref.watch(databaseProvider));
  return PluginAttachmentApi(backend, _gateFor(ref, 'attachments'));
}, dependencies: [pluginDataGateProvider]);

final taskRepositoryProvider = Provider<TaskRepository>((ref) {
  final backend = TaskRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  );
  return PluginTaskApi(backend, _gateFor(ref, 'items'));
}, dependencies: [pluginDataGateProvider]);

final settingsRepositoryProvider = Provider(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final shellTabRepositoryProvider = Provider<ShellTabRepository>(
  (ref) => DriftShellTabRepository(ref.watch(databaseProvider)),
);

/// Concrete and not swappable the way the host and key repositories are: paths
/// only ever exist under a host that has been saved, so there is no screen that
/// can be built without a database to hold them.
final pathRepositoryProvider = Provider<PathRepository>((ref) {
  final backend = DriftPathRepository(ref.watch(databaseProvider));
  final gate = ref.watch(pluginDataGateProvider);
  return gate == null ? backend : PluginWorkspaceApi(backend, gate);
}, dependencies: [pluginDataGateProvider]);

/// Every send that happened. Split from [pathRepositoryProvider] because the
/// two are read from different places: the picker wants targets, the sheet and
/// the rows want history.
final dispatchRepositoryProvider = Provider<DispatchRepository>((ref) {
  final backend = DriftDispatchRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  );
  final gate = ref.watch(pluginDataGateProvider);
  return gate == null ? backend : PluginDispatchApi(backend, gate);
}, dependencies: [pluginDataGateProvider]);

final noteRepositoryProvider = Provider<NoteRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final backend = NoteRepository(db, ref.watch(activityRepositoryProvider));
  return PluginNoteApi(backend, _gateFor(ref, 'item_notes'), db);
}, dependencies: [pluginDataGateProvider]);

/// Every screen reads a drift `watch` stream, so a write anywhere repaints the
/// views that depend on the touched tables without any manual invalidation.
final nextActionProvider = StreamProvider<NextAction?>(
  (ref) => ref.watch(taskRepositoryProvider).watchNextAction(),
  dependencies: [taskRepositoryProvider],
);

final blockedTasksProvider = StreamProvider<List<BlockedTask>>(
  (ref) => ref.watch(taskRepositoryProvider).watchBlocked(),
  dependencies: [taskRepositoryProvider],
);

final dropsProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchDrops(),
  dependencies: [taskRepositoryProvider],
);

/// The registered destinations offered by the send picker.
final pathTargetsProvider = StreamProvider<List<PathTarget>>(
  (ref) => ref.watch(pathRepositoryProvider).watchTargets(),
  dependencies: [pathRepositoryProvider],
);

/// The CODE list: every registered directory, host by host. Separate from
/// [pathTargetsProvider] because the two want different shapes of the same
/// table — the picker wants a flat list of targets, this wants panels.
final workspacesByHostProvider = StreamProvider<List<HostWorkspaces>>(
  (ref) => ref.watch(pathRepositoryProvider).watchByHost(),
  dependencies: [pathRepositoryProvider],
);

/// The directories filed under one project, for its CODE section.
final projectWorkspacesProvider =
    StreamProvider.family<List<PathTarget>, String>(
      (ref, projectId) =>
          ref.watch(pathRepositoryProvider).watchForProject(projectId),
      dependencies: [pathRepositoryProvider],
    );

/// One stream for every row that might carry the tag, rather than a query per
/// drop: Home draws the whole list at once.
final sentItemsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(dispatchRepositoryProvider).watchSentItems(),
  dependencies: [dispatchRepositoryProvider],
);

final itemDispatchesProvider = StreamProvider.family<List<Dispatch>, String>(
  (ref, itemId) => ref.watch(dispatchRepositoryProvider).watchForItem(itemId),
  dependencies: [dispatchRepositoryProvider],
);

final recentActivityProvider = StreamProvider<List<ActivityEntry>>(
  (ref) => ref.watch(activityRepositoryProvider).watchRecent(),
);

final projectsProvider = StreamProvider<List<Project>>(
  (ref) => ref.watch(projectRepositoryProvider).watchAll(),
  dependencies: [projectRepositoryProvider],
);

final captureProjectsProvider = StreamProvider<List<Project>>((ref) {
  if (ref.watch(nativeSurfaceOwnerProvider('capture.targets')) == null) {
    return Stream.value([]);
  }
  final db = ref.watch(databaseProvider);
  final backend = ProjectRepository(db, ref.watch(activityRepositoryProvider));
  return _gateFor(ref, 'items').watch(
    'host.capture_targets',
    () => backend.watchAll().map(
      (rows) => [
        for (final row in rows) row.copyWith(description: '', objective: ''),
      ],
    ),
  );
}, dependencies: [pluginDataGateProvider]);

final captureGoalsProvider = StreamProvider.family<List<GoalSummary>, String>((
  ref,
  projectId,
) {
  if (ref.watch(nativeSurfaceOwnerProvider('capture.targets')) == null) {
    return Stream.value([]);
  }
  final db = ref.watch(databaseProvider);
  final backend = GoalRepository(db, ref.watch(activityRepositoryProvider));
  return _gateFor(ref, 'items').watch(
    'host.capture_targets',
    () => backend.watchSummaries(projectId),
    also: ['items'],
  );
}, dependencies: [pluginDataGateProvider]);

final projectSummariesProvider = StreamProvider<List<ProjectSummary>>(
  (ref) => ref.watch(projectRepositoryProvider).watchSummaries(),
  dependencies: [projectRepositoryProvider],
);

final archivedProjectSummariesProvider = StreamProvider<List<ProjectSummary>>(
  (ref) => ref.watch(projectRepositoryProvider).watchArchivedSummaries(),
  dependencies: [projectRepositoryProvider],
);

final projectProvider = StreamProvider.family<Project?, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchById(id),
  dependencies: [projectRepositoryProvider],
);

/// Three families, because a project detail asks three
/// hierarchy questions: what is under me, what is my number over the subtree,
/// and what is the path down to me.
final projectChildrenProvider =
    StreamProvider.family<List<ProjectSummary>, String>(
      (ref, id) => ref.watch(projectRepositoryProvider).watchChildren(id),
      dependencies: [projectRepositoryProvider],
    );

final projectSummaryProvider = StreamProvider.family<ProjectSummary?, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchSummary(id),
  dependencies: [projectRepositoryProvider],
);

final projectAncestorsProvider =
    StreamProvider.family<List<ProjectCrumb>, String>(
      (ref, id) => ref.watch(projectRepositoryProvider).watchAncestors(id),
      dependencies: [projectRepositoryProvider],
    );

final projectTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchByProject(id),
  dependencies: [taskRepositoryProvider],
);

final projectNotesProvider = StreamProvider.family<List<Note>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).watchForProject(id),
  dependencies: [noteRepositoryProvider],
);

final projectDropsProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchProjectDrops(id),
  dependencies: [taskRepositoryProvider],
);

final projectGoalsProvider = StreamProvider.family<List<GoalSummary>, String>(
  (ref, id) => ref.watch(goalRepositoryProvider).watchSummaries(id),
  dependencies: [goalRepositoryProvider],
);

final goalTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchByGoal(id),
  dependencies: [taskRepositoryProvider],
);

final taskProvider = StreamProvider.family<Task?, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchById(id),
  dependencies: [taskRepositoryProvider],
);

final itemAttachmentsProvider = StreamProvider.family<List<Attachment>, String>(
  (ref, id) => ref.watch(attachmentRepositoryProvider).watchForItem(id),
  dependencies: [attachmentRepositoryProvider],
);

/// One subscription for every row on screen: the mark a row draws for its
/// links reads this map rather than opening a stream of its own.
final linkCountsProvider = StreamProvider<Map<String, int>>(
  (ref) => ref.watch(attachmentRepositoryProvider).watchLinkCounts(),
  dependencies: [attachmentRepositoryProvider],
);

final taskMatesProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchMates(id),
  dependencies: [taskRepositoryProvider],
);

final pairCandidatesProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchPairCandidates(id),
  dependencies: [taskRepositoryProvider],
);

final itemLocationProvider = StreamProvider.family<ItemLocation, String>((
  ref,
  id,
) {
  final available =
      ref.watch(nativeSurfaceOwnerProvider('capture.targets')) != null;
  return _gateFor(ref, 'items').watch(
    'host.capture_targets',
    () => ref
        .watch(databaseProvider)
        .watchItemLocation(id)
        .map(
          (location) => available ? location : const ItemLocation(null, null),
        ),
    also: ['items'],
  );
}, dependencies: [pluginDataGateProvider]);

/// The `[ STATIC ]` setting. A stream and not a one-shot read: the value
/// is changed on one screen and obeyed on every other, and the driver behind
/// the settings route has to stop the moment the row is written.
final staticEnabledProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.staticEnabled, orElse: true),
);

/// The terminal's type size. A stream for the same reason: it is pinched on
/// one shell tab and drawn on every other, and on the next open of the route.
final shellFontSizeProvider = StreamProvider<double>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchNumber(
        SettingsRepository.shellFontSize,
        orElse: shellFontSizeDefault,
      ),
);

/// The `[ THEME ]` setting: whether the app tracks the phone's own theme
/// (Material You where the platform offers it, light/dark otherwise) instead
/// of the fixed house palette. A stream for the same reason as
/// [staticEnabledProvider]: the row is written on SETTINGS and obeyed by the
/// running [MaterialApp] on every other screen.
final themeSystemProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.themeSystem, orElse: false),
);
