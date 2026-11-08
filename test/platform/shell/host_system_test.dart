import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/host_system.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/platform/shell/host_system.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/host_files.dart';

void main() {
  group('the probe answer', () {
    test('Darwin is macOS whatever follows it', () {
      expect(parseSystemProbe('Darwin\n'), HostSystem.darwin);
    });

    test('Linux with a nixos id is NixOS', () {
      expect(
        parseSystemProbe(
          'Linux\nANSI_COLOR="0;38;2;126;186;228"\nID=nixos\n'
          'NAME=NixOS\nVERSION_ID="25.11"\n',
        ),
        HostSystem.nixos,
      );
    });

    test('a quoted id is read through its quotes', () {
      expect(parseSystemProbe('Linux\nID="nixos"\n'), HostSystem.nixos);
    });

    test('an id_like of nixos is not nixos', () {
      expect(
        parseSystemProbe('Linux\nID=debian\nID_LIKE=nixos\n'),
        HostSystem.linux,
      );
    });

    test(
      'Ubuntu, Arch and Alpine, ARM builds included, are read by their id',
      () {
        expect(parseSystemProbe('Linux\nID=ubuntu\n'), HostSystem.ubuntu);
        expect(parseSystemProbe('Linux\nID=alpine\n'), HostSystem.alpine);
        expect(parseSystemProbe('Linux\nID=arch\n'), HostSystem.arch);
        expect(
          parseSystemProbe('Linux\nID=archarm\nID_LIKE=arch\n'),
          HostSystem.arch,
        );
        expect(
          parseSystemProbe('Linux\nID=manjaro\nID_LIKE=arch\n'),
          HostSystem.linux,
        );
      },
    );

    test('Linux with no os-release is plain linux', () {
      expect(parseSystemProbe('Linux\n'), HostSystem.linux);
    });

    test('any other kernel is other', () {
      expect(parseSystemProbe('FreeBSD\n'), HostSystem.other);
      expect(parseSystemProbe(''), HostSystem.other);
    });
  });

  group('the probe', () {
    test(
      'a Mac is read by its answer, not by the exit of a missing os-release',
      () async {
        final channels = _Answers(
          ExecResult(
            exitCode: 1,
            stdout: _bytes('Darwin\n'),
            stderr: _bytes(''),
          ),
        );
        expect(await probeSystem(channels), HostSystem.darwin);
      },
    );

    test('no exec or no answer is never probed', () async {
      expect(await probeSystem(_Answers(null)), isNull);
      expect(
        await probeSystem(
          _Answers(
            ExecResult(
              exitCode: 127,
              stdout: _bytes(''),
              stderr: _bytes('sh: not found'),
            ),
          ),
        ),
        isNull,
      );
    });
  });

  test('an unknown word on disk reads as never probed', () {
    expect(HostSystem.fromWire('plan9'), isNull);
    expect(HostSystem.fromWire(null), isNull);
    expect(HostSystem.fromWire('darwin'), HostSystem.darwin);
  });

  test('a known system draws its vendor mark and the rest a rack unit', () {
    expect(systemGlyph(HostSystem.nixos), UpgradeIcons.systemNixos);
    expect(systemGlyph(HostSystem.darwin), UpgradeIcons.systemDarwin);
    expect(systemGlyph(HostSystem.ubuntu), UpgradeIcons.systemUbuntu);
    expect(systemGlyph(HostSystem.arch), UpgradeIcons.systemArch);
    expect(systemGlyph(HostSystem.alpine), UpgradeIcons.systemAlpine);
    expect(systemGlyph(HostSystem.linux), UpgradeIcons.systemServer);
    expect(systemGlyph(HostSystem.other), UpgradeIcons.systemServer);
    expect(systemGlyph(null), UpgradeIcons.systemServer);
  });

  test(
    'the in-memory store keeps a learned system across a form save',
    () async {
      final hosts = InMemoryHostRepository();
      const oak = Host(
        id: 'h1',
        name: 'oak',
        address: '198.51.100.77',
        port: 357,
        user: 'developer',
        keyId: 'k1',
      );
      await hosts.save(oak);
      await hosts.recordSystem('h1', HostSystem.nixos);
      await hosts.save(oak);

      expect((await hosts.all()).single.system, HostSystem.nixos);
    },
  );
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _Answers implements HostChannels {
  _Answers(this.result);

  final ExecResult? result;

  @override
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) async => result;

  @override
  Future<FileWrite?> put(
    String path,
    FileBody body, {
    required Duration timeout,
    PutProgress? onProgress,
  }) => throw UnimplementedError();
}
