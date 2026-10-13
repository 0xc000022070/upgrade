import 'package:drift/drift.dart' show Value;

import 'package:upgrade/platform/plugins/access.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/views.dart';
import 'package:upgrade/data/repositories/attachment_repository.dart';
import 'package:upgrade/data/repositories/goal_repository.dart';
import 'package:upgrade/data/repositories/note_repository.dart';
import 'package:upgrade/data/repositories/project_repository.dart';
import 'package:upgrade/data/repositories/task_repository.dart';

class PluginDataGate {
  PluginDataGate(this._db, this._authority, this.actor)
    : _activation = _authority.activation(actor);
  final AppDatabase _db;
  final PluginAuthority _authority;
  final String actor;
  final int _activation;
  final _leases = <String, PluginLease>{};

  PluginLease lease(String service) {
    if (_authority.activation(actor) != _activation) {
      throw const PluginException(
        'Data handle belongs to an earlier activation',
      );
    }
    return _leases.putIfAbsent(
      service,
      () => _authority.acquire(actor, service),
    );
  }

  Future<T> call<T>(
    String service,
    Future<T> Function() operation, {
    List<String> also = const [],
    List<String> requires = const [],
  }) {
    final primary = lease(service);
    final others = also.map(lease).toList();
    final providers = <String, int>{};
    for (final service in requires) {
      final provider = _authority.providerOf(service);
      if (provider == null) {
        throw PluginException('The $service provider is disabled');
      }
      providers[provider] = _authority.activation(provider);
    }
    void checkProviders() {
      for (final provider in providers.entries) {
        if (_authority.activation(provider.key) != provider.value) {
          throw const PluginException('Target provider activation changed');
        }
      }
    }

    return primary.call(
      () => _db.transaction(() async {
        primary.check();
        checkProviders();
        for (final other in others) {
          other.check();
          other.usage.calls++;
        }
        final result = await operation();
        primary.check();
        checkProviders();
        for (final other in others) {
          other.check();
        }
        return result;
      }),
    );
  }

  Stream<T> watch<T>(
    String service,
    Stream<T> Function() operation, {
    List<String> also = const [],
  }) {
    final primary = lease(service);
    final others = also.map(lease).toList();
    return primary.watch(() {
      for (final other in others) {
        other.check();
      }
      return operation().map((value) {
        for (final other in others) {
          other.check();
          other.usage.calls++;
        }
        return value;
      });
    });
  }
}

