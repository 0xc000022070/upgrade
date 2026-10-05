import 'package:upgrade_luau/data_api.dart';

import '../../application/plugins.dart';
import '../../data/database.dart';
import '../../data/repositories/task_repository.dart';
import '../../platform/plugins/manifest.dart';

PluginSelection dropPluginSelection(Task task, TaskRepository repository) {
  if (task.projectId != null) {
    throw const PluginException('Select an unfiled drop');
  }
  return PluginSelection(DataRecord(task.id, task.title, 1), (proposal) async {
    if (proposal.value.trim().isEmpty) {
      throw const PluginException('Title cannot be empty');
    }
    // The repository compares the complete original row, not a timestamp.
    return repository.applyDropTitle(task, proposal.value);
  });
}
