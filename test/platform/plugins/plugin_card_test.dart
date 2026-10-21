import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/plugins/contributions.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/ui.dart';
import 'package:striked_luau/striked_luau.dart';
import 'package:striked_luau/ui_sdk.dart';

String _manifest({
  String ui = '["widget"]',
  String widget = 'locations = ["home.card"]\ndefault_location = "home.card"',
}) =>
    '''
manifest_version = 4
id = "test.card"
name = "Card test"
version = "1.0.0"
striked_api = "^2.1.0"
ui_api = 1
[runtime]
kind = "luau"
entry = "main.luau"
[permissions]
ui = $ui
[contributes]
[[contributes.widgets]]
id = "status"
title = "Status"
$widget
default_size = "auto"
sizes = [{ id = "auto", title = "Automatic", min_width = 280, max_width = 720 }]
''';

void main() {
  test('a script plugin declares a Home card and its refresh is a grant', () {
    final manifest = PluginManifest.parse(
      _manifest(
        widget: 'locations = ["home.card"]\ndefault_location = "home.card"\nrefresh_minutes = 30\nfill = true',
      ),
    );
    final widget = manifest.widgets.single;
    expect(widget.surface, isNull);
    expect(widget.fill, isTrue);
    expect(widget.refresh, const Duration(minutes: 30));
    expect(widget.locations, {PluginPlacementLocation.homeCard});
    expect(manifest.permissions.map((p) => p.id), {
      'ui.widget',
      'ui.widget.status.refresh.30',
    });
  });

  test('a script widget is refused off Home, unpermitted or too eager', () {
    for (final source in [
      _manifest(ui: '["page"]'),
      _manifest(
        widget:
            'locations = ["home.composer"]\ndefault_location = "home.composer"',
      ),
      _manifest(
        widget: 'surface = "home.status"\nlocations = ["home.card"]\ndefault_location = "home.card"',
      ),
      _manifest(
        widget: 'locations = ["home.card"]\ndefault_location = "home.card"\nrefresh_minutes = 5',
      ),
      _manifest(
        widget: 'locations = ["home.card"]\ndefault_location = "home.card"\nfill = "yes"',
      ),
    ]) {
      expect(
        () => PluginManifest.parse(source),
        throwsA(isA<PluginException>()),
      );
    }
  });

  test('a card is one panel of display nodes', () {
    Map<String, Object?> node(
      String kind, [
      List<Map<String, Object?>> children = const [],
    ]) => {
      'kind': kind,
      'props': {'key': '$kind${children.length}'},
      'children': children,
    };
    expect(
      PluginUiNode.parse(
        node('panel', [node('text')]),
        allowCanvas: false,
        card: true,
      ).kind,
      'panel',
    );
    expect(
      PluginUiNode.parse(
        node('panel', [node('canvas')]),
        allowCanvas: true,
        card: true,
      ).children.single.kind,
      'canvas',
    );
    expect(
      PluginUiNode.parse(
        node('panel', [
          {
            'kind': 'row',
            'props': {'key': 'split'},
            'children': [
              {
                'kind': 'list_row',
                'props': {'key': 'left', 'flex': 1},
              },
              {
                'kind': 'column',
                'props': {'key': 'right', 'width': 80},
              },
            ],
          },
        ]),
        allowCanvas: false,
        card: true,
      ).children.single.children.length,
      2,
    );
    for (final view in [
      node('column'),
      node('panel', [node('input')]),
      node('panel', [node('list')]),
      node('panel', [node('stack')]),
      {
        'kind': 'panel',
        'props': {'key': 'root'},
        'children': [
          {
            'kind': 'text',
            'props': {'key': 'grow', 'flex': 1},
          },
        ],
      },
      node('panel', [
        node('row', [node('list_row')]),
      ]),
      node('panel', [
        node('row', [
          {
            'kind': 'box',
            'props': {'key': 'half', 'flex': 0.5},
          },
        ]),
      ]),
      {
        'kind': 'panel',
        'props': {'key': 'root'},
        'children': [
          {
            'kind': 'canvas',
            'props': {'key': 'pan', 'interactive': true},
          },
        ],
      },
    ]) {
      expect(
        () => PluginUiNode.parse(view, allowCanvas: true, card: true),
        throwsA(isA<PluginException>()),
      );
    }
  });

  test('ui.app draws the named card from shared state', () async {
    final worker = LuauWorker();
    addTearDown(worker.close);
    const source =
        '''
$luauUiSdk
return ui.app {
 init = function() return {count = 0} end,
 update = function(state, event) if event.type == "action" then state.count += 1 end; return state end,
 view = function(state) return ui.Page {key = "page"} end,
 cards = {status = function(state) return ui.Panel {key = "card", title = tostring(state.count)} end},
}
''';
    final result = await worker.invoke(
      key: 'card',
      source: source,
      action: 'card',
      input: {
        'widget': 'status',
        'event': {'type': 'action'},
      },
    );
    final value = result.value! as Map<String, Object?>;
    expect(value['state'], {'count': 1});
    expect((value['view']! as Map<String, Object?>)['kind'], 'panel');
    await expectLater(
      worker.invoke(
        key: 'card',
        source: source,
        action: 'card',
        input: {'widget': 'missing'},
      ),
      throwsA(isA<LuauException>()),
    );
  });
}
