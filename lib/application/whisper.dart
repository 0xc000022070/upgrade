import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/whisper.dart';

sealed class WhisperState {
  const WhisperState();
}

final class WhisperOff extends WhisperState {
  const WhisperOff({this.fault});

  final ModelFault? fault;
}

final class WhisperFetching extends WhisperState {
  const WhisperFetching(this.progress);

  final double progress;
}

final class WhisperReady extends WhisperState {
  const WhisperReady();
}

final whisperStoreProvider = FutureProvider<ModelStore>((ref) async {
  final support = await getApplicationSupportDirectory();
  return ModelStore(
    directory: Directory(p.join(support.path, 'models', 'whisper-base')),
  );
});

class WhisperModel extends Notifier<WhisperState> {
  ModelStore? _store;
  WhisperTranscriber? _transcriber;
  Future<void>? _run;
  late Future<void> _settled;
  var _gone = false;

  @override
  WhisperState build() {
    ref.onDispose(() {
      _gone = true;
      _store?.cancel();
      _transcriber?.close();
    });
    _settled = _settle();
    return const WhisperOff();
  }

  Transcriber? get transcriber {
    final store = _store;
    if (state is! WhisperReady || store == null) return null;
    return _transcriber ??= WhisperTranscriber(store);
  }

  Future<ModelStore?> _ready() async {
    try {
      return _store ??= await ref.read(whisperStoreProvider.future);
    } on Object {
      // ignored: no store dir means no model, which callers show as off.
      return null;
    }
  }

  Future<void> _settle() async {
    final store = await _ready();
    if (store == null) return;
    if (await store.ready()) {
      if (!_gone && state is WhisperOff) state = const WhisperReady();
    } else {
      await store.delete();
    }
  }

  Future<void> enable() async {
    if (state is! WhisperOff) return;
    state = const WhisperFetching(0);
    await _settled;
    await _run;
    if (_gone || state is! WhisperFetching) return;
    final store = await _ready();
    if (store == null) {
      state = const WhisperOff(fault: ModelFault.failed);
      return;
    }
    final run = _fetch(store);
    _run = run;
    await run;
  }

  Future<void> _fetch(ModelStore store) async {
    var shown = 0;
    try {
      await store.fetch((progress) {
        final percent = (progress * 100).floor();
        if (percent == shown || _gone || state is! WhisperFetching) return;
        shown = percent;
        state = WhisperFetching(progress);
      });
      if (!_gone && state is WhisperFetching) state = const WhisperReady();
    } on ModelFetchException catch (error) {
      if (_gone || error.fault == ModelFault.cancelled) return;
      if (state is WhisperFetching) state = WhisperOff(fault: error.fault);
    }
  }

  Future<void> disable() async {
    state = const WhisperOff();
    _transcriber?.close();
    _transcriber = null;
    final store = await _ready();
    store?.cancel();
    await _run;
    if (state is WhisperOff) await store?.delete();
  }
}

final whisperModelProvider = NotifierProvider<WhisperModel, WhisperState>(
  WhisperModel.new,
);
