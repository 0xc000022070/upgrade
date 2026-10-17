import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/features/code/file_icons.dart';
import 'package:striked/features/code/syntax.dart';

import '../../support/themed_app.dart';

/// The table is keyed by the name `languageOf` gives a grammar and nothing ties the two
/// together at compile time, so a grammar renamed on one side loses its glyph silently.

Future<int> _draw(WidgetTester tester, Widget icon, {double scale = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme,
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: child!,
      ),
      home: Align(child: icon),
    ),
  );
  return tester.widget<Text>(find.byType(Text)).data!.codeUnitAt(0);
}

Future<int> _file(WidgetTester tester, String path) =>
    _draw(tester, FileIcon.file(languageOf(path)));

const _own = <String, String>{
  'dart': 'lib/main.dart',
  'javascript': 'web/app.js',
  'typescript': 'src/app.ts',
  'go': 'cmd/herdr/main.go',
  'rust': 'src/main.rs',
  'python': 'tools/run.py',
  'c': 'src/port.c',
  'cpp': 'src/port.cpp',
  'java': 'App.java',
  'kotlin': 'App.kt',
  'scala': 'App.scala',
  'bash': 'scripts/boot.sh',
  'yaml': 'pubspec.yaml',
  'json': 'package.json',
  'sql': 'schema.sql',
  'nix': 'flake.nix',
  'lua': 'init.lua',
  'markdown': 'README.md',
  'dockerfile': 'Dockerfile',
  'makefile': 'Makefile',
  'css': 'site.css',
  'scss': 'site.scss',
  'xml': 'index.html',
  'graphql': 'schema.graphql',
};

void main() {
  testWidgets('every grammar with a glyph of its own draws a different one', (
    tester,
  ) async {
    final drawn = <String, int>{};
    for (final entry in _own.entries) {
      drawn[entry.key] = await _file(tester, entry.value);
    }
    final unknown = await _file(tester, 'notes.zzz');

    expect(drawn.values.toSet(), hasLength(_own.length));
    expect(drawn.values, isNot(contains(unknown)));
  });

  testWidgets('ini and properties share the one config mark', (tester) async {
    final ini = await _file(tester, '.editorconfig');
    final properties = await _file(tester, 'gradle.properties');
    final unknown = await _file(tester, 'notes.zzz');

    expect(properties, ini);
    expect(ini, isNot(unknown));

    for (final path in _own.values) {
      expect(await _file(tester, path), isNot(ini));
    }
  });

  testWidgets('a grammar with no glyph draws what no grammar draws', (
    tester,
  ) async {
    final unknown = await _file(tester, 'notes.zzz');

    for (final path in ['api.proto', 'fix.diff', 'calls.http', 'nginx.conf']) {
      expect(languageOf(path), isNotNull, reason: path);
      expect(await _file(tester, path), unknown, reason: path);
    }
  });

  testWidgets('an open directory and a closed one draw different folders', (
    tester,
  ) async {
    final open = await _draw(tester, const FileIcon.directory(open: true));
    final closed = await _draw(tester, const FileIcon.directory(open: false));
    final unknown = await _file(tester, 'notes.zzz');

    expect(open, isNot(closed));
    expect([open, closed], isNot(contains(unknown)));
  });

  testWidgets('a glyph under a doubled text size is drawn at the one size', (
    tester,
  ) async {
    await _file(tester, 'lib/main.dart');
    final plain = tester.getSize(find.byType(Text));

    await _draw(tester, FileIcon.file(languageOf('lib/main.dart')), scale: 2);

    expect(tester.getSize(find.byType(Text)), plain);
  });
}
