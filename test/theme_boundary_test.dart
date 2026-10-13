import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _roots = [
  'lib/features',
  'lib/app',
  'lib/application',
  'lib/builtin_plugins',
  'lib/platform',
];

final _banned = RegExp(
  r'UpgradeColors\.|UpgradeText\.|SyntaxColors\.|Color\(0x[0-9A-Fa-f]{6,8}\)',
);

void main() {
  test('no colour or text-style token outside the design layer', () {
    final offenders = <String>[];

    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll('\\', '/');
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (_banned.hasMatch(lines[i])) {
            offenders.add('$path:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
