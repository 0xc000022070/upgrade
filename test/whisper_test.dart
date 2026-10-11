import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:upgrade/application/whisper.dart';
import 'package:upgrade/features/settings/voice_block.dart';
import 'package:upgrade/platform/whisper.dart';

final _encoder = Uint8List.fromList(List.generate(70000, (i) => i % 251));
final _decoder = Uint8List.fromList(List.generate(9000, (i) => i % 13));
final _tokens = Uint8List.fromList('a 0\nb 1\n'.codeUnits);

ModelFile _file(String name, Uint8List bytes) =>
    (name: name, bytes: bytes.length, sha256: sha256.convert(bytes).toString());

void main() {
  late HttpServer server;
  late Directory scratch;
  late Map<String, Uint8List> served;
  late List<String> asked;

  setUp(() async {
    // The test binding answers every request 400; these talk to a server of their own.
    HttpOverrides.global = null;
    scratch = await Directory.systemTemp.createTemp('whisper');
    served = {
      'encoder.onnx': _encoder,
      'decoder.onnx': _decoder,
      'tokens.txt': _tokens,
    };
    asked = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      asked.add(name);
      final body = served[name];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(body);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await scratch.delete(recursive: true);
  });

  ModelStore store({List<ModelFile>? files, String name = 'whisper'}) =>
      ModelStore(
        directory: Directory(p.join(scratch.path, 'models', name)),
        files:
            files ??
            [
              _file('encoder.onnx', _encoder),
              _file('decoder.onnx', _decoder),
              _file('tokens.txt', _tokens),
            ],
        url: (file) => Uri.http('127.0.0.1:${server.port}', '/m/${file.name}'),
      );

  test('a fetch keeps every file and says how far it got', () async {
    final model = store();
    expect(await model.ready(), isFalse);
    final progress = <double>[];
    await model.fetch(progress.add);
    expect(await model.ready(), isTrue);
    expect(progress.last, 1);
    expect(progress, orderedEquals([...progress]..sort()));
    expect(await File(model.path(model.files.first)).readAsBytes(), _encoder);
  });

  test('a file already whole is not fetched again', () async {
    final model = store();
    await model.fetch((_) {});
    asked.clear();
    await model.fetch((_) {});
    expect(asked, isEmpty);
  });

  test('a digest that differs leaves nothing behind', () async {
    final model = store(
      files: [
        _file('encoder.onnx', _encoder),
        _file('decoder.onnx', _decoder),
        (name: 'tokens.txt', bytes: _tokens.length, sha256: '0' * 64),
      ],
    );
    await expectLater(
      model.fetch((_) {}),
      throwsA(
        isA<ModelFetchException>().having(
          (e) => e.fault,
          'fault',
          ModelFault.corrupt,
        ),
      ),
    );
    expect(await model.directory.exists(), isFalse);
  });

  test('a file the server does not have fails the fetch', () async {
    served.remove('tokens.txt');
    final model = store();
    await expectLater(
      model.fetch((_) {}),
      throwsA(
        isA<ModelFetchException>().having(
          (e) => e.fault,
          'fault',
          ModelFault.failed,
        ),
      ),
    );
    expect(await model.directory.exists(), isFalse);
  });

  group('the toggle', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          whisperStoreProvider.overrideWith(
            (ref, size) async => store(name: size.name),
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('is off until the model is fetched, and off deletes it', () async {
      final model = container.read(
        whisperModelProvider(WhisperSize.base).notifier,
      );
      final base = whisperModelProvider(WhisperSize.base);
      expect(container.read(base), isA<WhisperOff>());
      expect(model.transcriber, isNull);
      await model.enable();
      expect(container.read(base), isA<WhisperReady>());
      expect(model.transcriber, isNotNull);
      await model.disable();
      expect(container.read(base), isA<WhisperOff>());
      expect(model.transcriber, isNull);
      expect(await store(name: 'base').ready(), isFalse);
    });

    test('reads on at launch when the files are already there', () async {
      await store(name: 'small').fetch((_) {});
      final small = whisperModelProvider(WhisperSize.small);
      container.read(small);
      for (var i = 0; i < 200 && container.read(small) is! WhisperReady; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(container.read(small), isA<WhisperReady>());
      expect(
        container.read(whisperModelProvider(WhisperSize.base)),
        isA<WhisperOff>(),
      );
    });

    test('a failed fetch turns it off and says why', () async {
      served.remove('encoder.onnx');
      final base = whisperModelProvider(WhisperSize.base);
      await container.read(base.notifier).enable();
      final state = container.read(base);
      expect(state, isA<WhisperOff>());
      expect(
        whisperSubtitle(WhisperSize.base, state, hearing: false),
        'DOWNLOAD FAILED',
      );
    });

    test(
      'small hears while it is on the phone, and base keeps or goes',
      () async {
        final base = whisperModelProvider(WhisperSize.base);
        final small = whisperModelProvider(WhisperSize.small);
        WhisperSize? hearing() => whisperHearing(
          (size) => container.read(whisperModelProvider(size)),
        );
        final pick = container.read(whisperProvider);
        expect(pick(), isNull);
        await container.read(base.notifier).enable();
        expect(hearing(), WhisperSize.base);
        expect(pick(), same(container.read(base.notifier).transcriber));
        await container.read(small.notifier).enable();
        expect(hearing(), WhisperSize.small);
        expect(pick(), same(container.read(small.notifier).transcriber));
        await container.read(base.notifier).disable();
        expect(hearing(), WhisperSize.small);
        await container.read(small.notifier).disable();
        expect(pick(), isNull);
      },
    );
  });

  test('each row says what its toggle costs and where it stands', () {
    String row(WhisperSize size, WhisperState state, {bool hearing = false}) =>
        whisperSubtitle(size, state, hearing: hearing);
    expect(
      row(WhisperSize.base, const WhisperOff()),
      '161 MB DOWNLOAD · STAYS ON THE PHONE',
    );
    expect(
      row(WhisperSize.small, const WhisperOff()),
      '375 MB DOWNLOAD · SHARPER, SLOWER',
    );
    expect(
      row(WhisperSize.base, const WhisperOff(fault: ModelFault.corrupt)),
      'MODEL CORRUPT',
    );
    expect(
      row(WhisperSize.small, const WhisperFetching(0.426)),
      'DOWNLOADING 42%',
    );
    expect(
      row(WhisperSize.base, const WhisperReady(), hearing: true),
      'IN USE · 161 MB',
    );
    expect(row(WhisperSize.base, const WhisperReady()), 'INSTALLED · 161 MB');
  });

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
