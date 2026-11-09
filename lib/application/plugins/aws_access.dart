import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/aws/aws_billing.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
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
        final host = (await ref.read(hostRepositoryProvider).all())
            .where((host) => host.id == id)
            .firstOrNull;
        if (host == null) {
          throw const PluginException(
            'The host chosen for AWS is gone; choose another in SYS · PLUGINS',
          );
        }
        if (host.hostKey == null) {
          throw const PluginException(
            'Verify the host key in MACHINES before connecting',
          );
        }
        final privateKey = await ref
            .read(privateKeyStoreProvider)
            .read(host.keyId);
        if (privateKey == null) {
          throw const PluginException('Host private key is unavailable');
        }
        check();
        final HostLease lease;
        try {
          lease = await ref
              .read(hostLinksProvider)
              .lease(
                address: host.address,
                port: host.port,
                user: host.user,
                privateKey: privateKey,
                verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
                use: HostUse.awsCost,
              );
        } on HostFailure catch (error) {
          throw PluginException(error.reason(host.name, address: host.address));
        }
        try {
          return await awsBilling(
            awsCliCall(
              (command, stdin) => leaseExec(
                lease,
                command,
                stdin: stdin,
                timeout: const Duration(seconds: 60),
              ),
            ),
            now,
          );
        } on Object catch (error) {
          if (!isHostFailure(error)) rethrow;
          throw PluginException('${host.name} did not answer');
        } finally {
          lease.release();
        }
    }
  } on AwsCostException catch (error) {
    throw PluginException(error.message);
  } on IOException {
    throw const PluginException('AWS could not be reached');
  } on TimeoutException {
    throw const PluginException('AWS did not answer in time');
  }
}
