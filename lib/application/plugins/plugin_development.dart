import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/plugins/plugin_check.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';

enum PluginDevPhase { connecting, watching, failed }

final class PluginDevState {
  const PluginDevState({
    required this.host,
    required this.path,
    required this.phase,
    this.line,
    this.check,
    this.shown,
  });

  final Host host;
  final String path;
  final PluginDevPhase phase;

  final String? line;

  final PluginCheck? check;

  final PluginCheck? shown;

  PluginDevState copyWith({
    PluginDevPhase? phase,
    String? line,
    PluginCheck? check,
    PluginCheck? shown,
  }) => PluginDevState(
    host: host,
    path: path,
    phase: phase ?? this.phase,
    line: line,
    check: check ?? this.check,
    shown: shown ?? this.shown,
  );
}

const pluginDevPoll = Duration(seconds: 2);

String pluginWorkspaceCommand(String path) => underSh(
  'cd -- ${_directory(path)} || exit 3\n'
  'if [ -f $pluginPreviewAsk ]; then\n'
  '  a=\$(head -c 64 $pluginPreviewAsk)\n'
  '  printf "%s\\n%s\\n%s" $pluginPreviewAsk "\$(printf %s "\$a" | wc -c | tr -d " ")" "\$a"\n'
  'fi\n'
  'find . -maxdepth 4 -name ".?*" -prune -o -type f \\( -name "*.luau" '
  '-o -path ./$pluginManifestFile -o -path "./fixtures/*.json" '
  '! -path "./fixtures/*/*" \\) -size -${maxWorkspaceFileKib}k -print | '
  'LC_ALL=C sort | head -n ${maxWorkspaceFiles + 1} | '
  'while IFS= read -r f; do\n'
  '  printf "%s\\n%s\\n" "\${f#./}" "\$(wc -c < "\$f" | tr -d " ")"\n'
  '  cat -- "\$f"\n'
  'done\n',
);

String _directory(String path) => path == '~' || path.startsWith('~/')
    ? '"\$HOME"${shellQuote(path.substring(1))}'
    : shellQuote(path);

String pluginPreviewWriteCommand(String path) => underSh(
  'cd -- ${_directory(path)} || exit 3\n'
  'mkdir -p .upgrade/preview && '
  'cat > $pluginPreviewResult.part && '
  'mv -f $pluginPreviewResult.part $pluginPreviewResult\n',
);

const pluginWorkspaceCreateCommand = 'sh -s';

/// Stdin for [pluginWorkspaceCreateCommand]. Exits 4 unless the folder is empty
/// or holds only a preview's `.upgrade`.
String pluginWorkspaceCreateScript(
  String path,
  Map<String, String> files, {
  Random? random,
}) {
  final source = random ?? Random.secure();
  final body = files.values.join();
  String delimiter;
  do {
    delimiter =
        'UPGRADE_${[for (var i = 0; i < 8; i++) source.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
  } while (body.contains(delimiter));
  final script = StringBuffer(
    'set -e\n'
    'd=${_directory(path)}\n'
    'p=\$(dirname -- "\$d")\n'
    'mkdir -p -- "\$p"\n'
    'if [ -e "\$d" ] && [ -n "\$(ls -A -- "\$d" | grep -Fvx .upgrade)" ]; then exit 4; fi\n'
    't=\$(mktemp -d "\$p/.upgrade-new.XXXXXX")\n'
    "trap 'rm -rf -- \"\$t\"' EXIT\n"
    "trap 'exit 1' HUP INT TERM\n",
  );
  for (final MapEntry(key: file, value: text) in files.entries) {
    final target = '"\$t"/${shellQuote(file)}';
    script
      ..write('mkdir -p -- "\$(dirname -- $target)"\n')
      ..write("cat > $target <<'$delimiter'\n")
      ..write(text.endsWith('\n') || text.isEmpty ? text : '$text\n')
      ..write('$delimiter\n');
    if (file.endsWith('.sh')) script.write('chmod +x -- $target\n');
  }
  script.write(
    'if [ -e "\$d" ]; then rm -rf -- "\$d/.upgrade"; rmdir -- "\$d" || exit 4; fi\n'
    '[ ! -e "\$d" ] || exit 4\n'
    'mv -- "\$t" "\$d"\n'
    'if [ -e "\$d/\${t##*/}" ]; then rm -rf -- "\$d/\${t##*/}"; exit 4; fi\n'
    'trap - EXIT\n',
  );
  return script.toString();
}

