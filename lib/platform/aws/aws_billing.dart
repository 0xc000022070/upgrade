import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:upgrade/platform/ssh/connection_supervisor.dart';

typedef AwsKeys = ({String id, String secret});

class AwsCostException implements Exception {
  const AwsCostException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum AwsOperation {
  costAndUsage('ce', 'GetCostAndUsage'),
  costForecast('ce', 'GetCostForecast'),
  accountPlanState('freetier', 'GetAccountPlanState'),
  freeTierUsage('freetier', 'GetFreeTierUsage'),
  callerIdentity('sts', 'GetCallerIdentity'),
  describeBudgets('budgets', 'DescribeBudgets');

  const AwsOperation(this.service, this.name);
  final String service;
  final String name;

  String get command => name
      .replaceAllMapped(RegExp('(?<!^)[A-Z]'), (m) => '-${m[0]}')
      .toLowerCase();
}

typedef AwsCall = Future<Map<String, Object?>> Function(
  AwsOperation operation,
  Map<String, Object?> payload,
);

const awsBillingPolicy = '''
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "freetier:GetAccountPlanState",
        "freetier:GetFreeTierUsage",
        "budgets:ViewBudget"
      ],
      "Resource": "*"
    }
  ]
}''';

String _hex(List<int> bytes) => sha256.convert(bytes).toString();

List<int> _hmac(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

String _stamp(DateTime at) {
  final iso = at.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '');
  return '${iso.substring(0, 15)}Z';
}

/// AWS Signature Version 4 for a request with no query string. [headers] must
/// already hold `host` and `x-amz-date`; every header given is signed.
String sigV4Authorization({
  required AwsKeys keys,
  required String region,
  required String service,
  required String method,
  required String path,
  required Map<String, String> headers,
  required List<int> body,
  required DateTime at,
}) {
  final stamp = _stamp(at);
  final day = stamp.substring(0, 8);
  final names = headers.keys.map((name) => name.toLowerCase()).toList()..sort();
  final lower = {
    for (final MapEntry(:key, :value) in headers.entries)
      key.toLowerCase(): value.trim().replaceAll(RegExp(r'\s+'), ' '),
  };
  final signed = names.join(';');
  final canonical = [
    method,
    path,
    '',
    for (final name in names) '$name:${lower[name]}',
    '',
    signed,
    _hex(body),
  ].join('\n');
  final scope = '$day/$region/$service/aws4_request';
  final toSign = [
    'AWS4-HMAC-SHA256',
    stamp,
    scope,
    _hex(utf8.encode(canonical)),
  ].join('\n');
  var key = _hmac(utf8.encode('AWS4${keys.secret}'), day);
  for (final part in [region, service, 'aws4_request']) {
    key = _hmac(key, part);
  }
  final signature = Hmac(sha256, key).convert(utf8.encode(toSign)).toString();
  return 'AWS4-HMAC-SHA256 Credential=${keys.id}/$scope, '
      'SignedHeaders=$signed, Signature=$signature';
}

const _endpoints = {
  'ce': ('ce.us-east-1.amazonaws.com', 'AWSInsightsIndexService', '1.1'),
  'freetier': ('freetier.us-east-1.api.aws', 'AWSFreeTierService', '1.0'),
  'budgets': ('budgets.amazonaws.com', 'AWSBudgetServiceGateway', '1.1'),
  'sts': ('sts.amazonaws.com', '', ''),
};

Future<T> withAwsKeys<T>(
  AwsKeys keys,
  Future<T> Function(AwsCall call) work, {
  HttpClient Function()? client,
  DateTime Function()? now,
}) async {
  final http = (client ?? HttpClient.new)()
    ..connectionTimeout = const Duration(seconds: 15);
  final clock = now ?? DateTime.now;
  try {
    return await work(
      (operation, payload) => _signed(http, keys, clock(), operation, payload),
    );
  } finally {
    http.close(force: true);
  }
}

Future<Map<String, Object?>> _signed(
  HttpClient http,
  AwsKeys keys,
  DateTime at,
  AwsOperation operation,
  Map<String, Object?> payload,
) async {
  final (host, prefix, json) = _endpoints[operation.service]!;
  final query = operation.service == 'sts';
  final body = utf8.encode(
    query ? 'Action=${operation.name}&Version=2011-06-15' : jsonEncode(payload),
  );
  final headers = {
    'content-type': query
        ? 'application/x-www-form-urlencoded; charset=utf-8'
        : 'application/x-amz-json-$json',
    'host': host,
    'x-amz-date': _stamp(at),
    if (!query) 'x-amz-target': '$prefix.${operation.name}',
  };
  final authorization = sigV4Authorization(
    keys: keys,
    region: 'us-east-1',
    service: operation.service,
    method: 'POST',
    path: '/',
    headers: headers,
    body: body,
    at: at,
  );
  final request = await http
      .postUrl(Uri.https(host, '/'))
      .timeout(const Duration(seconds: 15));
  headers.forEach(request.headers.set);
  request.headers.set('authorization', authorization);
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close().timeout(const Duration(seconds: 30));
  final text = await response
      .transform(utf8.decoder)
      .join()
      .timeout(const Duration(seconds: 30));
  if (query) return _queryAnswer(response.statusCode, text);
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw AwsCostException('AWS answered ${response.statusCode}');
  }
  if (decoded is! Map<String, Object?>) {
    throw AwsCostException('AWS answered ${response.statusCode}');
  }
  if (response.statusCode != 200) {
    final type = '${decoded['__type'] ?? ''}'.split('#').last;
    final message = decoded['message'] ?? decoded['Message'] ?? '';
    throw AwsCostException(
      'AWS refused: ${type.isEmpty ? response.statusCode : type}'
      '${message == '' ? '' : ' · $message'}',
    );
  }
  return decoded;
}