class PluginTaskApi implements TaskRepository {
  PluginTaskApi(this._base, this._gate);
  final TaskRepository _base;
  final PluginDataGate _gate;
  @override
  Stream<NextAction?> watchNextAction() =>
      _gate.watch('items', _base.watchNextAction);
  @override
  Stream<List<BlockedTask>> watchBlocked() =>
      _gate.watch('items', _base.watchBlocked);
  @override
  Stream<List<Task>> watchByProject(String projectId) =>
      _gate.watch('items', () => _base.watchByProject(projectId));
  @override
  Stream<List<Task>> watchProjectDrops(String projectId) =>
      _gate.watch('items', () => _base.watchProjectDrops(projectId));
  @override
  Stream<List<Task>> watchByGoal(String goalId) =>
      _gate.watch('items', () => _base.watchByGoal(goalId));
  @override
  Stream<List<Task>> watchDrops() => _gate.watch('items', _base.watchDrops);
  @override
  Stream<Task?> watchById(String id) =>
      _gate.watch('items', () => _base.watchById(id));
  @override
  Stream<List<SearchHit>> watchSearch({required bool filed}) => _gate.watch(
    'items',
    () => _base.watchSearch(filed: filed),
    also: ['attachments', 'host.capture_targets', 'host.dispatch'],
  );
  @override
  Stream<List<Task>> watchMates(String id) =>
      _gate.watch('items', () => _base.watchMates(id));
  @override
  Stream<List<Task>> watchPairCandidates(String id) =>
      _gate.watch('items', () => _base.watchPairCandidates(id));
  @override
  Future<String> create({
    required String title,
    String? projectId,
    String? goalId,
    bool isNext = false,
    int? effort,
    List<NewAttachment> attachments = const [],
    ActivityAction action = ActivityAction.created,
    DateTime? at,
  }) => _gate.call(
    'items',
    () => _base.create(
      title: title,
      projectId: projectId,
      goalId: goalId,
      isNext: isNext,
      effort: effort,
      attachments: attachments,
      action: action,
      at: at,
    ),
    also: [
      if (attachments.isNotEmpty) 'attachments',
      if (projectId != null) 'host.capture_targets',
    ],
    requires: [if (projectId != null) 'projects'],
  );
  @override
  Future<String> capture(
    String title, {
    ItemTarget target = const ItemTarget.drops(),
    List<NewAttachment> attachments = const [],
    DateTime? at,
  }) => create(
    title: title,
    projectId: target.projectId,
    goalId: target.goalId,
    attachments: attachments,
    action: ActivityAction.captured,
    at: at,
  );
  @override
  Future<void> setDone(String id, bool done, {DateTime? at}) =>
      _gate.call('items', () => _base.setDone(id, done, at: at));
  @override
  Future<void> block(String id, String reason, {DateTime? at}) =>
      _gate.call('items', () => _base.block(id, reason, at: at));
  @override
  Future<void> unblock(String id, {DateTime? at}) =>
      _gate.call('items', () => _base.unblock(id, at: at));
  @override
  Future<void> setNext(String id, {DateTime? at}) =>
      _gate.call('items', () => _base.setNext(id, at: at));
  @override
  Future<void> unsetNext(String id, {DateTime? at}) =>
      _gate.call('items', () => _base.unsetNext(id, at: at));
  @override
  Future<void> setPriority(String id, Priority priority, {DateTime? at}) =>
      _gate.call('items', () => _base.setPriority(id, priority, at: at));
  @override
  Future<void> moveToTarget(String id, ItemTarget target, {DateTime? at}) =>
      _gate.call(
        'items',
        () => _base.moveToTarget(id, target, at: at),
        also: [if (target.projectId != null) 'host.capture_targets'],
        requires: [if (target.projectId != null) 'projects'],
      );
  @override
  Future<void> pair(String id, String otherId, {DateTime? at}) =>
      _gate.call('items', () => _base.pair(id, otherId, at: at));
  @override
  Future<void> unpair(String id, {DateTime? at}) =>
      _gate.call('items', () => _base.unpair(id, at: at));
  @override
  Future<void> edit(String id, {String? title, int? effort, DateTime? at}) =>
      _gate.call(
        'items',
        () => _base.edit(id, title: title, effort: effort, at: at),
      );
  @override
  Future<void> setPrompt(String id, String? prompt, {DateTime? at}) =>
      _gate.call('items', () => _base.setPrompt(id, prompt, at: at));
  @override
  Future<bool> applyDropTitle(Task expected, String title) =>
      _gate.call('items', () => _base.applyDropTitle(expected, title));
  @override
  Future<void> delete(String id, {DateTime? at}) => _gate.call(
    'items',
    () => _base.delete(id, at: at),
    also: ['attachments', 'item_notes'],
  );
}

class PluginProjectApi implements ProjectRepository {
  PluginProjectApi(this._base, this._gate);
  final ProjectRepository _base;
  final PluginDataGate _gate;
  static const _keepParent = Object();
  @override
  Stream<List<Project>> watchAll() => _gate.watch('projects', _base.watchAll);
  @override
  Stream<List<ProjectSummary>> watchSummaries() =>
      _gate.watch('projects', _base.watchSummaries, also: ['items']);
  @override
  Stream<List<ProjectSummary>> watchArchivedSummaries() =>
      _gate.watch('projects', _base.watchArchivedSummaries, also: ['items']);
  @override
  Stream<List<ProjectSummary>> watchChildren(String parentId) => _gate.watch(
    'projects',
    () => _base.watchChildren(parentId),
    also: ['items'],
  );
  @override
  Stream<ProjectSummary?> watchSummary(String id) =>
      _gate.watch('projects', () => _base.watchSummary(id), also: ['items']);
  @override
  Stream<List<ProjectCrumb>> watchAncestors(String id) =>
      _gate.watch('projects', () => _base.watchAncestors(id));
  @override
  Stream<Project?> watchById(String id) =>
      _gate.watch('projects', () => _base.watchById(id));
  @override
  Future<int> descendantCount(String id) =>
      _gate.call('projects', () => _base.descendantCount(id));
  @override
  Future<String> create({
    required String name,
    String? iconId,
    String description = '',
    String objective = '',
    ProjectStatus status = ProjectStatus.active,
    Priority priority = Priority.normal,
    String? parentId,
    DateTime? at,
  }) => _gate.call(
    'projects',
    () => _base.create(
      name: name,
      iconId: iconId,
      description: description,
      objective: objective,
      status: status,
      priority: priority,
      parentId: parentId,
      at: at,
    ),
  );
  @override
  Future<void> edit(
    String id, {
    String? name,
    Value<String?> iconId = const Value.absent(),
    String? description,
    String? objective,
    ProjectStatus? status,
    Priority? priority,
    Object? parentId = _keepParent,
  }) => _gate.call(
    'projects',
    () => identical(parentId, _keepParent)
        ? _base.edit(
            id,
            name: name,
            iconId: iconId,
            description: description,
            objective: objective,
            status: status,
            priority: priority,
          )
        : _base.edit(
            id,
            name: name,
            iconId: iconId,
            description: description,
            objective: objective,
            status: status,
            priority: priority,
            parentId: parentId,
          ),
  );
  @override
  Future<void> setStatus(String id, ProjectStatus status) =>
      _gate.call('projects', () => _base.setStatus(id, status));
  @override
  Future<void> setPriority(String id, Priority priority) =>
      _gate.call('projects', () => _base.setPriority(id, priority));
  @override
  Future<void> archive(String id) => setStatus(id, ProjectStatus.archived);
  @override
  Future<void> unarchive(String id) => setStatus(id, ProjectStatus.active);
  @override
  Future<void> delete(String id, {DateTime? at}) => _gate.call(
    'projects',
    () => _base.delete(id, at: at),
    also: ['items', 'goals', 'project_notes', 'item_notes', 'host.workspaces'],
  );
}

