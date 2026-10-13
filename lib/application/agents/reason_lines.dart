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

  String on(String host) => names ? '${host.toLowerCase()} $words' : words;

  String get short => words.toUpperCase();
}

String protocolLine(Object? protocol) => 'protocol ${protocol ?? '?'}';
