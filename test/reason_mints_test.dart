import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const allowed = {
  'lib/features/shell/attach_sheet.dart': 2,
  'lib/features/shell/host_shell_screen.dart': 6,
  'lib/features/shell/shell_wake.dart': 3,
  'lib/main.dart': 1,
  'lib/platform/ssh/reasons.dart': 3,
};

final mint = RegExp(
  r'\b(?:UserIntent|PlatformSignal)\s*\(|'
  r'\b(?:UserIntent|PlatformSignal|ShellEnded)\s*\.\s*[A-Za-z]\w*',
);
final comment = RegExp(r'/\*[\s\S]*?\*/|//[^\n]*');

void main() {
  test('reason mints appear only where the owner approved', () {
    final found = <String, int>{
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          file.path: mint
              .allMatches(file.readAsStringSync().replaceAll(comment, ''))
              .length,
    }..removeWhere((_, count) => count == 0);
    for (final path in {...allowed.keys, ...found.keys}) {
      expect(
        found[path] ?? 0,
        allowed[path] ?? 0,
        reason:
            '$path: reason mint count changed. New mints need the owner\'s '
            'approval per the policy header in '
            'lib/platform/ssh/connection_supervisor.dart; a removed one '
            'must leave this allowlist.',
      );
    }
  });
}