class PluginGoalApi implements GoalRepository {
  PluginGoalApi(this._base, this._gate);
  final GoalRepository _base;
  final PluginDataGate _gate;
  @override
  Stream<List<Goal>> watchByProject(String projectId) =>
      _gate.watch('goals', () => _base.watchByProject(projectId));
  @override
  Stream<List<GoalSummary>> watchSummaries(String projectId) => _gate.watch(
    'goals',
    () => _base.watchSummaries(projectId),
    also: ['items'],
  );
  @override
  Future<String> create({
    required String projectId,
    required String title,
    DateTime? at,
  }) => _gate.call(
    'goals',
    () => _base.create(projectId: projectId, title: title, at: at),
  );
  @override
  Future<void> rename(String id, String title, {DateTime? at}) =>
      _gate.call('goals', () => _base.rename(id, title, at: at));
  @override
  Future<void> delete(String id, {DateTime? at}) =>
      _gate.call('goals', () => _base.delete(id, at: at), also: ['items']);
}

class PluginAttachmentApi implements AttachmentRepository {
  PluginAttachmentApi(this._base, this._gate);
  final AttachmentRepository _base;
  final PluginDataGate _gate;
  @override
  Stream<List<Attachment>> watchForItem(String itemId) =>
      _gate.watch('attachments', () => _base.watchForItem(itemId));
  @override
  Future<List<Attachment>> forItem(String itemId) =>
      _gate.call('attachments', () => _base.forItem(itemId));
  @override
  Future<Map<String, List<Attachment>>> forItems(Iterable<String> itemIds) =>
      _gate.call('attachments', () => _base.forItems(itemIds));
  @override
  Future<String> create({
    required String itemId,
    required AttachmentKind kind,
    required String value,
    DateTime? at,
  }) => _gate.call(
    'attachments',
    () => _base.create(itemId: itemId, kind: kind, value: value, at: at),
  );
  @override
  Stream<Map<String, int>> watchLinkCounts() =>
      _gate.watch('attachments', _base.watchLinkCounts);
  @override
  Future<void> delete(String id) =>
      _gate.call('attachments', () => _base.delete(id));
}

class PluginNoteApi implements NoteRepository {
  PluginNoteApi(this._base, this._gate, this._db);
  final NoteRepository _base;
  final PluginDataGate _gate;
  final AppDatabase _db;
  @override
  Stream<List<Note>> watchForTask(String taskId) =>
      _gate.watch('item_notes', () => _base.watchForTask(taskId));
  @override
  Stream<List<Note>> watchForProject(String projectId) => _gate.watch(
    'project_notes',
    () => _base.watchForProject(projectId),
    also: ['item_notes'],
  );
  @override
  Future<String> create({
    required String content,
    String? projectId,
    String? taskId,
    DateTime? at,
  }) => _gate.call(
    taskId == null && projectId != null ? 'project_notes' : 'item_notes',
    () => _base.create(
      content: content,
      projectId: projectId,
      taskId: taskId,
      at: at,
    ),
  );
  @override
  Future<void> edit(String id, String content) async {
    _gate.lease('item_notes').check();
    final note = await (_db.select(
      _db.notes,
    )..where((n) => n.id.equals(id))).getSingle();
    await _gate.call(
      note.taskId == null && note.projectId != null
          ? 'project_notes'
          : 'item_notes',
      () => _base.edit(id, content),
    );
  }
}