Map<String, String>? parseWorkspaceFrames(Uint8List bytes) {
  final files = <String, String>{};
  var at = 0;
  String? line() {
    final end = bytes.indexOf(10, at);
    if (end < 0) return null;
    final text = utf8.decode(bytes.sublist(at, end), allowMalformed: true);
    at = end + 1;
    return text;
  }

  while (at < bytes.length) {
    final path = line();
    final size = int.tryParse(line() ?? '');
    if (path == null || size == null || at + size > bytes.length) return null;
    if (isPluginWorkspaceFile(path) || path == pluginPreviewAsk) {
      files[path] = utf8.decode(
        bytes.sublist(at, at + size),
        allowMalformed: true,
      );
    }
    at += size;
  }
  return files;
}

final pluginDevelopmentProvider =
    NotifierProvider.autoDispose<PluginDevelopment, PluginDevState?>(
      PluginDevelopment.new,
    );

class PluginDevelopment extends Notifier<PluginDevState?> {
  HostLease? _lease;
  LuauWorker? _worker;
  Timer? _timer;
  var _session = 0;
  int? _polling;
  var _misses = 0;
  String? _written;
  String? _answered;
  var _writeFailed = false;
  Map<String, Object?> _theme = fixtureTheme;

  @override
  PluginDevState? build() {
    ref.onDispose(_end);
    return null;
  }

  Future<void> start(
    Host host,
    String path, {
    required Map<String, Object?> theme,
    Map<String, String>? create,
  }) async {
    final previous = state;
    final same =
        previous?.host.id == host.id &&
        previous?.path == path &&
        jsonEncode(theme) == jsonEncode(_theme);
    _written = null;
    _answered = null;
    _end();
    final session = ++_session;
    _theme = theme;
    state = PluginDevState(
      host: host,
      path: path,
      phase: PluginDevPhase.connecting,
      check: same ? previous?.check : null,
      shown: same ? previous?.shown : null,
    );
    final privateKey = await ref
        .read(ed25519KeysProvider)
        .privateKey(host.keyId);
    if (session != _session) return;
    if (privateKey == null) {
      state = state?.copyWith(
        phase: PluginDevPhase.failed,
        line: 'key rejected',
      );
      return;
    }
    try {
      final settleBy = DateTime.now().add(_settleWithin);
      HostLease lease;
      while (true) {
        try {
          lease = await ref
              .read(hostLinksProvider)
              .lease(
                address: host.address,
                port: host.port,
                user: host.user,
                privateKey: privateKey,
                verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
                use: HostUse.files,
              );
          break;
        } on DialSettling catch (settling) {
          final left = settleBy.difference(DateTime.now());
          if (left <= Duration.zero) rethrow;
          await settling.settled.timeout(left, onTimeout: () {});
          if (session != _session) return;
        }
      }
      if (session != _session) {
        lease.release();
        return;
      }
      _lease = lease;
      if (create != null) {
        final made = await leaseExec(
          lease,
          pluginWorkspaceCreateCommand,
          stdin: utf8.encode(pluginWorkspaceCreateScript(path, create)),
          timeout: remoteCommandDeadline,
        );
        if (!made.ok) {
          throw _CreateFailure(
            made.exitCode == 4 ? 'folder not empty' : 'cannot create folder',
          );
        }
        if (session != _session) return;
      }
    } catch (error) {
      if (session != _session) return;
      _lease?.release();
      _lease = null;
      state = state?.copyWith(
        phase: PluginDevPhase.failed,
        line: _failureLine(error),
      );
      return;
    }
    _worker = LuauWorker();
    unawaited(_poll(session));
    _timer = Timer.periodic(pluginDevPoll, (_) => _poll(session));
  }

  void stop() {
    _end();
    state = null;
  }

