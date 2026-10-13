import 'dart:async';
import 'dart:io';
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

/// The part is renamed only once it holds [length] bytes: a host that ignores the stop
/// signal sees stdin close, and cat ends as if the file were whole.
String putCommand(String path, int length) {
  final slash = path.lastIndexOf('/');
  final directory = slash <= 0 ? null : path.substring(0, slash);
  final part = shellQuote(
    '${path.substring(0, slash + 1)}.${path.substring(slash + 1)}.part',
  );
  return underSh(
    '${directory == null ? '' : 'mkdir -p ${shellQuote(directory)} && '}'
    '{ cat > $part && [ \$(wc -c < $part) -eq $length ] && '
    'mv -f $part ${shellQuote(path)}; } '
    '|| { rm -f $part; exit 1; }',
  );
}

typedef PutProgress = void Function(int sent);

const stoppedFailure = 'stopped';

final class TransferStopped implements Exception {
  const TransferStopped();
}

final class TransferStop {
  final _stopped = Completer<void>();

  bool get stopped => _stopped.isCompleted;

  Future<Never> get stopping =>
      _stopped.future.then((_) => throw const TransferStopped());

  void stop() {
    if (!stopped) _stopped.complete();
  }

  Stream<Uint8List> guard(Stream<Uint8List> stream) => stream.map((chunk) {
    if (stopped) throw const TransferStopped();
    return chunk;
  });

  Future<T> race<T>(Future<T> work) => Future.any([work, stopping]);
}

final class FileBody {
  FileBody.bytes(Uint8List this._bytes, {this.stop})
    : length = _bytes.length,
      _file = null;

  FileBody.file(File this._file, this.length, {this.stop}) : _bytes = null;

  FileBody._(this._bytes, this._file, this.length, this.stop);

  FileBody stoppedBy(TransferStop stop) =>
      FileBody._(_bytes, _file, length, stop);

  final int length;
  final TransferStop? stop;
  final Uint8List? _bytes;
  final File? _file;

  Stream<Uint8List> open() {
    final bytes = _bytes;
    final raw = bytes != null
        ? Stream.value(bytes)
        : _file!.openRead().map(
            (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          );
    return stop?.guard(raw) ?? raw;
  }

  Future<Uint8List> read() async => _bytes ?? await _file!.readAsBytes();
}

Future<Uint8List> collectBytes(Stream<Uint8List> stream) => stream
    .fold(BytesBuilder(copy: false), (all, chunk) => all..add(chunk))
    .then((all) => all.takeBytes());

typedef PutExec = Future<ExecResult> Function(
  String command,
  Stream<Uint8List> stdin,
);

Future<FileWrite> putFile({
  required Future<HostSftp> Function() sftp,
  required PutExec exec,
  required String path,
  required FileBody body,
  required Duration timeout,
  PutProgress? onProgress,
}) async {
  assert(path.startsWith('/'));
  final stop = body.stop;
  final HostSftp? channel = await _start(sftp);
  if (channel == null) {
    try {
      final put = _overExec(exec, path, body, onProgress);
      return await (stop?.race(put) ?? put);
    } on TransferStopped {
      return const FileWrite.failed(FileRoute.exec, stoppedFailure);
    }
  }
  final String failure;
  try {
    final write = _write(channel.client, path, body, onProgress);
    await (stop?.race(write) ?? write).timeout(timeout);
    await channel.close();
    return const FileWrite.landed(FileRoute.sftp);
  } on TransferStopped {
    failure = stoppedFailure;
  } on TimeoutException {
    failure = 'upload timed out';
  } on SftpStatusError catch (error) {
    failure = error.message;
  } on SftpError catch (error) {
    failure = '$error';
  } catch (_) {
    await channel.close();
    rethrow;
  }
  try {
    await channel.client.remove(path).timeout(sftpHandshakeDeadline);
  } catch (_) {
    // ignored: a part left behind is named as the file that did not land
  } finally {
    await channel.close();
  }
  return FileWrite.failed(FileRoute.sftp, failure);
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
  PutExec exec,
  String path,
  FileBody body,
  PutProgress? onProgress,
) async {
  var sent = 0;
  final result = await exec(
    putCommand(path, body.length),
    body.open().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent);
      return chunk;
    }),
  );
  if (result.ok) {
    onProgress?.call(body.length);
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
  FileBody body,
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
    await file.write(body.open(), onProgress: onProgress).done;
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

String getCommand(String path) => underSh('cat -- ${shellQuote(path)}');

typedef GetExec = Future<ExecResult> Function(
  String command,
  void Function(Uint8List chunk) onStdout,
);

Future<FileWrite> getFile({
  required Future<HostSftp> Function() sftp,
  required GetExec exec,
  required String path,
  required File into,
  required Duration timeout,
  PutProgress? onProgress,
  TransferStop? stop,
}) async {
  assert(path.startsWith('/'));
  await into.parent.create(recursive: true);
  final channel = await _start(sftp);
  final sink = into.openWrite();
  Future<void>? reading;
  var outcome = FileWrite.failed(
    channel == null ? FileRoute.exec : FileRoute.sftp,
    'download failed',
  );
  try {
    if (channel == null) {
      final read = _readOverExec(exec, path, sink, onProgress, stop);
      outcome = await (stop?.race(read) ?? read);
    } else {
      reading = _read(channel.client, path, sink, onProgress, stop);
      await (stop?.race(reading) ?? reading).timeout(timeout);
      outcome = const FileWrite.landed(FileRoute.sftp);
    }
  } on TransferStopped {
    outcome = FileWrite.failed(outcome.route, stoppedFailure);
  } on TimeoutException {
    outcome = FileWrite.failed(outcome.route, 'download timed out');
  } on SftpStatusError catch (error) {
    outcome = FileWrite.failed(FileRoute.sftp, error.message);
  } on SftpError catch (error) {
    outcome = FileWrite.failed(FileRoute.sftp, '$error');
  } finally {
    await channel?.close();
    await _release(sink, reading);
    if (!outcome.ok && await into.exists()) await into.delete();
  }
  return outcome;
}

/// A read the deadline cut short is still bound to [sink], which refuses to close until
/// the read lets go of it.
Future<void> _release(IOSink sink, Future<void>? reading) async {
  try {
    await reading?.timeout(const Duration(seconds: 2));
  } catch (_) {
    // ignored: the read's failure is already the outcome
  }
  try {
    await sink.close();
  } on StateError {
    // ignored: a read still stalled keeps the sink until its channel drops it
  }
}

Future<void> _read(
  SftpClient client,
  String path,
  IOSink sink,
  PutProgress? onProgress,
  TransferStop? stop,
) async {
  final file = await client.open(path);
  try {
    final read = file.read(onProgress: onProgress);
    await sink.addStream(stop?.guard(read) ?? read);
  } finally {
    await file.close();
  }
}

Future<FileWrite> _readOverExec(
  GetExec exec,
  String path,
  IOSink sink,
  PutProgress? onProgress,
  TransferStop? stop,
) async {
  var read = 0;
  final result = await exec(getCommand(path), (chunk) {
    if (stop?.stopped ?? false) return;
    sink.add(chunk);
    read += chunk.length;
    onProgress?.call(read);
  });
  if (result.ok) return const FileWrite.landed(FileRoute.exec);
  final said = result.err.trim();
  return FileWrite.failed(
    FileRoute.exec,
    said.isEmpty ? 'download exit ${result.exitCode}' : said,
  );
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
