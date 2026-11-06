import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

typedef ModelFile = ({String name, int bytes, String sha256});

const whisperRate = 16000;

const _tokensDigest =
    'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126';

/// Listed from the least to the most capable: the last one on the phone hears.
enum WhisperSize {
  base(
    revision: 'bb53ee204431c90d314c1cc08d28d23e5b7927cc',
    files: [
      (
        name: 'base-encoder.int8.onnx',
        bytes: 29120534,
        sha256:
            '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
      ),
      (
        name: 'base-decoder.int8.onnx',
        bytes: 130672026,
        sha256:
            '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
      ),
      (name: 'base-tokens.txt', bytes: 816730, sha256: _tokensDigest),
    ],
  ),
  small(
    revision: '8f3c18b358db4d1f2fc1eae49d75cd20989e4309',
    files: [
      (
        name: 'small-encoder.int8.onnx',
        bytes: 112442483,
        sha256:
            '4cbe7b22fa9026b843b60a68640c747de05bafb1a11b57edc0e66c232d9f33a9',
      ),
      (
        name: 'small-decoder.int8.onnx',
        bytes: 262226114,
        sha256:
            'acad50b5c782696e91b55914cc5ab4f756f1532f76e22aa6fc615f39fb69a8ee',
      ),
      (name: 'small-tokens.txt', bytes: 816730, sha256: _tokensDigest),
    ],
  );

  const WhisperSize({required this.revision, required this.files});

  final String revision;
  final List<ModelFile> files;

  Uri url(ModelFile file) => Uri.https(
    'huggingface.co',
    '/csukuangfj/sherpa-onnx-whisper-$name/resolve/$revision/${file.name}',
  );
}

int modelBytes(List<ModelFile> files) =>
    files.fold(0, (sum, file) => sum + file.bytes);

enum ModelFault { failed, corrupt, cancelled }

class ModelFetchException implements Exception {
  const ModelFetchException(this.fault);

  final ModelFault fault;

  @override
  String toString() => 'ModelFetchException(${fault.name})';
}

const _fetchWait = Duration(seconds: 20);

class ModelStore {
  ModelStore({
    required this.directory,
    required this.files,
    required this.url,
    HttpClient Function()? httpClient,
  }) : _httpClient = httpClient ?? HttpClient.new;

  final Directory directory;
  final List<ModelFile> files;
  final Uri Function(ModelFile file) url;
  final HttpClient Function() _httpClient;

  HttpClient? _client;
  var _cancelled = false;

  String path(ModelFile file) => p.join(directory.path, file.name);

  Future<bool> ready() async {
    for (final file in files) {
      final target = File(path(file));
      if (!await target.exists() || await target.length() != file.bytes) {
        return false;
      }
    }
    return true;
  }

