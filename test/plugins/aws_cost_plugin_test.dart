import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/plugins/plugin_reach.dart';
import 'package:upgrade/features/plugins/plugin_ui.dart';
import 'package:upgrade/platform/aws/aws_billing.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

import '../support/plugin_packages.dart';

Iterable<PluginUiNode> walk(PluginUiNode node) sync* {
  yield node;
  for (final child in node.children) {
    yield* walk(child);
  }
}

List<String> texts(PluginUiNode node) => [
  for (final entry in walk(node))
    for (final prop in ['text', 'title', 'value', 'subtitle'])
      if (entry.props[prop] case final String text) text,
];

Map<String, Object?> day(String date, List<(String, String, String)> rows) => {
  'TimePeriod': {'Start': date},
  'Estimated': date == '2026-11-08',
  'Groups': [
    for (final (service, record, amount) in rows)
      {
        'Keys': [service, record],
        'Metrics': {
          'UnblendedCost': {'Amount': amount, 'Unit': 'USD'},
        },
      },
  ],
};

Future<Map<String, Object?>> fakeAws(
  AwsOperation operation,
  Map<String, Object?> payload,
) async => switch (operation) {
  AwsOperation.costAndUsage when payload['NextPageToken'] == null => {
    'ResultsByTime': [
      day('2026-10-05', [('Amazon EC2', 'Usage', '3')]),
      day('2026-10-20', [('Amazon EC2', 'Usage', '7')]),
    ],
    'NextPageToken': 'next',
  },
  AwsOperation.costAndUsage => {
    'ResultsByTime': [
      day('2026-11-01', [
        ('Amazon EC2', 'Usage', '1.006'),
        ('Amazon EC2', 'Credit', '-1.006'),
        ('AWS Lambda', 'Usage', '0.2'),
      ]),
      day('2026-11-08', [('Amazon EC2', 'Usage', '2'), ('Tax', 'Tax', '0.5')]),
    ],
  },
  AwsOperation.costForecast => {
    'Total': {'Amount': '9.876', 'Unit': 'USD'},
  },
  AwsOperation.accountPlanState => {
    'accountPlanType': 'FREE',
    'accountPlanStatus': 'ACTIVE',
    'accountPlanRemainingCredits': {'amount': 140.5, 'unit': 'USD'},
    'accountPlanExpirationDate': 1798675200,
  },
  AwsOperation.freeTierUsage => {
    'freeTierUsages': [
      {
        'service': 'AWS Lambda',
        'description': '1000000 requests a month',
        'freeTierType': 'Always Free',
        'unit': 'Request',
        'actualUsageAmount': 250000.0,
        'forecastedUsageAmount': 900000.0,
        'limit': 1000000.0,
      },
    ],
  },
  AwsOperation.callerIdentity => {'Account': '123456789012'},
  AwsOperation.describeBudgets => throw const AwsCostException(
    'AWS refused: AccessDeniedException',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signs the AWS SigV4 get-vanilla vector', () {
    expect(
      sigV4Authorization(
        keys: (
          id: 'AKIDEXAMPLE',
          secret: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        ),
        region: 'us-east-1',
        service: 'service',
        method: 'GET',
        path: '/',
        headers: {
          'Host': 'example.amazonaws.com',
          'X-Amz-Date': '20150830T123600Z',
        },
        body: const [],
        at: DateTime.utc(2015, 8, 30, 12, 36),
      ),
      'AWS4-HMAC-SHA256 '
      'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
      'SignedHeaders=host;x-amz-date, '
      'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    );
  });

  test(
    'billing splits credits and tax out and keeps a refused block as a note',
    () async {
      final asked = <(AwsOperation, Map<String, Object?>)>[];
      final billing = await awsBilling((operation, payload) {
        asked.add((operation, payload));
        return fakeAws(operation, payload);
      }, DateTime.utc(2026, 11, 8, 9, 30));
      expect(
        asked.first.$2,
        containsPair('TimePeriod', {
          'Start': '2026-10-01',
          'End': '2026-11-09',
        }),
      );
      expect(
        asked
            .firstWhere((a) => a.$1 == AwsOperation.costForecast)
            .$2['TimePeriod'],
        {'Start': '2026-11-08', 'End': '2026-12-01'},
      );
      expect(billing, containsPair('net', 2.7));
      expect(billing, containsPair('charges', 3.21));
      expect(billing, containsPair('credits', -1.01));
      expect(billing, containsPair('tax', 0.5));
      expect(billing['last'], {
        'month': '2026-10',
        'net': 10.0,
        'charges': 10.0,
        'sameDays': 3.0,
      });
      expect(billing['estimated'], isTrue);
      expect(billing['services'], [
        {'name': 'Amazon EC2', 'charges': 3.01, 'net': 2.0},
        {'name': 'AWS Lambda', 'charges': 0.2, 'net': 0.2},
        {'name': 'Tax', 'charges': 0.0, 'net': 0.5},
      ]);
      expect(billing['days'], [
        {'date': '2026-11-01', 'amount': 1.21},
        {'date': '2026-11-08', 'amount': 2.0},
      ]);
      expect(billing['forecast'], 9.88);
      expect(billing['forecastEnd'], '2026-11-30');
      expect(billing['plan'], {
        'type': 'FREE',
        'status': 'ACTIVE',
        'remaining': 140.5,
        'currency': 'USD',
        'expires': '2026-12-31',
      });
      expect(
        (billing['freeTier']! as List).single,
        containsPair('used', 250000.0),
      );
      expect(billing['budgets'], isEmpty);
      expect(billing['notes'], [
        {'block': 'BUDGETS', 'error': 'AWS refused: AccessDeniedException'},
      ]);
    },
  );

  test('a paid account shows no free plan block', () async {
    final billing = await awsBilling(
      (operation, payload) => operation == AwsOperation.accountPlanState
          ? Future.value({
              'accountPlanType': 'PAID',
              'accountPlanStatus': 'ACTIVE',
            })
          : fakeAws(operation, payload),
      DateTime.utc(2026, 11, 8),
    );
    expect(billing.containsKey('plan'), isFalse);
  });

  test('a failed cost read fails the fetch before any other call', () async {
    final asked = <AwsOperation>[];
    await expectLater(
      awsBilling((operation, payload) async {
        asked.add(operation);
        throw const AwsCostException(
          'AWS refused: UnrecognizedClientException',
        );
      }, DateTime.utc(2026, 11, 8)),
      throwsA(isA<AwsCostException>()),
    );
    expect(asked, [AwsOperation.costAndUsage]);
  });

  test(
    'the host route runs a fixed aws command and feeds the payload on stdin',
    () async {
      final runs = <(String, String)>[];
      ExecResult answer = ExecResult(
        exitCode: 0,
        stdout: utf8.encode('motd\n{"Account": "123456789012"}'),
        stderr: Uint8List(0),
      );
      final call = awsCliCall((command, stdin) async {
        runs.add((command, utf8.decode(stdin)));
        return answer;
      });
      expect(await call(AwsOperation.callerIdentity, const {}), {
        'Account': '123456789012',
      });
      await call(AwsOperation.costForecast, {'Metric': "x'; rm -rf ~"});
      expect(
        runs.last.$1,
        'exec "\$SHELL" -lc \'env AWS_PAGER= aws ce get-cost-forecast '
        '--cli-input-json "\$(cat)" --region us-east-1 --output json\'',
      );
      expect(runs.last.$2, '{"Metric":"x\'; rm -rf ~"}');
      answer = ExecResult(
        exitCode: 255,
        stdout: Uint8List(0),
        stderr: utf8.encode(
          '\nError when retrieving token from sso: Token has expired and refresh failed\n',
        ),
      );
      await expectLater(
        call(AwsOperation.costAndUsage, const {}),
        throwsA(
          isA<AwsCostException>().having(
            (e) => e.message,
            'message',
            'Error when retrieving token from sso: Token has expired and refresh failed',
          ),
        ),
      );
      answer = ExecResult(
        exitCode: 127,
        stdout: Uint8List(0),
        stderr: Uint8List(0),
      );
      await expectLater(
        call(AwsOperation.costAndUsage, const {}),
        throwsA(isA<AwsCostException>()),
      );
    },
  );

  group('plugin', () {
    late Directory root;
    late LuauWorker worker;
    final package = awsCostPackage();
    Map<String, Object?>? state;
    late Map<String, Object?> response;
    Future<void> send(
      Map<String, Object?> event, {
      String action = 'frame',
    }) async {
      response = await invokePlugin(worker, package, action, {
        'state': state,
        'event': {'token': 'seed', 'now': '2026-11-08T09:30:00', ...event},
      });
      state = response['state']! as Map<String, Object?>;
    }

    PluginUiNode view() =>
        PluginUiNode.parse(response['view'], allowCanvas: true);

    setUp(() async {
      state = null;
      root = await Directory.systemTemp.createTemp('upgrade-aws-cost-');
      worker = LuauWorker(
        dataDirectory: root.path,
        dataTimeBudget: const Duration(days: 1),
      );
    });
    tearDown(() async {
      await worker.close();
      await root.delete(recursive: true);
    });

    test('review names the AWS reach in plain words', () {
      expect(
        pluginReach(package.manifest).map((reach) => reach.line),
        contains(
          'READ YOUR AWS BILLING WHEN YOU TAP, WITH THE ACCESS YOU CHOOSE ON THIS SHEET',
        ),
      );
    });

    test('fetch asks for billing and every block survives a reopen', () async {
      await send({'type': 'mount'});
      expect(texts(view()), contains(startsWith('Nothing fetched yet')));
      final card = state;
      await send({'type': 'action', 'id': 'fetch'});
      final effects = response['effects']! as List<Object?>;
      expect(effects.single, containsPair('operation', 'billing'));
      await send({
        'type': 'result',
        'id': 'billing',
        'ok': true,
        'value': await awsBilling(fakeAws, DateTime.utc(2026, 11, 8, 9, 30)),
      });
      state = card;
      await send({'type': 'mount'});
      final shown = texts(view());
      expect(
        shown,
        contains(
          matches(r'UTC · ESTIMATED · FETCHED \d{4}-\d\d-\d\d \d\d:\d\d$'),
        ),
      );
      expect(
        shown,
        containsAll([
          'USD 2.70',
          'CHARGES USD 3.21 · CREDITS USD -1.01 · TAX USD 0.50',
          'SAME DAYS OF 2026-10 · USD 3.00 CHARGED (+7%)',
          'FORECAST TO 2026-11-30',
          'USD 9.88',
          'USD 140.50',
          'Amazon EC2',
          'NET USD 2.00',
          '2026-11-01',
          'AWS Lambda',
          '250000 / 1000000 Request · 25%',
          'BUDGETS',
          'AWS refused: AccessDeniedException',
        ]),
      );
      expect(walk(view()).where((node) => node.kind == 'canvas'), hasLength(1));
    });

    test('a refusal is shown and the fetch can be tapped again', () async {
      await send({'type': 'mount'});
      await send({'type': 'action', 'id': 'fetch'});
      await send({
        'type': 'result',
        'id': 'billing',
        'ok': false,
        'error': 'No AWS access chosen',
      });
      expect(texts(view()), contains('No AWS access chosen'));
      expect(state!['busy'], isFalse);
    });
  });
}
