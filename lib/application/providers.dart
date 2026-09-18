import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

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
import '../platform/link_metadata.dart';
import 'agents.dart';
import 'link_preview.dart';
import 'pane_share.dart';
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

final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

/// Swapped together or not at all. Without them the app comes up looking like it works
/// and forgets every key on restart.
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

final pathRepositoryProvider = Provider<PathRepository>((ref) {
  final backend = DriftPathRepository(ref.watch(databaseProvider));
  final gate = ref.watch(pluginDataGateProvider);
  return gate == null ? backend : PluginWorkspaceApi(backend, gate);
}, dependencies: [pluginDataGateProvider]);

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

final pathTargetsProvider = StreamProvider<List<PathTarget>>(
  (ref) => ref.watch(pathRepositoryProvider).watchTargets(),
  dependencies: [pathRepositoryProvider],
);

final workspacesByHostProvider = StreamProvider<List<HostWorkspaces>>(
  (ref) => ref.watch(pathRepositoryProvider).watchByHost(),
  dependencies: [pathRepositoryProvider],
);

final projectWorkspacesProvider =
    StreamProvider.family<List<PathTarget>, String>(
      (ref, projectId) =>
          ref.watch(pathRepositoryProvider).watchForProject(projectId),
      dependencies: [pathRepositoryProvider],
    );

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

final linkPreviewsProvider = Provider<LinkPreviews>((ref) {
  ref.keepAlive();
  return LinkPreviews(
    fetcher: LinkMetadataFetcher(),
    cache: LinkPreviewCache.inDirectory(
      Directory(p.join(Directory.systemTemp.path, 'dazzle')),
    ),
  );
});

final linkPreviewProvider = FutureProvider.autoDispose
    .family<LinkPreview?, String>(
      (ref, url) => ref.watch(linkPreviewsProvider).of(url),
      dependencies: [linkPreviewsProvider],
    );

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

final staticEnabledProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.staticEnabled, orElse: true),
);

final shellFontSizeProvider = StreamProvider<double>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchNumber(
        SettingsRepository.shellFontSize,
        orElse: shellFontSizeDefault,
      ),
);

final paneShareProvider = StreamProvider.family<double, PaneSeam>(
  (ref, seam) => ref
      .watch(settingsRepositoryProvider)
      .watchNumber(seam.key, orElse: seam.fallback),
);

final themeSystemProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchFlag(SettingsRepository.themeSystem, orElse: false),
);