  Future<void> fetch(void Function(double progress) onProgress) async {
    final client = _httpClient()..connectionTimeout = _fetchWait;
    _client = client;
    _cancelled = false;
    final total = modelBytes(files);
    var done = 0;
    try {
      await directory.create(recursive: true);
      for (final file in files) {
        final target = File(path(file));
        if (await target.exists() && await target.length() == file.bytes) {
          done += file.bytes;
          onProgress(done / total);
          continue;
        }
        final base = done;
        await _fetchOne(client, file, target, (got) {
          onProgress((base + got) / total);
        });
        done += file.bytes;
      }
    } on ModelFetchException catch (error) {
      await delete();
      throw ModelFetchException(
        _cancelled ? ModelFault.cancelled : error.fault,
      );
    } on Object {
      await delete();
      throw ModelFetchException(
        _cancelled ? ModelFault.cancelled : ModelFault.failed,
      );
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<void> _fetchOne(
    HttpClient client,
    ModelFile file,
    File target,
    void Function(int got) onBytes,
  ) async {
    final request = await client.getUrl(url(file)).timeout(_fetchWait);
    final response = await request.close().timeout(_fetchWait);
    if (response.statusCode != HttpStatus.ok) {
      throw const ModelFetchException(ModelFault.failed);
    }
    final part = File('${target.path}.part');
    final sink = part.openWrite();
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    var got = 0;
    try {
      await for (final chunk in response.timeout(_fetchWait)) {
        if (_cancelled) throw const ModelFetchException(ModelFault.cancelled);
        got += chunk.length;
        if (got > file.bytes) {
          throw const ModelFetchException(ModelFault.corrupt);
        }
        hashing.add(chunk);
        sink.add(chunk);
        onBytes(got);
      }
    } finally {
      await sink.close();
    }
    hashing.close();
    if (got != file.bytes || digest.value.toString() != file.sha256) {
      throw const ModelFetchException(ModelFault.corrupt);
    }
    await part.rename(target.path);
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<void> delete() async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // ignored: already gone, which is what was asked.
      return;
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Float32List pcmSamples(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
  }
  return samples;
}

// About -45 dBFS over a tenth of a second: above a quiet room, below a voice.
const _heardRms = 0.0056;

bool heardAnything(Float32List samples) {
  const window = whisperRate ~/ 10;
  for (var start = 0; start < samples.length; start += window) {
    final end = math.min(start + window, samples.length);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += samples[i] * samples[i];
    }
    if (math.sqrt(sum / (end - start)) >= _heardRms) return true;
  }
  return false;
}

const _chunkMost = 28 * whisperRate;
const _chunkLeast = 20 * whisperRate;

// Whisper hears thirty seconds and drops the rest, so a long take is cut at its
// quietest tenth of a second between twenty and twenty-eight.
List<Float32List> whisperChunks(Float32List samples) {
  const window = whisperRate ~/ 10;
  final chunks = <Float32List>[];
  var start = 0;
  while (samples.length - start > _chunkMost) {
    var cut = start + _chunkMost;
    var quietest = double.infinity;
    for (
      var at = start + _chunkLeast;
      at + window <= start + _chunkMost;
      at += window
    ) {
      var sum = 0.0;
      for (var i = at; i < at + window; i++) {
        sum += samples[i] * samples[i];
      }
      if (sum < quietest) {
        quietest = sum;
        cut = at + window ~/ 2;
      }
    }
    chunks.add(Float32List.sublistView(samples, start, cut));
    start = cut;
  }
  chunks.add(Float32List.sublistView(samples, start));
  return chunks;
}

final _bracketed = RegExp(r'\[[^\]]*\]');
final _spaces = RegExp(r'\s+');

String spokenText(String text) =>
    text.replaceAll(_bracketed, ' ').replaceAll(_spaces, ' ').trim();

abstract interface class Transcriber {
  void warm();

  Future<String> transcribe(Float32List samples);
}

class TranscriptionFailed implements Exception {
  const TranscriptionFailed(this.reason);

  final String reason;

  @override
  String toString() => 'TranscriptionFailed($reason)';
}

typedef _WhisperPaths = ({String encoder, String decoder, String tokens});

class WhisperTranscriber implements Transcriber {
  WhisperTranscriber(ModelStore store, {this.language})
    : _paths = (
        encoder: store.path(store.files[0]),
        decoder: store.path(store.files[1]),
        tokens: store.path(store.files[2]),
      );

  final Future<String> Function()? language;
  final _WhisperPaths _paths;
  Future<(Isolate, SendPort)>? _worker;
  Isolate? _isolate;

  @override
  void warm() => unawaited(_spawn().then<void>((_) {}, onError: (_) {}));

  Future<(Isolate, SendPort)> _spawn() => _worker ??= _start();

  Future<(Isolate, SendPort)> _start() async {
    final ready = ReceivePort();
    try {
      final isolate = _isolate = await Isolate.spawn(_serve, (
        ready.sendPort,
        _paths,
      ));
      final answer = await ready.first;
      if (answer is SendPort) return (isolate, answer);
      throw TranscriptionFailed('$answer');
    } on Object {
      close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  @override
  Future<String> transcribe(Float32List samples) async {
    final (isolate, worker) = await _spawn();
    final language = await this.language?.call() ?? '';
    final heard = <String>[];
    for (final chunk in whisperChunks(samples)) {
      if (!heardAnything(chunk)) continue;
      if (!identical(_isolate, isolate)) {
        throw const TranscriptionFailed('closed');
      }
      heard.add(await hear(isolate, worker, chunk, language));
    }
    return heard.join(' ');
  }

  void close() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _worker = null;
  }
}

@visibleForTesting
Future<String> hear(
  Isolate isolate,
  SendPort worker,
  Float32List samples,
  String language,
) async {
  final reply = ReceivePort();
  try {
    isolate.addOnExitListener(reply.sendPort, response: 'closed');
    worker.send((
      reply.sendPort,
      language,
      TransferableTypedData.fromList([samples]),
    ));
    final answer = await reply.first;
    if (answer is String) throw TranscriptionFailed(answer);
    final (text, error) = answer as (String?, String?);
    if (text == null) throw TranscriptionFailed(error ?? 'no answer');
    return text;
  } finally {
    isolate.removeOnExitListener(reply.sendPort);
    reply.close();
  }
}

void _serve((SendPort, _WhisperPaths) start) {
  final (ready, paths) = start;
  sherpa.OfflineRecognizerConfig configFor(String language) =>
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            language: language,
            task: 'transcribe',
          ),
          tokens: paths.tokens,
          numThreads: math.min(4, Platform.numberOfProcessors),
          debug: false,
        ),
      );
  final sherpa.OfflineRecognizer recognizer;
  var current = '';
  try {
    sherpa.initBindings();
    recognizer = sherpa.OfflineRecognizer(configFor(current));
  } on Object catch (error) {
    ready.send('$error');
    return;
  }
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  requests.listen((message) {
    final (reply, language, audio) =
        message as (SendPort, String, TransferableTypedData);
    sherpa.OfflineStream? stream;
    try {
      if (language != current) {
        recognizer.setConfig(configFor(language));
        current = language;
      }
      stream = recognizer.createStream();
      stream.acceptWaveform(
        samples: audio.materialize().asFloat32List(),
        sampleRate: whisperRate,
      );
      recognizer.decode(stream);
      reply.send((recognizer.getResult(stream).text, null));
    } on Object catch (error) {
      reply.send((null, '$error'));
    } finally {
      stream?.free();
    }
  });
}
