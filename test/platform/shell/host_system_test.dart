import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/features/hosts/host_mark.dart';
import 'package:upgrade/platform/shell/host_system.dart';

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

    test('Linux with no os-release is plain linux', () {
      expect(parseSystemProbe('Linux\n'), HostSystem.linux);
    });

    test('any other kernel is other', () {
      expect(parseSystemProbe('FreeBSD\n'), HostSystem.other);
      expect(parseSystemProbe(''), HostSystem.other);
    });
  });

  test('an unknown word on disk reads as never probed', () {
    expect(HostSystem.fromWire('plan9'), isNull);
    expect(HostSystem.fromWire(null), isNull);
    expect(HostSystem.fromWire('darwin'), HostSystem.darwin);
  });

  test('only nixos and darwin draw a vendor mark', () {
    expect(systemGlyph(HostSystem.nixos), UpgradeIcons.systemNixos);
    expect(systemGlyph(HostSystem.darwin), UpgradeIcons.systemDarwin);
    expect(systemGlyph(HostSystem.linux), UpgradeIcons.systemServer);
    expect(systemGlyph(HostSystem.other), UpgradeIcons.systemServer);
    expect(systemGlyph(null), UpgradeIcons.systemServer);
  });

  test(
    'the in-memory store keeps a learned system across a form save',
    () async {
      final hosts = InMemoryHostRepository();
      const nyx = Host(
        id: 'h1',
        name: 'nyx',
        address: '100.118.60.77',
        port: 357,
        user: 'luisnquin',
        keyId: 'k1',
      );
      await hosts.save(nyx);
      await hosts.recordSystem('h1', HostSystem.nixos);
      await hosts.save(nyx);

      expect((await hosts.all()).single.system, HostSystem.nixos);
    },
  );
}