String? _tag(String xml, String name) =>
    RegExp('<$name>([^<]*)</$name>').firstMatch(xml)?.group(1);

Map<String, Object?> _queryAnswer(int status, String xml) {
  final account = _tag(xml, 'Account');
  if (status == 200 && account != null) return {'Account': account};
  final code = _tag(xml, 'Code') ?? '$status';
  final message = _tag(xml, 'Message');
  throw AwsCostException(
    'AWS refused: $code${message == null ? '' : ' · $message'}',
  );
}

/// The payload reaches `aws` as one quoted `"$(cat)"` argument: `--cli-input-json
/// file:///dev/stdin` fails when stdin is a pipe.
AwsCall awsCliCall(
  Future<ExecResult> Function(String command, Uint8List stdin) run,
) => (operation, payload) async {
  final script =
      'env AWS_PAGER= aws ${operation.service} ${operation.command} '
      '--cli-input-json "\$(cat)" --region us-east-1 --output json';
  final result = await run(
    'exec "\$SHELL" -lc \'$script\'',
    utf8.encode(jsonEncode(payload)),
  );
  if (result.exitCode == 127) {
    throw const AwsCostException('This host has no aws CLI on its login PATH');
  }
  if (!result.ok) {
    final complaint = result.err.trim().split('\n').last.trim();
    throw AwsCostException(
      complaint.isEmpty
          ? 'aws exited ${result.exitCode}'
          : complaint.length > 300
          ? '${complaint.substring(0, 300)}…'
          : complaint,
    );
  }
  final out = result.out;
  final start = out.indexOf('{');
  try {
    final decoded = jsonDecode(start < 0 ? out : out.substring(start));
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // ignored: the throw below reports bad JSON as a refusal
  }
  throw const AwsCostException('The aws CLI did not answer in JSON');
};

String _ymd(DateTime day) => day.toIso8601String().substring(0, 10);

double _cents(double amount) => (amount * 100).roundToDouble() / 100;

List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

double _amount(Object? value) => double.tryParse('$value') ?? 0;

Future<List<Map<String, Object?>>> _pages(
  AwsCall call,
  AwsOperation operation,
  Map<String, Object?> payload,
  String token, {
  int limit = 20,
}) async {
  final pages = <Map<String, Object?>>[];
  String? next;
  for (var page = 0; page < limit; page++) {
    final answer = await call(operation, {...payload, token: ?next});
    pages.add(answer);
    final more = answer[token];
    next = more is String && more.isNotEmpty ? more : null;
    if (next == null) break;
  }
  return pages;
}

