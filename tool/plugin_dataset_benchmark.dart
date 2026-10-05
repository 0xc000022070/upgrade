import 'dart:convert';
import 'dart:io';

import 'package:upgrade_luau/data_api.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

Future<void> main() async {
  final directory = Directory.systemTemp.createTempSync(
    'upgrade-data-benchmark-',
  );
  final worker = LuauWorker(dataDirectory: directory.path);
  final owner = DataOwner('benchmark.records', 'bundled:benchmark');
  final dataset = DataSet(owner: owner, name: 'records', schemaVersion: 1);
  final context = DataContext(owner, {
    'local': DataGrant(dataset, {
      DataOperation.get,
      DataOperation.put,
      DataOperation.query,
    }),
  });
  const source = '''
return {run = function()
  local record = upgrade.data.get("local", "counter")
  local count = record and tonumber(record.value) or 0
  local revision = record and record.revision or 0
  upgrade.data.put("local", "counter", tostring(count + 1), revision)
  assert(#upgrade.data.query("local", "", 1) == 1)
end}
''';
  final roundtrips = <int>[];
  final hostTimes = <int>[];
  var coldRoundtrip = 0;
  LuauResult? cold;
  LuauResult? warm;
  try {
    for (var i = 0; i < 101; i++) {
      final watch = Stopwatch()..start();
      final result = await worker.invoke(
        key: 'dataset-benchmark',
        source: source,
        action: 'run',
        data: context,
      );
      if (i == 0) {
        cold = result;
        coldRoundtrip = watch.elapsedMicroseconds;
      } else {
        warm = result;
        roundtrips.add(watch.elapsedMicroseconds);
        hostTimes.add(result.dataWaitMicros);
      }
    }
    roundtrips.sort();
    hostTimes.sort();
    final report = await worker.inspectData(owner: owner);
    // ignore: avoid_print -- Android routes print to logcat.
    print(
      jsonEncode({
        'benchmark': 'dataset-get-put-query',
        'cold_roundtrip_us': coldRoundtrip,
        'cold_compile_load_us': cold!.loadMicros,
        'warm_roundtrip_median_us': roundtrips[50],
        'warm_roundtrip_p95_us': roundtrips[95],
        'warm_host_median_us': hostTimes[50],
        'warm_host_p95_us': hostTimes[95],
        'warm_native_run_us': warm!.runMicros,
        'vm_bytes': warm.memoryBytes,
        'vm_peak_bytes': warm.peakBytes,
        'dataset_calls': report.usage.single.calls,
        'dataset_records': report.inventory.single.records,
        'dataset_logical_bytes': report.inventory.single.logicalBytes,
        'dataset_file_bytes': report.inventory.single.fileBytes,
        'iterations': roundtrips.length,
      }),
    );
  } finally {
    await worker.close();
    directory.deleteSync(recursive: true);
  }
}
