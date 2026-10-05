import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/plugins/plugin_page.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/ui.dart';

import 'support/themed_app.dart';

final _themedTokens = UpgradeTokens.house.copyWith(
  brightness: Brightness.light,
  backgroundPrimary: const Color(0xFF111111),
  backgroundSecondary: const Color(0xFF222222),
  surfacePrimary: const Color(0xFF333333),
  surfaceSecondary: const Color(0xFF444444),
  borderSubtle: const Color(0xFF555555),
  borderNormal: const Color(0xFF666666),
  textPrimary: const Color(0xFF777777),
  textSecondary: const Color(0xFF888888),
  textMuted: const Color(0xFF999999),
  textDisabled: const Color(0xFFAAAAAA),
  accent: const Color(0xFF00FF00),
  accentMuted: const Color(0xFF00CC00),
  warning: const Color(0xFFFFCC00),
  danger: const Color(0xFFFF0000),
);

const _manifest = '''
manifest_version = 4
id = "test.theme"
name = "Theme test"
purpose = "Verify the UI API accepts theme-aware manifests."
version = "1.0.0"
upgrade_api = "^2.1.0"
ui_api = 1
[runtime]
kind = "luau"
entry = "main.luau"
[permissions]
ui = ["page"]
[contributes]
[[contributes.pages]]
id = "main"
title = "Theme"
''';

void main() {
  group('pluginColor resolves against live tokens', () {
    test('semantic names follow the tokens instance, not a fixed palette', () {
      expect(pluginColor(_themedTokens, 'accent'), _themedTokens.accent);
      expect(pluginColor(_themedTokens, 'muted'), _themedTokens.textMuted);
      expect(
        pluginColor(_themedTokens, 'background'),
        _themedTokens.backgroundPrimary,
      );
      expect(
        pluginColor(_themedTokens, 'surface'),
        _themedTokens.backgroundSecondary,
      );
      expect(pluginColor(_themedTokens, 'border'), _themedTokens.borderNormal);
      expect(pluginColor(_themedTokens, 'danger'), _themedTokens.danger);
      expect(
        pluginColor(UpgradeTokens.house, 'danger'),
        UpgradeTokens.house.danger,
      );
      expect(
        pluginColor(_themedTokens, 'danger'),
        isNot(UpgradeTokens.house.danger),
      );
    });

    test('a hex string wins over the tokens instance', () {
      expect(pluginColor(_themedTokens, '#123456'), const Color(0xFF123456));
    });

    test('an unrecognised value falls back to the given colour or text', () {
      expect(pluginColor(_themedTokens, null, Colors.pink), Colors.pink);
      expect(pluginColor(_themedTokens, null), _themedTokens.textPrimary);
    });
  });

  group('the UI API accepts version 1 and 2', () {
    test('ui_api 1 and 2 parse; other values are rejected', () {
      expect(PluginManifest.parse(_manifest).uiVersion, 1);
      expect(
        PluginManifest.parse(_manifest.replaceFirst('ui_api = 1', 'ui_api = 2'))
            .uiVersion,
        2,
      );
      expect(
        () => PluginManifest.parse(
          _manifest.replaceFirst('ui_api = 1', 'ui_api = 3'),
        ),
        throwsA(isA<PluginException>()),
      );
    });
  });

  group('the mount event carries the theme table', () {
    test('every field is present as the app-facing table shape', () {
      final table = pluginThemeTable(_themedTokens);
      expect(table['brightness'], 'light');
      expect(table['background'], '#111111');
      expect(table['surface'], '#333333');
      expect(table['border'], '#666666');
      expect(table['text'], '#777777');
      expect(table['muted'], '#999999');
      expect(table['accent'], '#00ff00');
      expect(table['danger'], '#ff0000');
    });

    test('the house palette reports dark brightness', () {
      expect(pluginThemeTable(UpgradeTokens.house)['brightness'], 'dark');
    });
  });

  group('house layout node kinds render through PluginUi', () {
    Map<String, Object?> node(
      String kind,
      Map<String, Object?> props, [
      List<Object?> children = const [],
    ]) => {
      'kind': kind,
      'props': {'key': kind, ...props},
      'children': children,
    };

    testWidgets('panel, section, list_row, status_tag and bracket_label all '
        'build without error', (tester) async {
      final view = PluginUiNode.parse(
        node('screen', const {}, [
          node(
            'panel',
            const {'title': 'A panel'},
            [
              node('text', const {'key': 'panel-text', 'text': 'inside'}),
            ],
          ),
          node(
            'section',
            const {'title': 'A section'},
            [
              node('text', const {'key': 'section-text', 'text': 'inside'}),
            ],
          ),
          node('list_row', const {
            'key': 'row',
            'title': 'Row title',
            'subtitle': 'Row subtitle',
            'value': '3',
            'node': true,
          }),
          node('status_tag', const {
            'key': 'tag',
            'label': 'DONE',
            'color': 'accent',
          }),
          node('bracket_label', const {
            'key': 'bracket',
            'label': 'SHA',
            'value': 'deadbeef',
          }),
        ]),
        allowCanvas: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: PluginUi(node: view, values: const {}, onEvent: (_) {}),
          ),
        ),
      );
      // Panel and section titles decode on entry off a periodic timer; pumpAndSettle does not
      // drain it.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('A PANEL'), findsOneWidget);
      expect(find.text('A SECTION'), findsOneWidget);
      expect(find.text('Row title'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('[ SHA ]'), findsOneWidget);
      expect(find.text('deadbeef'), findsOneWidget);
    });
  });
}
