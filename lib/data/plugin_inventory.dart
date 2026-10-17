import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as path;

import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/data/database.dart';

class NativeDatasetInventory {
  const NativeDatasetInventory({
    required this.name,
    required this.records,
    required this.fieldBytes,
    required this.fileBytes,
    required this.missingFiles,
  });
  final String name;
  final int records;
  final int fieldBytes;
  final int fileBytes;
  final int missingFiles;
}

class NativeDatasetMount {
  const NativeDatasetMount(this.table, {this.where = '1', this.images = false});
  final TableInfo<Table, Object?> table;
  final String where;
  final bool images;
}

class NativeDatasetInspector {
  NativeDatasetInspector(this._db, this.mounts, {this.attachmentDirectory});
  final AppDatabase _db;
  final Map<String, NativeDatasetMount> mounts;
  final Directory? attachmentDirectory;

  Future<List<NativeDatasetInventory>> inspect(PluginManifest manifest) async {
    final result = <NativeDatasetInventory>[];
    for (final dataset in manifest.hostDatasets.values) {
      final mount = mounts[dataset.service];
      if (mount == null || dataset.schemaVersion != 1) {
        throw const PluginException(
          'Native dataset schema or mount is unavailable',
        );
      }
      final columns = mount.table.$columns
          .map((c) => 'coalesce(length(cast("${c.name}" AS BLOB)), 0)')
          .join(' + ');
      final row = await _db
          .customSelect(
            'SELECT count(*) AS records, coalesce(sum($columns), 0) AS bytes '
            'FROM "${mount.table.actualTableName}" WHERE ${mount.where}',
          )
          .getSingle();
      var fileBytes = 0;
      var missing = 0;
      if (mount.images && attachmentDirectory != null) {
        final paths = await _db
            .customSelect(
              'SELECT DISTINCT value FROM "${mount.table.actualTableName}" WHERE kind = ?',
              variables: [const Variable('image')],
            )
            .get();
        final root = path.normalize(attachmentDirectory!.absolute.path);
        final resolvedRoot = await attachmentDirectory!.resolveSymbolicLinks();
        for (final row in paths) {
          final relative = row.read<String>('value');
          final target = path.normalize(path.join(root, relative));
          if (path.isAbsolute(relative) ||
              !path.isWithin(root, target) ||
              await FileSystemEntity.type(target, followLinks: false) !=
                  FileSystemEntityType.file) {
            missing++;
            continue;
          }
          final file = File(target);
          final resolved = await file.resolveSymbolicLinks();
          if (!path.isWithin(resolvedRoot, resolved)) {
            missing++;
            continue;
          }
          fileBytes += await file.length();
        }
      }
      result.add(
        NativeDatasetInventory(
          name: dataset.name,
          records: row.read<int>('records'),
          fieldBytes: row.read<int>('bytes'),
          fileBytes: fileBytes,
          missingFiles: missing,
        ),
      );
    }
    return result;
  }
}

NativeDatasetInspector builtinDatasetInspector(
  AppDatabase db, {
  Directory? attachmentDirectory,
}) => NativeDatasetInspector(db, {
  'items': NativeDatasetMount(db.tasks),
  'attachments': NativeDatasetMount(db.attachments, images: true),
  'item_notes': NativeDatasetMount(
    db.notes,
    where: 'task_id IS NOT NULL OR project_id IS NULL',
  ),
  'projects': NativeDatasetMount(db.projects),
  'goals': NativeDatasetMount(db.goals),
  'project_notes': NativeDatasetMount(
    db.notes,
    where: 'task_id IS NULL AND project_id IS NOT NULL',
  ),
}, attachmentDirectory: attachmentDirectory);
