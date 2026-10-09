import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _reasons = 'lib/platform/ssh/reasons.dart';
const _hostLinks = 'lib/platform/host_links.dart';

Iterable<File> _sources() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart') && file.path != _reasons);

Map<String, int> _mints(RegExp mint, {String? except}) => {
  for (final file in _sources())
    if (file.path != except)
      if (mint.allMatches(file.readAsStringSync()).length case final count
          when count > 0)
        file.path: count,
};

RegExp _member(String name) => RegExp('\\.$name\\b(?!\\])');

const _seam =
    "a new call site needs the owner's approval before it joins this list";

void main() {
  test('only HostLinks opens an ssh connection', () {
    final dials = RegExp(r'SSHSocket\.connect\(|SSHClient\(');
    final outside = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            file.path != 'lib/platform/host_links.dart' &&
            dials.hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(
      outside,
      isEmpty,
      reason: 'lease from HostLinks, or add a named dial to it',
    );
  });

  test('a UserIntent is minted only where a gesture lands', () {
    expect(
      _mints(RegExp(r'UserIntent\.fromGesture\b')),
      {
        'lib/features/shell/attach_sheet.dart': 2,
        'lib/features/shell/host_shell_screen.dart': 6,
      },
      reason:
          'mint UserIntent only in a gesture handler; a new call site needs the '
          "owner's approval before it joins this list",
    );
  });

  test('a PlatformSignal is minted only where the platform calls in', () {
    expect(
      _mints(RegExp(r'PlatformSignal\.fromPlatform\b')),
      {'lib/main.dart': 1, 'lib/features/shell/shell_wake.dart': 3},
      reason:
          'mint PlatformSignal only in a platform callback; a new call site needs '
          "the owner's approval before it joins this list",
    );
  });

  test('no other part of the ssh library reaches the private mints', () {
    final private = RegExp(r'\b(UserIntent|PlatformSignal)\._\b');
    expect(
      [
        for (final file in _sources())
          if (private.hasMatch(file.readAsStringSync())) file.path,
      ],
      isEmpty,
      reason: 'mint through fromGesture or fromPlatform only',
    );
  });

  test('only the shell tunnel dials through SshConnector.establish', () {
    expect(_mints(_member('establish')), {
      'lib/platform/shell/shell_tunnel.dart': 1,
    }, reason: 'a supervisor comes only from establish; $_seam');
  });

  test('only the supervisor renounces a host link', () {
    expect(_mints(_member('renounce'), except: _hostLinks), {
      'lib/platform/ssh/connection_supervisor.dart': 1,
    }, reason: 'a renounce ends a live control link; $_seam');
  });

  test('only the shell sessions put host links to sleep and wake them', () {
    expect(_mints(RegExp(r'\.(sleep|wake)\(\)'), except: _hostLinks), {
      'lib/features/shell/shell_sessions.dart': 2,
    }, reason: 'a sleep ends every yielding lease; $_seam');
  });

  test('only the shell wake rechecks every host link', () {
    expect(_mints(_member('recheckAll'), except: _hostLinks), {
      'lib/features/shell/shell_wake.dart': 1,
    }, reason: 'a recheck is a keepalive round on every link; $_seam');
  });

  test('only the known owners close host links', () {
    expect(_mints(RegExp(r'[lL]inks\??\.close\b(?!\])'), except: _hostLinks), {
      'lib/application/agents.dart': 1,
      'lib/platform/agent_watcher.dart': 1,
      'lib/platform/alert_actions.dart': 1,
    }, reason: 'a close ends every link in the pool; $_seam');
  });

  test('only the named borrowers reach a lease\'s raw client', () {
    expect(
      _mints(RegExp(r'(?<!\bthis)\.client\b(?!\])'), except: _hostLinks),
      {
        'lib/platform/herdr_client.dart': 1,
        'lib/platform/ssh/ssh_host.dart': 1,
        'lib/platform/vnc/vnc_tunnel.dart': 1,
      },
      reason: 'a raw client can close the connection under every lease; $_seam',
    );
  });
}
