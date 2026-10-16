import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/hosts/phone_linux_picker.dart';
import 'package:upgrade/platform/phone_linux.dart';

import '../../support/themed_app.dart';

void main() {
  final catalog = PhoneLinuxCatalog.fromJson(
    jsonDecode(File(PhoneLinuxCatalog.asset).readAsStringSync())
        as Map<String, Object?>,
  );

  testWidgets('Alpine takes Cursor Agent only once Nix is chosen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    PhoneLinuxSetup? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await pickPhoneLinuxSetup(
              context,
              catalog: catalog,
              name: 'PHONE',
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    await tap('phone-linux-distro-alpine');
    await tap('phone-linux-next');
    expect(find.text('LINUX ON THIS PHONE · PACKAGES'), findsOneWidget);
    expect(find.text('[ PACKAGE MANAGERS ]'), findsOneWidget);
    expect(find.text('APK'), findsOneWidget);
    expect(find.text("Alpine's own · always there"), findsOneWidget);
    expect(find.text('ALPINE LINUX 3.24'), findsOneWidget);

    await tap('phone-linux-next');
    expect(find.text('LINUX ON THIS PHONE · TOOLS'), findsOneWidget);
    expect(find.text('[ MULTIPLEXERS ]'), findsOneWidget);
    expect(find.text('[ AGENTS ]'), findsOneWidget);
    const reason =
        'Needs glibc: choose NIX in the previous step, or pick Ubuntu or Arch';
    expect(find.text(reason), findsOneWidget);

    await tap('phone-linux-back');
    await tap('phone-linux-nix');
    await tap('phone-linux-next');
    expect(find.text(reason), findsNothing);
    expect(find.text('ALPINE LINUX 3.24 · NIX'), findsOneWidget);

    await tap('phone-linux-tool-tmux');
    await tap('phone-linux-tool-cursor');
    await tap('phone-linux-install');

    expect(picked?.distro, 'alpine');
    expect(picked?.nix, isTrue);
    expect(picked?.tools, {'tmux', 'cursor'});
  });
}
