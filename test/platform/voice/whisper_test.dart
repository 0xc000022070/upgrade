import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/voice/whisper.dart';

void _silent(SendPort ready) {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  requests.listen((_) {});
}

void main() {
  test(
    'a worker killed mid-chunk fails the chunk instead of hanging',
    () async {
      final ready = ReceivePort();
      final isolate = await Isolate.spawn(_silent, ready.sendPort);
      final worker = await ready.first as SendPort;

      final heard = hear(isolate, worker, Float32List(16), '');
      isolate.kill(priority: Isolate.immediate);

      await expectLater(
        heard.timeout(const Duration(seconds: 5)),
        throwsA(isA<TranscriptionFailed>()),
      );
    },
  );
}
