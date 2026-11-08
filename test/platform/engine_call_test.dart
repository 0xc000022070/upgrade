import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/engine_call.dart';

void main() {
  group('EngineReply.parse', () {
    test('a reply that is not a map is malformed', () {
      for (final json in <Object?>[null, 'ok', 3, <Object?>[]]) {
        expect(
          EngineReply.parse(json),
          isA<EngineMalformed>().having(
            (m) => m.part,
            'part',
            EnginePart.reply,
          ),
        );
      }
    });

    test('anything but ok true is an error with what it said', () {
      final table = <(Object?, String?, String?)>[
        ({'ok': false}, null, null),
        ({'ok': 'yes', 'result': <String, Object?>{}}, null, null),
        ({'ok': false, 'error': 'boom'}, null, null),
        (
          {
            'ok': false,
            'error': {'kind': 'denied', 'message': 'no'},
          },
          'denied',
          'no',
        ),
        (
          {
            'ok': false,
            'error': {'kind': 'denied'},
          },
          'denied',
          null,
        ),
        (
          {
            'ok': false,
            'error': {'kind': 3, 'message': 'no'},
          },
          null,
          'no',
        ),
      ];
      for (final (json, kind, message) in table) {
        expect(
          EngineReply.parse(json),
          isA<EngineErr>()
              .having((e) => e.kind, 'kind', kind)
              .having((e) => e.message, 'message', message),
        );
      }
    });

    test('an ok reply needs a map result', () {
      expect(
        EngineReply.parse({
          'ok': true,
          'result': {'a': 1},
        }),
        isA<EngineOk>().having((o) => o.result, 'result', {'a': 1}),
      );
      for (final json in <Object?>[
        {'ok': true},
        {'ok': true, 'result': 'x'},
      ]) {
        expect(
          EngineReply.parse(json),
          isA<EngineMalformed>().having(
            (m) => m.part,
            'part',
            EnginePart.result,
          ),
        );
      }
    });
  });

  group('daemonStart', () {
    Future<Map<String, Object?>?> start(Object? reply) =>
        daemonStart('me', (_) async => reply)();

    test('hands back the result of an ok reply', () async {
      expect(
        await start({
          'ok': true,
          'result': {'port': 4},
        }),
        {'port': 4},
      );
    });

    test('is null for an error, a malformed reply or none at all', () async {
      expect(await start({'ok': false}), isNull);
      expect(await start({'ok': true}), isNull);
      expect(await start(null), isNull);
    });
  });
}
