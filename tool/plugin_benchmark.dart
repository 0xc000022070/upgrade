import 'dart:convert';
import 'dart:io';

import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:upgrade_luau/data_api.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'upgrade-record-benchmark-',
  );
  final worker = LuauWorker(dataDirectory: directory.path);
  const source = '''
return { trim = function()
  local item = upgrade.data.get('selected')
  upgrade.data.propose('selected', item.key, string.gsub(item.value, "[ \\t]+", " "), item.revision)
end }
''';
  final samples = <int>[];
  LuauResult? cold;
  LuauResult? warm;
  var coldRoundtrip = 0;
  try {
    for (var i = 0; i < 101; i++) {
      final watch = Stopwatch()..start();
      final result = await worker.invoke(
        key: 'benchmark:3',
        source: source,
        action: 'trim',
        data: DataContext(DataOwner('benchmark', 'bundled:test'), {
          'selected': DataGrant(null, {
            DataOperation.get,
            DataOperation.propose,
          }),
        }, selection: const DataRecord('test', 'test   a   small   record', 1)),
      );
      watch.stop();
      if (i == 0) {
        cold = result;
        coldRoundtrip = watch.elapsedMicroseconds;
      } else {
        warm = result;
        samples.add(watch.elapsedMicroseconds);
      }
    }
    samples.sort();
    // ignore: avoid_print -- Android routes print, not stdout, to logcat.
    print(
      jsonEncode({
        'cold_roundtrip_us': coldRoundtrip,
        'cold_compile_load_us': cold!.loadMicros,
        'warm_roundtrip_median_us': samples[samples.length ~/ 2],
        'warm_roundtrip_p95_us': samples[(samples.length * 0.95).floor()],
        'warm_native_run_us': warm!.runMicros,
        'vm_bytes': warm.memoryBytes,
        'vm_peak_bytes': warm.peakBytes,
        'iterations': samples.length,
      }),
    );
  } finally {
    await worker.close();
    await directory.delete(recursive: true);
  }
}
