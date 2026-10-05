import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../data_api.dart';
import 'dataset_store.dart';

const _asset = 'package:upgrade_luau/upgrade_luau.dart';
typedef _DataCall = Void Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf8>,
  Size,
  Pointer<Utf8>,
  Size,
  Pointer<Utf8>,
  Size,
  Int64,
  Int32,
);

@Native<Void Function(Pointer<Void>, Pointer<NativeFunction<_DataCall>>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_data_callback',
)
external void _callback(
  Pointer<Void> vm,
  Pointer<NativeFunction<_DataCall>> callback,
);
@Native<Void Function(Pointer<Void>, Pointer<Utf8>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_data_error',
)
external void _error(Pointer<Void> vm, Pointer<Utf8> error);
@Native<
  Void Function(Pointer<Void>, Pointer<Utf8>, Size, Pointer<Utf8>, Size, Int64)
>(assetId: _asset, symbol: 'upgrade_vm_data_record')
external void _record(
  Pointer<Void> vm,
  Pointer<Utf8> key,
  int keySize,
  Pointer<Utf8> value,
  int valueSize,
  int revision,
);
@Native<Void Function(Pointer<Void>, Int64, Bool)>(
  assetId: _asset,
  symbol: 'upgrade_vm_data_reply',
)
external void _reply(Pointer<Void> vm, int revision, bool changed);
@Native<Uint32 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_data_calls',
)
external int nativeDataCalls(Pointer<Void> vm);
@Native<Int64 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'upgrade_vm_data_wait_us',
)
external int nativeDataWaitMicros(Pointer<Void> vm);

class NativeDataBinding {
  NativeDataBinding(this.vm, this.invocation) {
    _callable = NativeCallable<_DataCall>.isolateLocal(_call);
    _callback(vm, _callable.nativeFunction);
  }
  final Pointer<Void> vm;
  final DataInvocation invocation;
  late final NativeCallable<_DataCall> _callable;

  void _call(
    Pointer<Void> state,
    int operation,
    Pointer<Utf8> alias,
    int aliasSize,
    Pointer<Utf8> key,
    int keySize,
    Pointer<Utf8> value,
    int valueSize,
    int revision,
    int limit,
  ) {
    try {
      final result = invocation.call(
        DataOperation.values[operation],
        alias.toDartString(length: aliasSize),
        key: key.toDartString(length: keySize),
        value: value.toDartString(length: valueSize),
        revision: revision,
        limit: limit,
      );
      using((arena) {
        for (final record in result.records) {
          _record(
            state,
            record.key.toNativeUtf8(allocator: arena),
            utf8.encode(record.key).length,
            record.value.toNativeUtf8(allocator: arena),
            utf8.encode(record.value).length,
            record.revision,
          );
        }
        _reply(state, result.revision, result.changed);
      });
    } catch (error) {
      final text = error is DataException
          ? error.message
          : 'Dataset operation failed';
      using((arena) => _error(state, text.toNativeUtf8(allocator: arena)));
    }
  }

  void close() {
    _callback(vm, nullptr);
    _callable.close();
  }
}