Map<String, Object?> awsCostFold(
  DateTime today,
  List<Map<String, Object?>> pages,
) {
  final monthStart = _ymd(DateTime.utc(today.year, today.month));
  final split = {'charges': 0.0, 'credits': 0.0, 'refunds': 0.0, 'tax': 0.0};
  final perDay = <String, double>{};
  final gross = <String, double>{};
  final net = <String, double>{};
  var lastNet = 0.0;
  var lastCharges = 0.0;
  var lastSameDays = 0.0;
  String? currency;
  var estimated = false;
  for (final answer in pages) {
    for (final result in _list(answer['ResultsByTime'])) {
      final day = _map(_map(result)['TimePeriod'])['Start'];
      if (day is! String || day.length != 10) continue;
      final current = day.compareTo(monthStart) >= 0;
      if (current) {
        perDay.putIfAbsent(day, () => 0);
        if (_map(result)['Estimated'] == true) estimated = true;
      }
      for (final group in _list(_map(result)['Groups'])) {
        final names = _list(_map(group)['Keys']);
        final cost = _map(_map(_map(group)['Metrics'])['UnblendedCost']);
        if (names.length < 2 || cost.isEmpty) continue;
        final amount = _amount(cost['Amount']);
        if (cost['Unit'] case final String unit) currency ??= unit;
        final bucket = switch ('${names[1]}') {
          'Credit' => 'credits',
          'Refund' => 'refunds',
          'Tax' => 'tax',
          _ => 'charges',
        };
        final charge = bucket == 'charges';
        if (!current) {
          lastNet += amount;
          if (charge) {
            lastCharges += amount;
            if ((int.tryParse(day.substring(8)) ?? 99) <= today.day) {
              lastSameDays += amount;
            }
          }
          continue;
        }
        split[bucket] = split[bucket]! + amount;
        final service = '${names[0]}';
        net[service] = (net[service] ?? 0) + amount;
        if (charge) {
          gross[service] = (gross[service] ?? 0) + amount;
          perDay[day] = perDay[day]! + amount;
        }
      }
    }
  }
  final services = net.keys.toList()
    ..sort((a, b) => (gross[b] ?? 0).compareTo(gross[a] ?? 0));
  final last = DateTime.utc(today.year, today.month - 1);
  return {
    'start': monthStart,
    'end': _ymd(today),
    'currency': currency ?? 'USD',
    'estimated': estimated,
    'net': _cents(split.values.fold(0.0, (sum, v) => sum + v)),
    for (final MapEntry(:key, :value) in split.entries) key: _cents(value),
    'last': {
      'month': _ymd(last).substring(0, 7),
      'net': _cents(lastNet),
      'charges': _cents(lastCharges),
      'sameDays': _cents(lastSameDays),
    },
    'days': [
      for (final day in perDay.keys.toList()..sort())
        {'date': day, 'amount': _cents(perDay[day]!)},
    ],
    'services': [
      for (final name in services.take(40))
        if (_cents(gross[name] ?? 0) != 0 || _cents(net[name]!) != 0)
          {
            'name': name,
            'charges': _cents(gross[name] ?? 0),
            'net': _cents(net[name]!),
          },
    ],
  };
}

String? _date(Object? value) => switch (value) {
  final num seconds => _ymd(
    DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true),
  ),
  final String text when text.length >= 10 => text.substring(0, 10),
  _ => null,
};

