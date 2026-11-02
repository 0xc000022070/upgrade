import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 2 && args.length != 4) _usage();
  final report = File(args[0]);
  final out = File(args[1]);
  double? budget;
  if (args.length == 4) {
    if (args[2] != '--budget') _usage();
    budget = double.tryParse(args[3]) ?? _usage();
  }

  final suites = <int, String>{};
  final starts = <int, (int, String, int)>{};
  final times = <String, int>{};
  for (final line in report.readAsLinesSync()) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    switch (decoded['type']) {
      case 'suite':
        final suite = decoded['suite'] as Map<String, Object?>;
        suites[suite['id'] as int] = suite['path'] as String;
      case 'testStart':
        final test = decoded['test'] as Map<String, Object?>;
        starts[test['id'] as int] = (
          test['suiteID'] as int,
          test['name'] as String,
          decoded['time'] as int,
        );
      case 'testDone':
        final start = starts[decoded['testID'] as int];
        if (start == null) continue;
        final (suiteId, name, began) = start;
        if (name.startsWith('loading ')) continue;
        final path = suites[suiteId];
        if (path == null) continue;
        final file = path.contains('/test/shards/')
            ? '${name.split(' ').first}.dart'
            : path.substring(path.lastIndexOf('/test/') + '/test/'.length);
        times[file] = (times[file] ?? 0) + (decoded['time'] as int) - began;
    }
  }

  final ranked = times.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    ranked.map((entry) => '${entry.key}\t${entry.value}\n').join(),
  );

  if (budget == null) return;
  final over = ranked.where((entry) => entry.value > budget! * 1000).toList();
  for (final entry in over) {
    stderr.writeln(
      'test budget: ${entry.key} ran ${_seconds(entry.value)}s, '
      'over the ${budget}s a file may take; drop what does not earn its time, '
      'then split the rest along its groups',
    );
  }
  if (over.isNotEmpty) exit(1);
}

String _seconds(int ms) => (ms / 1000).toStringAsFixed(1);

Never _usage() {
  stderr.writeln(
    'usage: dart tool/test_times.dart <report.json> <times.tsv> '
    '[--budget <seconds>]',
  );
  exit(2);
}
