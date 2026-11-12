import 'dart:convert';
import 'dart:typed_data';

import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

typedef PassRun = Future<ExecResult> Function(String command, Uint8List script);

class PassException implements Exception {
  const PassException(this.message);
  final String message;
  @override
  String toString() => message;
}

const passCommand = 'exec "\$SHELL" -lc \'exec sh -s\'';

const _store = 'd="\${PASSWORD_STORE_DIR:-\$HOME/.password-store}"\n';

Future<ExecResult> _run(PassRun run, String script) async {
  final result = await run(passCommand, utf8.encode(script));
  if (result.exitCode == 127) {
    throw const PassException('This host has no pass on its login PATH');
  }
  if (!result.ok) {
    // pass-otp dies with the whole otpauth URI, seed included, when it cannot parse one.
    final complaint = result.err
        .trim()
        .split('\n')
        .last
        .split('otpauth:')
        .first
        .trim();
    throw PassException(
      complaint.isEmpty
          ? 'pass exited ${result.exitCode}'
          : complaint.length > 300
          ? '${complaint.substring(0, 300)}…'
          : complaint,
    );
  }
  return result;
}

Future<List<String>> passList(PassRun run) async {
  final result = await _run(
    run,
    '$_store'
    'cd "\$d" 2>/dev/null || { echo "No password store at \$d" >&2; exit 2; }\n'
    'command -v pass >/dev/null || exit 127\n'
    'find . -name "*.gpg" ! -path "./.git/*" -type f\n',
  );
  return [
    for (final line in const LineSplitter().convert(result.out))
      if (line.startsWith('./') && line.endsWith('.gpg'))
        line.substring(2, line.length - 4),
  ]..sort();
}

bool passEntryValid(String entry) =>
    entry.isNotEmpty &&
    entry.length <= 1024 &&
    !entry.contains(RegExp(r'[\x00-\x1f]')) &&
    !entry.startsWith('/') &&
    !entry.startsWith('-') &&
    !entry
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..');

Future<String> passShow(PassRun run, String entry) => _firstLine(
  run,
  entry,
  'pass show',
  'The entry has no password on its first line',
);

Future<String> passOtp(PassRun run, String entry) async {
  final code = await _firstLine(
    run,
    entry,
    'pass otp code -q',
    'pass otp printed no code',
    guard:
        'pass otp --help >/dev/null 2>&1 || '
        '{ echo "This host has no pass-otp extension" >&2; exit 3; }\n',
  );
  if (!RegExp(r'^\d{4,10}$').hasMatch(code)) {
    throw const PassException('pass otp printed no code');
  }
  return code;
}

Future<String> _firstLine(
  PassRun run,
  String entry,
  String command,
  String empty, {
  String guard = '',
}) async {
  if (!passEntryValid(entry)) {
    throw const PassException('Not an entry in the password store');
  }
  final e = shellQuote(entry);
  final result = await _run(
    run,
    '$_store'
    'test -f "\$d"/$e.gpg || { echo "No such entry in \$d" >&2; exit 2; }\n'
    'command -v pass >/dev/null || exit 127\n'
    '$guard'
    'printf "\\036\\n"\n'
    'exec $command -- $e\n',
  );
  final out = result.out;
  final start = out.indexOf('\x1e\n');
  final line = start < 0
      ? ''
      : const LineSplitter().convert(out.substring(start + 2)).firstOrNull ??
            '';
  if (line.isEmpty) throw PassException(empty);
  return line;
}
