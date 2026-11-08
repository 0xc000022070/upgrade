import 'dart:io';

import 'package:upgrade/platform/device.dart';

enum ReasonLine {
  unresolved('unresolved', names: true),
  unreachable('unreachable', names: true),
  keyRejected('key rejected'),
  shellRefused('shell refused'),
  streamClosed('stream closed'),
  hostKeyUnverified('host key unverified'),
  hostKeyChanged('host key changed'),
  hostBusy('host busy'),

  protocolMismatch('protocol mismatch'),
  noEngine('no engine'),
  noHerdr('no herdr'),

  tunnelRefused('tunnel refused'),
  authUnsupported('auth unsupported'),
  usernameNeeded('VNC username missing'),
  passwordNeeded('VNC password missing'),
  passwordRejected('VNC credentials rejected'),

  notABundle('not a bundle'),
  newerBundle('newer bundle'),
  wrongPassphrase('wrong passphrase'),
  bundleIncomplete('bundle incomplete'),
  noPicker('no picker'),

  bootTimedOut('not booted in 3 min'),
  noDeviceTools('no emulator or xcrun'),
  noAvdManager('no avdmanager'),
  noSystemImage('no system image'),
  noRuntime('no simulator runtime');

  const ReasonLine(this.words, {this.names = false});

  final String words;

  final bool names;

  String on(String host, {String? address}) {
    if (!names) return words;
    final line = '${host.toLowerCase()} $words';
    return address != null && Device.vpn == false && isTailnetAddress(address)
        ? '$line · vpn off'
        : line;
  }

  String get short => words.toUpperCase();

  String reason(String host, {String? address, Object? protocol}) =>
      this == protocolMismatch
      ? protocolLine(protocol)
      : on(host, address: address);

  String shortReason({Object? protocol}) =>
      (this == protocolMismatch ? protocolLine(protocol) : words).toUpperCase();
}

String protocolLine(Object? protocol) => 'protocol ${protocol ?? '?'}';

bool isTailnetAddress(String address) {
  final ip = InternetAddress.tryParse(address);
  if (ip == null) {
    final name = address.toLowerCase();
    return name.endsWith('.ts.net') || name.endsWith('.ts.net.');
  }
  final b = ip.rawAddress;
  return switch (ip.type) {
    InternetAddressType.IPv4 => b[0] == 100 && (b[1] & 0xc0) == 64,
    InternetAddressType.IPv6 =>
      b[0] == 0xfd &&
          b[1] == 0x7a &&
          b[2] == 0x11 &&
          b[3] == 0x5c &&
          b[4] == 0xa1 &&
          b[5] == 0xe0,
    _ => false,
  };
}
