import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Theme section's rule: colour and text style come from context.tokens,
/// not from the constant classes or a raw literal, anywhere outside the
/// design layer that defines them.
///
/// lib/features/settings/plugins_panel.dart is a second agent's work in
/// flight on the plugin marketplace, on a parallel branch, and stays out of
/// this migration's reach.
///
/// lib/platform/plugins/ui.dart resolves plugin colour through pluginColor,
/// which still falls back to the constant classes; that lands with the
/// plugin bridge, not here.
const _roots = [
  'lib/features',
  'lib/app',
  'lib/application',
  'lib/plugins',
  'lib/platform',
];

const _excluded = {
  'lib/features/settings/plugins_panel.dart',
  'lib/platform/plugins/ui.dart',
};

final _banned = RegExp(
  r'DazzleColors\.|DazzleText\.|SyntaxColors\.|Color\(0x[0-9A-Fa-f]{6,8}\)',
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
        if (_excluded.contains(path)) continue;

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
