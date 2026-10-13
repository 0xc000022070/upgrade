import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/shell/host_clipboard.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/host_files.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

export 'package:upgrade/platform/ssh/host_files.dart'
    show FileBody, FileWrite, PutProgress, uploadWidth, uploadsSharing;
export 'package:upgrade/platform/workspace/workspace_model.dart'
    show DirEntry, DirEntryKind;

final class HostFilesFailure implements Exception {
  const HostFilesFailure(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

abstract interface class HostFiles {
  Host get host;

  Future<String> home();

  Future<List<DirEntry>?> list(String directory);

  Future<FileWrite> put(
    String path,
    FileBody body, {
    int sharing = 1,
    PutProgress? onProgress,
  });

  Future<FileWrite> get(
    String path,
    File into, {
    required int size,
    int sharing = 1,
    PutProgress? onProgress,
  });

  Future<String?> copy({String? text, String? imageAt, String? mime});

  void close();
}

typedef HostFilesOpener = Future<HostFiles> Function(Host host);

final hostFilesOpenerProvider = Provider<HostFilesOpener>((ref) {
  final links = ref.read(hostLinksProvider);
  final keys = ref.read(ed25519KeysProvider);
  return (host) async {
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) throw const HostFilesFailure('key rejected');
    try {
      final lease = await links.lease(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
        use: HostUse.files,
      );
      return _LeasedFiles(host, lease);
    } catch (error) {
      throw HostFilesFailure(filesFailureLine(error));
    }
  };
});

String filesFailureLine(Object error) {
  if (isKeyFailure(error)) return 'key rejected';
  if (error is TimeoutException) return 'timed out';
  if (error is SocketException) return 'unreachable';
  return '$error';
}

Duration transferDeadline(int bytes, int sharing) =>
    remoteCommandDeadline + Duration(milliseconds: bytes * sharing ~/ 64);

String homeCommand() => underSh(r'printf %s "$HOME"');

String listCommand(String directory) => underSh(
  'cd -- ${shellQuote(directory)} || exit 1\n'
  "LC_ALL=C find -L . -mindepth 1 -maxdepth 1 -printf '%Y\\t%s\\t%f\\n' 2>/dev/null\n"
  'exit 0\n',
);

final class _LeasedFiles implements HostFiles {
  _LeasedFiles(this.host, this._lease);

  @override
  final Host host;
  final HostLease _lease;
  HostClipboard? _clipboard;

  Future<ExecResult> _exec(String command, {Uint8List? stdin}) =>
      leaseExec(_lease, command, stdin: stdin, timeout: remoteCommandDeadline);

  @override
  Future<String> home() async {
    final reply = await _exec(homeCommand());
    final home = reply.out.trim();
    return reply.ok && home.startsWith('/') ? home : '/';
  }

  @override
  Future<List<DirEntry>?> list(String directory) async {
    final reply = await _exec(listCommand(directory));
    return reply.ok ? parseListing(reply.out) : null;
  }

  @override
  Future<FileWrite> put(
    String path,
    FileBody body, {
    int sharing = 1,
    PutProgress? onProgress,
  }) {
    final timeout = transferDeadline(body.length, sharing);
    return putFile(
      sftp: _lease.sftp,
      exec: (command, feed) =>
          transferExec(_lease, command, feed: feed, timeout: timeout),
      path: path,
      body: body,
      timeout: timeout,
      onProgress: onProgress,
    );
  }

  @override
  Future<FileWrite> get(
    String path,
    File into, {
    required int size,
    int sharing = 1,
    PutProgress? onProgress,
  }) {
    final timeout = transferDeadline(size, sharing);
    return getFile(
      sftp: _lease.sftp,
      exec: (command, onStdout) =>
          transferExec(_lease, command, onStdout: onStdout, timeout: timeout),
      path: path,
      into: into,
      timeout: timeout,
      onProgress: onProgress,
    );
  }

  @override
  Future<String?> copy({String? text, String? imageAt, String? mime}) async {
    assert((text == null) != (imageAt == null));
    final clipboard = _clipboard ??= parseProbe(
      await _exec(underSh(probeScript)),
    );
    final image = imageAt == null
        ? null
        : clipboardImageCommand(clipboard, imageAt, mime: mime ?? 'image/png');
    final command = image ?? clipboardTextCommand(clipboard);
    if (command == null) return clipboard.reason ?? 'no clipboard';
    final set = await _exec(
      command,
      stdin: image == null ? utf8.encode(text ?? imageAt!) : null,
    );
    return set.ok
        ? null
        : '${clipboard.label.toLowerCase()} exit ${set.exitCode}';
  }

  @override
  void close() => _lease.release();
}
