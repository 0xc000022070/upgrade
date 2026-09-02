import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repositories/activity_repository.dart';
import '../data/repositories/note_repository.dart';
import '../data/repositories/project_repository.dart';
import '../data/repositories/task_repository.dart';
import '../data/views.dart';

/// Overridden in main() with the opened (and, in debug, seeded) database, so
/// no screen ever has to wait on an async database handle.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final activityRepositoryProvider = Provider(
  (ref) => ActivityRepository(ref.watch(databaseProvider)),
);

final projectRepositoryProvider = Provider(
  (ref) => ProjectRepository(
    ref.watch(databaseProvider),
    ref.watch(activityRepositoryProvider),
  ),
);

final taskRepositoryProvider = Provider(
  (ref) => TaskRepository(
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

final looseTasksProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchLoose(),
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

final projectProvider = StreamProvider.family<Project?, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchById(id),
);

final projectTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchByProject(id),
);

final projectNotesProvider = StreamProvider.family<List<Note>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).watchForProject(id),
);
