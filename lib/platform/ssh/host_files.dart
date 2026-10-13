import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:upgrade/platform/ssh/connection_supervisor.dart'
    show ExecResult;
import 'package:upgrade/platform/shell/remote_shell.dart'
    show shellQuote, underSh;

final class HostSftp {
  HostSftp(this.client, {this.closeDeadline = const Duration(seconds: 2)});

  final SftpClient client;

  final Duration closeDeadline;
  final _done = Completer<void>();

  Future<void> get done => _done.future;

  Future<void> close() async {
    try {
      await client.close().timeout(closeDeadline);
    } catch (_) {
      // ignored: a channel the host already closed, or never will, has nothing left to wait for.
    } finally {
      if (!_done.isCompleted) _done.complete();
    }
  }
}

enum FileRoute { sftp, exec }

final class FileWrite {
  const FileWrite.landed(this.route) : failure = null;

  const FileWrite.failed(this.route, String this.failure);

  final FileRoute route;

  final String? failure;

  bool get ok => failure == null;
}

/// A host that grants the subsystem but whose server never answers init; past this the
/// file goes over exec.
const sftpHandshakeDeadline = Duration(seconds: 3);

String putCommand(String path) {
  final slash = path.lastIndexOf('/');
  final directory = slash <= 0 ? null : path.substring(0, slash);
  return underSh(
    '${directory == null ? '' : 'mkdir -p ${shellQuote(directory)} && '}'
    'cat > ${shellQuote(path)}',
  );
}

typedef PutProgress = void Function(int sent);

Future<FileWrite> putFile({
  required Future<HostSftp> Function() sftp,
  required Future<ExecResult> Function(String command, Uint8List stdin) exec,
  required String path,
  required Uint8List bytes,
  required Duration timeout,
  PutProgress? onProgress,
}) async {
  assert(path.startsWith('/'));
  final HostSftp? channel = await _start(sftp);
  if (channel == null) return _overExec(exec, path, bytes, onProgress);
  try {
    await _write(channel.client, path, bytes, onProgress).timeout(timeout);
    return const FileWrite.landed(FileRoute.sftp);
  } on TimeoutException {
    return const FileWrite.failed(FileRoute.sftp, 'upload timed out');
  } on SftpStatusError catch (error) {
    return FileWrite.failed(FileRoute.sftp, error.message);
  } on SftpError catch (error) {
    return FileWrite.failed(FileRoute.sftp, '$error');
  } finally {
    await channel.close();
  }
}

Future<HostSftp?> _start(Future<HostSftp> Function() sftp) async {
  final HostSftp channel;
  try {
    channel = await sftp();
  } on SSHChannelRequestError {
    // ignored: the refusal is the answer, and the caller takes exec instead.
    return null;
  }
  try {
    await channel.client.handshake.timeout(sftpHandshakeDeadline);
    return channel;
  } catch (error) {
    await channel.close();
    if (error is TimeoutException || error is SftpError) return null;
    rethrow;
  }
}

Future<FileWrite> _overExec(
  Future<ExecResult> Function(String command, Uint8List stdin) exec,
  String path,
  Uint8List bytes,
  PutProgress? onProgress,
) async {
  final result = await exec(putCommand(path), bytes);
  if (result.ok) {
    onProgress?.call(bytes.length);
    return const FileWrite.landed(FileRoute.exec);
  }
  final said = result.err.trim();
  return FileWrite.failed(
    FileRoute.exec,
    said.isEmpty ? 'upload exit ${result.exitCode}' : said,
  );
}

Future<void> _write(
  SftpClient client,
  String path,
  Uint8List bytes,
  PutProgress? onProgress,
) async {
  await _directories(client, path);
  final file = await client.open(
    path,
    mode:
        SftpFileOpenMode.create |
        SftpFileOpenMode.truncate |
        SftpFileOpenMode.write,
  );
  try {
    await file.write(Stream.value(bytes), onProgress: onProgress).done;
  } finally {
    await file.close();
  }
}

Future<void> _directories(SftpClient client, String path) async {
  final parts = path.split('/')..removeLast();
  var at = '';
  for (final part in parts.skip(1)) {
    at = '$at/$part';
    if (await _isDirectory(client, at)) continue;
    try {
      await client.mkdir(at);
    } on SftpStatusError {
      if (!await _isDirectory(client, at)) rethrow;
    }
  }
}

Future<bool> _isDirectory(SftpClient client, String path) async {
  try {
    return (await client.stat(path)).isDirectory;
  } on SftpStatusError {
    // ignored: a path stat cannot see is not a directory, which mkdir then settles.
    return false;
  }
}

const uploadWidth = 3;

int uploadsSharing(int count) => count < uploadWidth ? count : uploadWidth;

List<Future<T>> atMost<T>(
  int width,
  List<Future<T> Function()> tasks, {
  List<int>? sizes,
}) {
  assert(sizes == null || sizes.length == tasks.length);
  final results = [for (final _ in tasks) Completer<T>()];
  final order = smallestFirst(sizes ?? List.filled(tasks.length, 0));
  var next = 0;
  void start() {
    if (next >= tasks.length) return;
    final index = order[next++];
    Future.sync(tasks[index])
        .then(results[index].complete, onError: results[index].completeError)
        .whenComplete(start);
  }

  for (var slot = 0; slot < width; slot++) {
    start();
  }
  return [for (final result in results) result.future..ignore()];
}

List<int> smallestFirst(List<int> sizes) =>
    List.generate(sizes.length, (i) => i)..sort((a, b) {
      final by = sizes[a].compareTo(sizes[b]);
      return by != 0 ? by : a.compareTo(b);
    });