  void _end() {
    _session++;
    _misses = 0;
    _writeFailed = false;
    _timer?.cancel();
    _timer = null;
    _lease?.release();
    _lease = null;
    final worker = _worker;
    _worker = null;
    if (worker != null) unawaited(worker.close());
  }

  Future<void> _poll(int session) async {
    final lease = _lease;
    final worker = _worker;
    final current = state;
    if (session != _session ||
        _polling == session ||
        lease == null ||
        worker == null ||
        current == null) {
      return;
    }
    if (lease.closed) {
      _end();
      state = current.copyWith(
        phase: PluginDevPhase.failed,
        line: 'link closed',
      );
      return;
    }
    _polling = session;
    try {
      final reply = await leaseExec(
        lease,
        pluginWorkspaceCommand(current.path),
        timeout: remoteCommandDeadline,
      );
      if (session != _session) return;
      final files = reply.ok ? parseWorkspaceFrames(reply.stdout) : null;
      final asked = files?.remove(pluginPreviewAsk)?.trim();
      final ask = asked != null && asked.length <= 64 ? asked : null;
      if (files == null) {
        // One miss is let pass: a sync swaps the directory under a poll.
        if (++_misses < 2) return;
        state = state?.copyWith(
          phase: PluginDevPhase.failed,
          line: reply.exitCode == 3 ? 'not found' : 'workspace unreadable',
        );
        return;
      }
      _misses = 0;
      var check = current.check;
      var shown = current.shown;
      if (current.phase != PluginDevPhase.watching && !_writeFailed) {
        state = current.copyWith(phase: PluginDevPhase.watching);
      }
      if (workspaceRevision(files) != check?.revision) {
        check = await checkPluginWorkspace(
          files,
          theme: _theme,
          invoke:
              ({
                required key,
                required source,
                required action,
                required input,
              }) async => (await worker.invoke(
                key: key,
                source: source,
                action: action,
                input: input,
              )).value,
        );
        if (session != _session) return;
        if (check.ok && check.renders.isNotEmpty) shown = check;
        state = current.copyWith(
          phase: _writeFailed ? PluginDevPhase.failed : PluginDevPhase.watching,
          line: _writeFailed ? current.line : null,
          check: check,
          shown: shown,
        );
      }
      if (check == null || (check.revision == _written && ask == _answered)) {
        return;
      }
      final envelope = check.envelope(
        command: 'preview',
        artifacts: {'shown_revision': ?shown?.revision},
        context: {
          'runtime': 'phone',
          'renderer': 'PluginUi',
          'host': current.host.name,
          'workspace': current.path,
          'ask': ?ask,
        },
      );
      String? failure;
      try {
        final wrote = await leaseExec(
          lease,
          pluginPreviewWriteCommand(current.path),
          stdin: utf8.encode(
            const JsonEncoder.withIndent('  ').convert(envelope),
          ),
          timeout: remoteCommandDeadline,
        );
        if (!wrote.ok) failure = 'cannot write $pluginPreviewResult';
      } catch (error) {
        failure = _failureLine(error);
      }
      if (session != _session) return;
      if (failure == null) {
        _written = check.revision;
        _answered = ask;
        if (_writeFailed) {
          _writeFailed = false;
          state = state?.copyWith(phase: PluginDevPhase.watching);
        }
      } else {
        _written = null;
        _writeFailed = true;
        state = state?.copyWith(phase: PluginDevPhase.failed, line: failure);
      }
    } catch (error) {
      if (session != _session || ++_misses < 2) return;
      state = state?.copyWith(
        phase: PluginDevPhase.failed,
        line: _failureLine(error),
      );
    } finally {
      if (_polling == session) _polling = null;
    }
  }
}

const _settleWithin = Duration(seconds: 10);

final class _CreateFailure implements Exception {
  const _CreateFailure(this.line);
  final String line;
}

String _failureLine(Object error) => switch (error) {
  _CreateFailure(:final line) => line,
  HostFailure(:final line) => line.words,
  _ when filesFailureLine(error) == '$error' => 'failed',
  _ => filesFailureLine(error),
};
