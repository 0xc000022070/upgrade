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

  test('each model is fetched from its own pinned repository', () {
    for (final size in WhisperSize.values) {
      expect(size.files, hasLength(3));
      for (final file in size.files) {
        expect(file.name, startsWith('${size.name}-'));
        expect(
          size.url(file).path,
          '/csukuangfj/sherpa-onnx-whisper-${size.name}/resolve/'
          '${size.revision}/${file.name}',
        );
      }
    }
  });

  test('pcm reads as little-endian samples, and room noise as nothing', () {
    final pcm = ByteData(4)
      ..setInt16(0, 16384, Endian.little)
      ..setInt16(2, -32768, Endian.little);
    expect(pcmSamples(pcm.buffer.asUint8List()), [0.5, -1.0]);
    expect(
      heardAnything(Float32List(16000)..fillRange(0, 16000, 0.001)),
      isFalse,
    );
    expect(
      heardAnything(Float32List(16000)..fillRange(8000, 9600, 0.2)),
      isTrue,
    );
  });

  test(
    'a long take is cut at its quiet spot into pieces whisper hears whole',
    () {
      const rate = whisperRate;
      final samples = Float32List(65 * rate)..fillRange(0, 65 * rate, 0.2);
      samples.fillRange(23 * rate, 23 * rate + rate ~/ 5, 0);
      final chunks = whisperChunks(samples);
      expect(
        chunks.map((c) => c.length).fold(0, (a, b) => a + b),
        samples.length,
      );
      expect(chunks.every((c) => c.length <= 28 * rate), isTrue);
      expect(
        chunks.first.length,
        inInclusiveRange(23 * rate, 23 * rate + rate ~/ 5),
      );
      expect(whisperChunks(Float32List(rate)), hasLength(1));
    },
  );

  test('whisper notes about the audio are not words', () {
    expect(spokenText(' [BLANK_AUDIO] '), isEmpty);
    expect(spokenText('fix  the [MUSIC] parser'), 'fix the parser');
  });
}
