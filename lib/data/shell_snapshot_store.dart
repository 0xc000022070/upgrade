import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract class ShellSnapshotStore {
  Future<Uint8List?> read(String hostId, int number);

  Future<void> write(String hostId, int number, Uint8List bytes);

  Future<void> drop(String hostId, int number);

  Future<void> keepOnly(Set<(String, int)> tabs);
}

class FileShellSnapshotStore implements ShellSnapshotStore {
  FileShellSnapshotStore(this.directory);

  static Future<FileShellSnapshotStore> open() async {
    final support = await getApplicationSupportDirectory();
    return FileShellSnapshotStore(
      Directory(p.join(support.path, 'shell-snapshots')),
    );
  }

  final Directory directory;

  static const _suffix = '.snap';

  File _file(String hostId, int number) => File(
    p.join(directory.path, '${Uri.encodeComponent(hostId)}.$number$_suffix'),
  );

  @override
  Future<Uint8List?> read(String hostId, int number) async {
    try {
      return await _file(hostId, number).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(String hostId, int number, Uint8List bytes) async {
    await directory.create(recursive: true);
    final file = _file(hostId, number);
    final partial = File('${file.path}.part');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(file.path);
  }

  @override
  Future<void> drop(String hostId, int number) async {
    try {
      await _file(hostId, number).delete();
    } on FileSystemException {
      return;
    }
  }

  @override
  Future<void> keepOnly(Set<(String, int)> tabs) async {
    if (!await directory.exists()) return;
    final kept = {
      for (final (hostId, number) in tabs) _file(hostId, number).path,
    };
    await for (final entry in directory.list()) {
      if (entry is File && !kept.contains(entry.path)) {
        try {
          await entry.delete();
        } on FileSystemException {
          continue;
        }
      }
    }
  }
}

class InMemoryShellSnapshotStore implements ShellSnapshotStore {
  final snapshots = <(String, int), Uint8List>{};

  @override
  Future<Uint8List?> read(String hostId, int number) async =>
      snapshots[(hostId, number)];

  @override
  Future<void> write(String hostId, int number, Uint8List bytes) async {
    snapshots[(hostId, number)] = bytes;
  }

  @override
  Future<void> drop(String hostId, int number) async {
    snapshots.remove((hostId, number));
  }

  @override
  Future<void> keepOnly(Set<(String, int)> tabs) async {
    snapshots.removeWhere((key, _) => !tabs.contains(key));
  }
}
