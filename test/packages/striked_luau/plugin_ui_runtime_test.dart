import 'package:striked_luau/striked_luau.dart';
import 'package:striked_luau/ui_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'UI values cross the worker and constructors preserve low-level nodes',
    () async {
      final worker = LuauWorker();
      addTearDown(worker.close);
      const source =
          '''
$luauUiSdk
return ui.app {
 init = function() return {count = 0} end,
 update = function(state, event) state.count += event.amount; return state end,
 view = function(state) return ui.Column {key = "root", children = {
   ui.Text {key = "label", text = tostring(state.count)},
   ui.node("canvas", {key = "art", commands = {}}, {}),
 }} end,
}
''';
      final result = await worker.invoke(
        key: 'ui',
        source: source,
        action: 'frame',
        input: {
          'event': {'amount': 2},
        },
      );
      final value = result.value! as Map<String, Object?>;
      expect((value['state']! as Map<String, Object?>)['count'], 2);
      expect((value['view']! as Map<String, Object?>)['kind'], 'column');
      expect(result.responseBytes, greaterThan(0));
      final second = await worker.invoke(
        key: 'ui',
        source: source,
        action: 'frame',
        input: {
          'state': value['state'],
          'event': {'amount': 3},
        },
      );
      expect((second.value! as Map<String, Object?>)['state'], {'count': 5});
      expect(second.cold, isFalse);
    },
  );

  test(
    'UI transport rejects functions and cyclic or excessive output',
    () async {
      for (final source in [
        'return {frame = function() return {callback = function() end} end}',
        'return {frame = function() local t = {}; t.self = t; return t end}',
        'return {frame = function() return string.rep("x", 262145) end}',
      ]) {
        final worker = LuauWorker();
        addTearDown(worker.close);
        await expectLater(
          worker.invoke(
            key: source,
            source: source,
            action: 'frame',
            input: {},
          ),
          throwsA(isA<LuauException>()),
        );
      }
    },
  );
}
