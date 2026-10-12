import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'data_api.dart';
import 'src/dataset_store.dart';
import 'src/native_data.dart';
import 'src/value_codec.dart';

const _asset = 'package:upgrade_luau/upgrade_luau.dart';

@Native<Pointer<Void> Function(Pointer<Utf8>, Size)>(
  assetId: _asset,
  symbol: 'upgrade_vm_load',
)
external Pointer<Void> _load(Pointer<Utf8> source, int size);
@Native<Int32 Function(Pointer<Void>, Pointer<Utf8>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_invoke',
)
external int _invoke(Pointer<Void> vm, Pointer<Utf8> action);
@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Size)>(
  assetId: _asset,
  symbol: 'upgrade_vm_input',
)
external int _input(Pointer<Void> vm, Pointer<Uint8> bytes, int size);
@Native<Pointer<Uint8> Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_output',
)
external Pointer<Uint8> _output(Pointer<Void> vm);
@Native<Size Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_output_size',
)
external int _outputSize(Pointer<Void> vm);
@Native<Pointer<Utf8> Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_error',
)
external Pointer<Utf8> _error(Pointer<Void> vm);
@Native<Size Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_memory',
)
external int _memory(Pointer<Void> vm);
@Native<Size Function(Pointer<Void>)>(assetId: _asset, symbol: 'upgrade_vm_peak')
external int _peak(Pointer<Void> vm);
@Native<Int64 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_load_us',
)
external int _loadUs(Pointer<Void> vm);
@Native<Int64 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_run_us',
)
external int _runUs(Pointer<Void> vm);
@Native<Void Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_destroy',
)
external void _destroy(Pointer<Void> vm);

class LuauException implements Exception {
  const LuauException(this.message, {this.metrics});
  final String message;
  final LuauResult? metrics;
  @override
  String toString() => message;
}

class LuauResult {
  const LuauResult({
    required this.loadMicros,
    required this.runMicros,
    required this.memoryBytes,
    required this.peakBytes,
    required this.cold,
    this.dataProposal,
    this.dataUsage = const [],
    this.dataCalls = 0,
    this.dataWaitMicros = 0,
    this.value,
    this.responseBytes = 0,
  });
  final int loadMicros;
  final int runMicros;
  final int memoryBytes;
  final int peakBytes;
  final bool cold;
  final DataRecord? dataProposal;
  final List<DataUsage> dataUsage;
  final int dataCalls;
  final int dataWaitMicros;
  final Object? value;
  final int responseBytes;
}

class LuauWorker {
  LuauWorker({
    this.dataDirectory,
    this.dataTimeBudget = DatasetStore.defaultTimeBudget,
  });
  final String? dataDirectory;
  final Duration dataTimeBudget;
  static const maxPending = 8;
  static const maxResident = 2;
  Future<void> _tail = Future.value();
  Completer<void>? _exited;
  SendPort? _port;
  SendPort? _activeReply;
  final _cached = <String>{};
  int _pending = 0;
  bool _closed = false;
  Timer? _idle;
  int _generation = 0;
  final _ownerGenerations = <String, int>{};