Future<Map<String, Object?>> awsBilling(AwsCall call, DateTime now) async {
  final today = DateTime.utc(
    now.toUtc().year,
    now.toUtc().month,
    now.toUtc().day,
  );
  final notes = <Map<String, Object?>>[];
  Future<T?> optional<T>(String block, Future<T> Function() work) async {
    try {
      return await work();
    } on Exception catch (error) {
      notes.add({
        'block': block,
        'error': error is AwsCostException ? error.message : 'Did not answer',
      });
      return null;
    }
  }

  final costs = await _pages(call, AwsOperation.costAndUsage, {
    'TimePeriod': {
      'Start': _ymd(DateTime.utc(today.year, today.month - 1)),
      'End': _ymd(today.add(const Duration(days: 1))),
    },
    'Granularity': 'DAILY',
    'Metrics': ['UnblendedCost'],
    'GroupBy': [
      {'Type': 'DIMENSION', 'Key': 'SERVICE'},
      {'Type': 'DIMENSION', 'Key': 'RECORD_TYPE'},
    ],
  }, 'NextPageToken');
  final monthEnd = DateTime.utc(today.year, today.month + 1);
  final forecast = optional('FORECAST', () async {
    final answer = await call(AwsOperation.costForecast, {
      'TimePeriod': {'Start': _ymd(today), 'End': _ymd(monthEnd)},
      'Metric': 'UNBLENDED_COST',
      'Granularity': 'MONTHLY',
    });
    return _cents(_amount(_map(answer['Total'])['Amount']));
  });
  final plan = optional('FREE PLAN', () async {
    final answer = await call(AwsOperation.accountPlanState, const {});
    if (answer['accountPlanType'] != 'FREE') return null;
    final credits = _map(answer['accountPlanRemainingCredits']);
    return <String, Object?>{
      'type': '${answer['accountPlanType'] ?? ''}',
      'status': '${answer['accountPlanStatus'] ?? ''}',
      'remaining': _cents(_amount(credits['amount'])),
      'currency': '${credits['unit'] ?? 'USD'}',
      'expires': ?_date(answer['accountPlanExpirationDate']),
    };
  });
  final freeTier = optional('FREE TIER', () async {
    final usages = [
      for (final page in await _pages(
        call,
        AwsOperation.freeTierUsage,
        const {},
        'nextToken',
        limit: 10,
      ))
        for (final usage in _list(page['freeTierUsages']))
          if (_map(usage).isNotEmpty) _map(usage),
    ];
    double share(Map<String, Object?> usage) {
      final limit = _amount(usage['limit']);
      return limit > 0 ? _amount(usage['actualUsageAmount']) / limit : 0;
    }

    usages.sort((a, b) => share(b).compareTo(share(a)));
    return [
      for (final usage in usages.take(12))
        {
          'service': '${usage['service'] ?? ''}',
          'description': '${usage['description'] ?? ''}',
          'type': '${usage['freeTierType'] ?? ''}',
          'unit': '${usage['unit'] ?? ''}',
          'used': _amount(usage['actualUsageAmount']),
          'forecast': _amount(usage['forecastedUsageAmount']),
          'limit': _amount(usage['limit']),
        },
    ];
  });
  final budgets = optional('BUDGETS', () async {
    final account = (await call(
      AwsOperation.callerIdentity,
      const {},
    ))['Account'];
    if (account is! String || !RegExp(r'^\d{12}$').hasMatch(account)) {
      throw const AwsCostException('AWS named no account id');
    }
    final rows = [
      for (final page in await _pages(
        call,
        AwsOperation.describeBudgets,
        {'AccountId': account},
        'NextToken',
        limit: 10,
      ))
        for (final budget in _list(page['Budgets']))
          {
            'name': '${_map(budget)['BudgetName'] ?? ''}',
            'period': '${_map(budget)['TimeUnit'] ?? ''}',
            'unit': '${_map(_map(budget)['BudgetLimit'])['Unit'] ?? ''}',
            'limit': _cents(
              _amount(_map(_map(budget)['BudgetLimit'])['Amount']),
            ),
            'actual': _cents(
              _amount(
                _map(
                  _map(_map(budget)['CalculatedSpend'])['ActualSpend'],
                )['Amount'],
              ),
            ),
            'forecast': _cents(
              _amount(
                _map(
                  _map(_map(budget)['CalculatedSpend'])['ForecastedSpend'],
                )['Amount'],
              ),
            ),
          },
    ];
    return rows.take(12).toList();
  });
  final (spent, credit, tier, limits) = await (
    forecast,
    plan,
    freeTier,
    budgets,
  ).wait;
  return {
    ...awsCostFold(today, costs),
    'forecast': ?spent,
    'forecastEnd': _ymd(monthEnd.subtract(const Duration(days: 1))),
    'plan': ?credit,
    'freeTier': tier ?? const [],
    'budgets': limits ?? const [],
    'notes': notes,
    'fetched': now
        .toLocal()
        .toIso8601String()
        .substring(0, 16)
        .replaceFirst('T', ' '),
  };
}
