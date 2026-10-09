import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _reasons = 'lib/platform/ssh/reasons.dart';

Iterable<File> _sources() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart') && file.path != _reasons);

Map<String, int> _mints(RegExp mint) => {
  for (final file in _sources())
    if (mint.allMatches(file.readAsStringSync()).length case final count
        when count > 0)
      file.path: count,
};

void main() {
  test('only HostLinks opens an ssh connection', () {
    final dials = RegExp(r'SSHSocket\.connect\(|SSHClient\(');
    final outside = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            file.path != 'lib/platform/host_links.dart' &&
            dials.hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(
      outside,
      isEmpty,
      reason: 'lease from HostLinks, or add a named dial to it',
    );
  });

  test('a UserIntent is minted only where a gesture lands', () {
    expect(
      _mints(RegExp(r'UserIntent\.fromGesture\b')),
      {
        'lib/features/shell/attach_sheet.dart': 2,
        'lib/features/shell/host_shell_screen.dart': 6,
      },
      reason:
          'mint UserIntent only in a gesture handler; a new call site needs the '
          "owner's approval before it joins this list",
    );
  });

  test('a PlatformSignal is minted only where the platform calls in', () {
    expect(
      _mints(RegExp(r'PlatformSignal\.fromPlatform\b')),
      {'lib/main.dart': 1, 'lib/features/shell/shell_wake.dart': 3},
      reason:
          'mint PlatformSignal only in a platform callback; a new call site needs '
          "the owner's approval before it joins this list",
    );
  });

  test('no other part of the ssh library reaches the private mints', () {
    final private = RegExp(r'\b(UserIntent|PlatformSignal)\._\b');
    expect(
      [
        for (final file in _sources())
          if (private.hasMatch(file.readAsStringSync())) file.path,
      ],
      isEmpty,
      reason: 'mint through fromGesture or fromPlatform only',
    );
  });
}
