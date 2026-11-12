import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/plugins/chosen_host.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/aws/aws_billing.dart';
import 'package:upgrade/platform/ssh/host_links.dart';

const _slot = 'aws.cost.keys';

sealed class AwsAccess {
  const AwsAccess();
}

final class AwsPhoneKeys extends AwsAccess {
  const AwsPhoneKeys(this.keys);
  final AwsKeys keys;
}

final class AwsHostCli extends AwsAccess {
  const AwsHostCli(this.host);
  final String host;
}

final awsAccessProvider = FutureProvider<AwsAccess?>(readAwsAccess);

Future<AwsAccess?> readAwsAccess(Ref ref) async {
  final stored = await ref.read(privateKeyStoreProvider).read(_slot);
  if (stored == null) return null;
  final fields = jsonDecode(stored);
  if (fields is! Map<String, Object?>) return null;
  return switch (fields) {
    {'host': final String host} => AwsHostCli(host),
    {'id': final String id, 'secret': final String secret} => AwsPhoneKeys((
      id: id,
      secret: secret,
    )),
    _ => null,
  };
}

Future<void> _write(WidgetRef ref, Map<String, String> fields) async {
  await ref.read(privateKeyStoreProvider).write(_slot, jsonEncode(fields));
  ref.invalidate(awsAccessProvider);
}

Future<void> saveAwsKeys(WidgetRef ref, String id, String secret) {
  id = id.trim();
  secret = secret.trim();
  if (!RegExp(r'^[A-Z0-9]{16,128}$').hasMatch(id) || secret.length < 16) {
    throw const PluginException('Paste an access key id and its secret');
  }
  return _write(ref, {'id': id, 'secret': secret});
}

Future<void> useAwsHost(WidgetRef ref, String host) =>
    _write(ref, {'host': host});

Future<void> forgetAwsAccess(WidgetRef ref) async {
  await ref.read(privateKeyStoreProvider).delete(_slot);
  ref.invalidate(awsAccessProvider);
}

Future<Map<String, Object?>> fetchAwsBilling(
  Ref ref,
  void Function() check,
) async {
  final access = await readAwsAccess(ref);
  final now = DateTime.now();
  try {
    switch (access) {
      case null:
        throw const PluginException(
          'No AWS access chosen; choose keys or a host on this plugin in SYS · PLUGINS',
        );
      case AwsPhoneKeys(:final keys):
        check();
        return await withAwsKeys(keys, (call) => awsBilling(call, now));
      case AwsHostCli(host: final id):
        return await onChosenHost(
          ref,
          id,
          HostUse.awsCost,
          check,
          gone: 'The host chosen for AWS is gone; choose another in SYS · PLUGINS',
          (run) => awsBilling(awsCliCall(run), now),
        );
    }
  } on AwsCostException catch (error) {
    throw PluginException(error.message);
  } on IOException {
    throw const PluginException('AWS could not be reached');
  } on TimeoutException {
    throw const PluginException('AWS did not answer in time');
  }
}
