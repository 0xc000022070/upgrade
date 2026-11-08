import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/key_repository.dart';
import 'package:upgrade/platform/ssh/host_key_dial.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/keys.dart';

final keyRepositoryProvider = Provider<KeyRepository>(
  (ref) => InMemoryKeyRepository(),
);

final hostRepositoryProvider = Provider<HostRepository>(
  (ref) => InMemoryHostRepository(),
);

final privateKeyStoreProvider = Provider<PrivateKeyStore>(
  (ref) => CachingPrivateKeyStore(const SecurePrivateKeyStore()),
);

final ed25519KeysProvider = Provider(
  (ref) => Ed25519Keys(ref.watch(privateKeyStoreProvider)),
);

final managedKeysProvider = StreamProvider<List<ManagedKey>>(
  (ref) => ref.watch(keyRepositoryProvider).watchAll(),
);

final hostsProvider = StreamProvider<List<Host>>(
  (ref) => ref.watch(hostRepositoryProvider).watchAll(),
);

final registeredHostProvider = Provider.family<Host?, String>(
  (ref, id) => ref
      .watch(hostsProvider)
      .value
      ?.where((host) => host.id == id)
      .firstOrNull,
);

final herdrHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.herdr),
);

final engineHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.agents),
);

final deviceHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.devices),
);

final vncHostsProvider = StreamProvider<List<Host>>(
  (ref) => ref
      .watch(hostRepositoryProvider)
      .watchWithIntegration(IntegrationKind.vnc),
);

class ScreenHost {
  const ScreenHost(this.host, {required this.desktop, required this.devices});

  final Host host;
  final bool desktop;
  final bool devices;
}

final screenHostsProvider = Provider<List<ScreenHost>?>((ref) {
  final desktops = ref.watch(vncHostsProvider).value;
  final devices = ref.watch(deviceHostsProvider).value;
  if (desktops == null || devices == null) return null;
  final desktopIds = {for (final host in desktops) host.id};
  final deviceIds = {for (final host in devices) host.id};
  final hosts = {
    for (final host in [...desktops, ...devices]) host.id: host,
  }.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return [
    for (final host in hosts)
      ScreenHost(
        host,
        desktop: desktopIds.contains(host.id),
        devices: deviceIds.contains(host.id),
      ),
  ];
});

final hostIntegrationsProvider =
    StreamProvider.family<Set<IntegrationKind>, String>(
      (ref, hostId) =>
          ref.watch(hostRepositoryProvider).watchIntegrations(hostId),
    );

final hostKeyPinsProvider = Provider<HostKeyPins>((ref) {
  final hosts = ref.watch(hostRepositoryProvider);
  return HostKeyPins(store: hosts.pinHostKey, forget: hosts.forgetHostKey);
});

final hostLinksProvider = Provider<HostLinks>((ref) {
  final links = HostLinks();
  ref.onDispose(links.close);
  return links;
});

final hostKeyDialProvider = Provider<HostKeyDial>((ref) => HostLinks.probe);
