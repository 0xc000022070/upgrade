import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/plugins/chosen_host.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/device.dart';
import 'package:upgrade/platform/pass/pass_cli.dart';
import 'package:upgrade/platform/ssh/host_links.dart';

const _slot = 'pass.host';
const passClearSeconds = 45;

final passHostProvider = FutureProvider<String?>(
  (ref) => ref.read(privateKeyStoreProvider).read(_slot),
);

Future<void> usePassHost(WidgetRef ref, String host) async {
  await ref.read(privateKeyStoreProvider).write(_slot, host);
  ref.invalidate(passHostProvider);
}

Future<void> forgetPassHost(WidgetRef ref) async {
  await ref.read(privateKeyStoreProvider).delete(_slot);
  ref.invalidate(passHostProvider);
}

Future<T> _onPassHost<T>(
  Ref ref,
  void Function() check,
  Future<T> Function(PassRun run) body,
) async {
  final id = await ref.read(privateKeyStoreProvider).read(_slot);
  if (id == null) {
    throw const PluginException(
      'No host chosen for Pass; choose one on this plugin in SYS · PLUGINS',
    );
  }
  try {
    return await onChosenHost(
      ref,
      id,
      HostUse.pass,
      check,
      body,
      gone: 'The host chosen for Pass is gone; choose another in SYS · PLUGINS',
    );
  } on PassException catch (error) {
    throw PluginException(error.message);
  }
}

Future<Map<String, Object?>> listPass(Ref ref, void Function() check) async => {
  'entries': await _onPassHost(ref, check, passList),
};

Future<Map<String, Object?>> copyPass(
  Ref ref,
  Map<String, Object?> args,
  void Function() check, {
  bool otp = false,
}) async {
  final entry = args['entry'];
  if (entry is! String || !passEntryValid(entry)) {
    throw const PluginException('copy takes an entry from the list');
  }
  final secret = await _onPassHost(
    ref,
    check,
    (run) => otp ? passOtp(run, entry) : passShow(run, entry),
  );
  try {
    await Device.copySecret(secret, passClearSeconds);
  } on MissingPluginException {
    throw const PluginException('This phone cannot copy a password');
  } on PlatformException {
    throw const PluginException('This phone cannot copy a password');
  }
  return {'entry': entry, 'clears': passClearSeconds};
}