  Future<LuauResult> invoke({
    required String key,
    required String source,
    required String action,
    DataContext? data,
    String? ownerIdentity,
    Object? input,
  }) {
    final Uint8List? encoded;
    try {
      encoded = input == null ? null : encodeValue(input);
    } on FormatException catch (error) {
      return Future.error(LuauException(error.message));
    }
    final owner = data?.owner.identity ?? ownerIdentity ?? key;
    final cacheKey = '$owner:$key:${data?.permissionKey ?? ""}';
    final generation = _generation;
    final ownerGeneration = _ownerGenerations[owner] ?? 0;
    bool active() =>
        generation == _generation &&
        ownerGeneration == (_ownerGenerations[owner] ?? 0);
    if (data != null && dataDirectory == null) {
      return Future.error(
        const LuauException('Dataset storage is unavailable'),
      );
    }
    if (_closed) {
      return Future.error(const LuauException('Plugin worker is closed'));
    }
    if (_pending >= maxPending) {
      return Future.error(const LuauException('Plugin queue is full'));
    }
    if ((!_cached.contains(cacheKey) &&
            utf8.encode(source).length > 64 * 1024) ||
        action.length > 100 ||
        action.contains('\x00')) {
      return Future.error(
        const LuauException('Plugin input exceeds its limits'),
      );
    }
    _idle?.cancel();
    _pending++;
    // Cache bookkeeping and requests use the same order, including after errors.
    final result = _tail
        .then((_) async {
          if (_closed) throw const LuauException('Plugin worker is closed');
          if (!active()) throw const LuauException('Plugin activation ended');
          await _start();
          if (_closed || !active()) {
            throw const LuauException('Plugin activation ended');
          }
          final reply = ReceivePort();
          try {
            if (_exited!.isCompleted) {
              throw const LuauException('Plugin worker stopped');
            }
            _activeReply = reply.sendPort;
            _port!.send(
              _Request(
                reply.sendPort,
                cacheKey,
                _cached.contains(cacheKey) ? null : source,
                action,
                data,
                owner,
                encoded,
              ),
            );
            final response = await reply.first as _Response;
            _cached
              ..clear()
              ..addAll(response.cached);
            if (!active()) {
              throw LuauException(
                'Plugin activation ended',
                metrics: response.result,
              );
            }
            if (response.error != null) {
              throw LuauException(response.error!, metrics: response.result);
            }
            return response.result!;
          } finally {
            _activeReply = null;
            reply.close();
          }
        })
        .whenComplete(() {
          _pending--;
          if (_pending == 0 && !_closed) {
            _idle = Timer(const Duration(seconds: 30), () => release());
          }
        });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _start() async {
    if (_port != null && !_exited!.isCompleted) return;
    _port = null;
    _cached.clear();
    final ready = ReceivePort();
    final exits = ReceivePort();
    final exited = _exited = Completer<void>();
    exits.listen((_) {
      if (!exited.isCompleted) exited.complete();
      if (identical(_exited, exited)) {
        _activeReply?.send(const _Response(null, 'Plugin worker stopped', []));
      }
      exits.close();
    });
    try {
      await Isolate.spawn(
        _serve,
        _Start(ready.sendPort, dataDirectory, dataTimeBudget),
        debugName: 'upgrade.plugins',
        onError: exits.sendPort,
        onExit: exits.sendPort,
      );
      _port = await Future.any([
        ready.first.then((value) => value as SendPort),
        exited.future.then<SendPort>(
          (_) => throw const LuauException('Plugin worker failed to start'),
        ),
      ]);
    } catch (_) {
      exits.close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<void> release() {
    _generation++;
    _idle?.cancel();
    final released = _tail.then((_) async {
      final port = _port;
      if (port == null) return;
      final reply = ReceivePort();
      try {
        port.send(reply.sendPort);
        await Future.any([reply.first, _exited!.future]);
      } finally {
        reply.close();
        _port = null;
        _exited = null;
        _cached.clear();
      }
    });
    _tail = released;
    return released;
  }

  Future<void> close() {
    _closed = true;
    return release();
  }

  Future<void> invalidateOwner(String owner) {
    return invalidateOwners([owner]);
  }

  Future<void> invalidateOwners(Iterable<String> identities) {
    final owners = identities.toSet();
    for (final owner in owners) {
      _ownerGenerations[owner] = (_ownerGenerations[owner] ?? 0) + 1;
    }
    if (_port == null && _pending == 0) return Future.value();
    return _control((reply) => _Invalidate(reply, owners)).then((_) {});
  }

  Future<PluginDataReport> inspectData({DataOwner? owner}) async {
    if (dataDirectory == null) {
      throw const LuauException('Dataset storage is unavailable');
    }
    final result = await _control((reply) => _InspectData(reply, owner));
    return result.dataReport!;
  }

  Future<_Response> _control(Object Function(SendPort) message) {
    if (_closed) {
      return Future.error(const LuauException('Plugin worker is closed'));
    }
    _idle?.cancel();
    _pending++;
    final result = _tail
        .then((_) async {
          if (_closed) throw const LuauException('Plugin worker is closed');
          await _start();
          final reply = ReceivePort();
          try {
            if (_exited!.isCompleted) {
              throw const LuauException('Plugin worker stopped');
            }
            _activeReply = reply.sendPort;
            _port!.send(message(reply.sendPort));
            final response = await reply.first as _Response;
            _cached
              ..clear()
              ..addAll(response.cached);
            if (response.error != null) throw LuauException(response.error!);
            return response;
          } finally {
            _activeReply = null;
            reply.close();
          }
        })
        .whenComplete(() {
          _pending--;
          if (_pending == 0 && !_closed) {
            _idle = Timer(const Duration(seconds: 30), () => release());
          }
        });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class PluginDataReport {
  const PluginDataReport(
    this.inventory,
    this.usage, {
    this.residentVms = 0,
    this.vmBytes = 0,
  });
  final List<DataInventory> inventory;
  final List<DataUsage> usage;
  final int residentVms;
  final int vmBytes;
}

class _Invalidate {
  const _Invalidate(this.reply, this.owners);
  final SendPort reply;
  final Set<String> owners;
}

class _InspectData {
  const _InspectData(this.reply, this.owner);
  final SendPort reply;
  final DataOwner? owner;
}

class _Request {
  const _Request(
    this.reply,
    this.key,
    this.source,
    this.action,
    this.data,
    this.owner,
    this.input,
  );
  final SendPort reply;
  final String key;
  final String? source;
  final String action;
  final DataContext? data;
  final String owner;
  final Uint8List? input;
}

class _Response {
  const _Response(this.result, this.error, this.cached, {this.dataReport});
  final LuauResult? result;
  final String? error;
  final List<String> cached;
  final PluginDataReport? dataReport;
}

class _Start {
  const _Start(this.ready, this.directory, this.timeBudget);
  final SendPort ready;
  final String? directory;
  final Duration timeBudget;
}

void _serve(_Start start) async {
  final input = ReceivePort();
  final cache = <String, Pointer<Void>>{};
  final owners = <String, String>{};
  final dataStore = start.directory == null
      ? null
      : DatasetStore(Directory(start.directory!), timeBudget: start.timeBudget);
  start.ready.send(input.sendPort);
  await for (final message in input) {
    if (message is _Invalidate) {
      for (final key
          in owners.keys
              .where((key) => message.owners.contains(owners[key]))
              .toList()) {
        final vm = cache.remove(key);
        if (vm != null) _destroy(vm);
        owners.remove(key);
      }
      message.reply.send(_Response(null, null, cache.keys.toList()));
      continue;
    }
    if (message is _InspectData) {
      try {
        final inventory = dataStore!.inventory(owner: message.owner);
        final usage = message.owner == null
            ? <DataUsage>[]
            : dataStore.usage(message.owner!);
        final resident = cache.entries
            .where(
              (entry) =>
                  message.owner == null ||
                  owners[entry.key] == message.owner!.identity,
            )
            .toList();
        message.reply.send(
          _Response(
            null,
            null,
            cache.keys.toList(),
            dataReport: PluginDataReport(
              inventory,
              usage,
              residentVms: resident.length,
              vmBytes: resident.fold<int>(
                0,
                (bytes, entry) => bytes + _memory(entry.value),
              ),
            ),
          ),
        );
      } catch (error) {
        message.reply.send(_Response(null, '$error', cache.keys.toList()));
      }
      continue;
    }
    if (message is SendPort) {
      for (final vm in cache.values) {
        _destroy(vm);
      }
      cache.clear();
      dataStore?.close();
      input.close();
      message.send(true);
      break;
    }
    if (message is! _Request) continue;
    final request = message;
    var vm = cache.remove(request.key);
    final cold = vm == null;
    var invoked = false;
    DataInvocation? data;
    var usage = <DataUsage>[];
    void finishData() {
      final invocation = data;
      data = null;
      if (invocation != null) {
        usage = invocation.finish(
          nativeCalls: vm == null || vm == nullptr || !cold && !invoked
              ? 0
              : nativeDataCalls(vm),
        );
      }
    }

    LuauResult metrics({DataRecord? proposal, Object? value}) => LuauResult(
      cold: cold,
      loadMicros: vm == null || vm == nullptr || !cold ? 0 : _loadUs(vm),
      runMicros: vm == null || vm == nullptr || !invoked ? 0 : _runUs(vm),
      memoryBytes: vm == null || vm == nullptr ? 0 : _memory(vm),
      peakBytes: vm == null || vm == nullptr ? 0 : _peak(vm),
      dataProposal: proposal,
      value: value,
      responseBytes: vm == null || vm == nullptr || !invoked
          ? 0
          : _outputSize(vm),
      dataUsage: usage,
      dataCalls: vm == null || vm == nullptr || !cold && !invoked
          ? 0
          : nativeDataCalls(vm),
      dataWaitMicros: vm == null || vm == nullptr || !invoked
          ? 0
          : nativeDataWaitMicros(vm),
    );
    try {
      if (request.data != null) data = dataStore!.begin(request.data!);
      if (vm == null) {
        final source = request.source;
        if (source == null) throw const LuauException('Plugin source missing');
        if (cache.length >= LuauWorker.maxResident) {
          final oldest = cache.keys.first;
          _destroy(cache.remove(oldest)!);
          owners.remove(oldest);
        }
        vm = using(
          (arena) => _load(
            source.toNativeUtf8(allocator: arena),
            utf8.encode(source).length,
          ),
        );
        if (vm == nullptr) {
          throw const LuauException('Cannot allocate plugin VM');
        }
        final error = _error(vm!).toDartString();
        if (error.isNotEmpty) throw LuauException(error);
      }
      final state = vm;
      final binding = data == null ? null : NativeDataBinding(state, data!);
      final int status;
      try {
        invoked = true;
        status = using((arena) {
          final input = request.input;
          final buffer = input == null
              ? nullptr.cast<Uint8>()
              : arena<Uint8>(input.length);
          if (input != null) buffer.asTypedList(input.length).setAll(0, input);
          if (_input(state, buffer, input?.length ?? 0) != 0) {
            throw const LuauException('Cannot allocate plugin message');
          }
          return _invoke(state, request.action.toNativeUtf8(allocator: arena));
        });
      } finally {
        binding?.close();
      }
      final proposal = data?.proposal;
      finishData();
      if (status < 0) throw LuauException(_error(state).toDartString());
      final outputSize = _outputSize(state);
      final value = outputSize == 0
          ? null
          : decodeValue(_output(state).asTypedList(outputSize));
      final result = metrics(proposal: proposal, value: value);
      cache[request.key] = state;
      owners[request.key] = request.owner;
      request.reply.send(_Response(result, null, cache.keys.toList()));
    } catch (error) {
      var message = '$error';
      try {
        finishData();
      } catch (_) {
        message += '; usage could not be persisted';
      }
      final result = metrics();
      if (vm != null && vm != nullptr) _destroy(vm);
      owners.remove(request.key);
      request.reply.send(_Response(result, message, cache.keys.toList()));
    }
  }
}
