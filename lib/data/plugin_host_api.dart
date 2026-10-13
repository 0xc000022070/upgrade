import 'package:upgrade/data/plugin_api.dart';
import 'package:upgrade/data/repositories/dispatch_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';

class PluginWorkspaceApi implements PathRepository {
  PluginWorkspaceApi(this._base, this._gate);
  final PathRepository _base;
  final PluginDataGate _gate;
  @override
  Stream<List<AgentPath>> watchForHost(String hostId) =>
      _gate.watch('host.workspaces', () => _base.watchForHost(hostId));
  @override
  Future<List<AgentPath>> listForHost(String hostId) =>
      _gate.call('host.workspaces', () => _base.listForHost(hostId));
  @override
  Stream<List<HostWorkspaces>> watchByHost() =>
      _gate.watch('host.workspaces', _base.watchByHost);
  @override
  Stream<List<PathTarget>> watchForProject(String projectId) =>
      _gate.watch('host.workspaces', () => _base.watchForProject(projectId));
  @override
  Stream<List<PathTarget>> watchUnlinked() =>
      _gate.watch('host.workspaces', _base.watchUnlinked);
  @override
  Stream<List<PathTarget>> watchTargets() =>
      _gate.watch('host.workspaces', _base.watchTargets);
  @override
  Future<void> setProject(String pathId, String? projectId) => _gate.call(
    'host.workspaces',
    () => _base.setProject(pathId, projectId),
    also: ['host.capture_targets'],
    requires: [if (projectId != null) 'projects'],
  );
  @override
  Future<void> repoint(String pathId, String directory) =>
      _gate.call('host.workspaces', () => _base.repoint(pathId, directory));
  @override
  Future<void> remove(String pathId) => _gate.call(
    'host.workspaces',
    () => _base.remove(pathId),
    also: ['host.dispatch'],
  );
  @override
  Future<AgentPath> add({
    required String hostId,
    required String directory,
    String? label,
    String? projectId,
  }) => _gate.call(
    'host.workspaces',
    () => _base.add(
      hostId: hostId,
      directory: directory,
      label: label,
      projectId: projectId,
    ),
    requires: [if (projectId != null) 'projects'],
  );
  @override
  Future<void> put(AgentPath path) => _gate.call(
    'host.workspaces',
    () => _base.put(path),
    requires: [if (path.projectId != null) 'projects'],
  );
}

class PluginDispatchApi implements DispatchRepository {
  PluginDispatchApi(this._base, this._gate);
  final DispatchRepository _base;
  final PluginDataGate _gate;
  @override
  Stream<List<Dispatch>> watchForItem(String itemId) =>
      _gate.watch('host.dispatch', () => _base.watchForItem(itemId));
  @override
  Stream<Set<String>> watchSentItems() =>
      _gate.watch('host.dispatch', _base.watchSentItems);
  @override
  Future<void> record({
    required String itemId,
    required String pathId,
    required String paneId,
    required String title,
    required String agent,
    String? model,
  }) => _gate.call(
    'host.dispatch',
    () => _base.record(
      itemId: itemId,
      pathId: pathId,
      paneId: paneId,
      title: title,
      agent: agent,
      model: model,
    ),
  );
}
