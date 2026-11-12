import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';

Future<T> onChosenHost<T>(
  Ref ref,
  String id,
  HostUse use,
  void Function() check,
  Future<T> Function(
    Future<ExecResult> Function(String command, Uint8List stdin) run,
  )
  body, {
  required String gone,
}) async {
  final host = (await ref.read(hostRepositoryProvider).all())
      .where((host) => host.id == id)
      .firstOrNull;
  if (host == null) throw PluginException(gone);
  if (host.hostKey == null) {
    throw const PluginException(
      'Verify the host key in MACHINES before connecting',
    );
  }
  final privateKey = await ref.read(privateKeyStoreProvider).read(host.keyId);
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
          use: use,
        );
  } on HostFailure catch (error) {
    throw PluginException(error.reason(host.name, address: host.address));
  }
  try {
    return await body(
      (command, stdin) => leaseExec(
        lease,
        command,
        stdin: stdin,
        timeout: const Duration(seconds: 60),
      ),
    );
  } on Object catch (error) {
    if (!isHostFailure(error)) rethrow;
    throw PluginException('${host.name} did not answer');
  } finally {
    lease.release();
  }
}
