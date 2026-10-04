import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
