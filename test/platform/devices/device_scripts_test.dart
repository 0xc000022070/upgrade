import 'dart:io';

import 'package:upgrade/platform/devices/device_link.dart';
import 'package:flutter_test/flutter_test.dart';

final _devices = File('test/fixtures/simctl/simctl_devices.json')
    .readAsStringSync();
final _types = File('test/fixtures/simctl/simctl_devicetypes.json')
    .readAsStringSync();
final _runtimes = File('test/fixtures/simctl/simctl_runtimes.json')
    .readAsStringSync();

const _ios27 = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0';
const _ios265 = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5';

const _adb = r'''#!/bin/sh
echo "adb $*" >>"$STATE/calls"
case "$*" in
  devices)
    echo 'List of devices attached'
    [ -f "$STATE/up" ] && printf 'emulator-5556\tdevice\n'
    [ -f "$STATE/phys" ] && printf '10.0.0.5:5555\tdevice\nR5CT1234\tdevice\n'
    ;;
  '-s R5CT1234 shell getprop ro.serialno'|'-s 10.0.0.5:5555 shell getprop ro.serialno') echo R5CT1234 ;;
  '-s emulator-5556 emu avd name')
    [ -f "$STATE/noname" ] || { cat "$STATE/up"; echo; echo OK; }
    ;;
  '-s emulator-5556 shell getprop ro.boot.qemu.avd_name') cat "$STATE/up" ;;
  '-s emulator-5556 shell getprop sys.boot_completed') echo 1 ;;
  '-s emulator-5556 emu kill') rm -f "$STATE/up" ;;
  '-s R5CT1234 emu avd name') exit 1 ;;
  '-s R5CT1234 shell getprop ro.product.model') echo 'Pixel 8' ;;
esac
exit 0
''';

const _emulator = r'''#!/bin/sh
if [ "$1" = -list-avds ]; then cat "$STATE/avds"; exit 0; fi
for a in "$@"; do echo "$a"; done >"$STATE/argv"
if [ -f "$STATE/die" ]; then
  echo 'INFO    | starting'
  echo "PANIC: Missing emulator engine program for 'x86' CPU."
  exit 1
fi
echo 'INFO    | booting'
printf '%s' "$2" >"$STATE/up"
while [ -d "$STATE" ]; do sleep 1; done
''';

const _avdmanager = r'''#!/bin/sh
echo "avdmanager $*" >>"$STATE/calls"
if [ -f "$STATE/avdfail" ]; then
  echo 'Loading local repository...'
  echo "Error: Package path is not valid. Valid system image paths are:"
  echo 'null'
  exit 1
fi
case "$1 $2" in
  'list device') printf 'pixel_7\nmedium_phone\n' ;;
  'create avd') cat >/dev/null ;;
esac
exit 0
''';

const _xcrun = r'''#!/bin/sh
echo "xcrun $*" >>"$STATE/calls"
case "$*" in
  'simctl list devices -j') cat "$STATE/devices.json" ;;
  'simctl list devicetypes -j') cat "$STATE/types.json" ;;
  'simctl list runtimes -j') cat "$STATE/runtimes.json" ;;
  'simctl boot BAD') echo 'An error was encountered processing the command (domain=com.apple.CoreSimulatorService.ErrorDomain, code=405):' >&2; echo 'Unable to boot device in current state: Booted' >&2; exit 149 ;;
esac
exit 0
''';

const _tools = [
  'sh',
  'mktemp',
  'rm',
  'cat',
  'head',
  'tail',
  'grep',
  'awk',
  'tr',
  'sed',
  'dirname',
  'perl',
];

class _Host {
  _Host(this.root);

  final Directory root;

  String get state => '${root.path}/state';
  String get bin => '${root.path}/bin';

  File file(String name) => File('$state/$name');

  List<String> get calls =>
      file('calls').existsSync() ? file('calls').readAsLinesSync() : const [];

  Future<String> run(
    String command, {
    Map<String, String> env = const {},
  }) async {
    final result = await Process.run(
      'sh',
      ['-c', command],
      includeParentEnvironment: false,
      environment: {'PATH': bin, 'STATE': state, 'HOME': root.path, ...env},
    );
    return '${result.stdout}';
  }
}

Future<String?> _which(String tool) async {
  final result = await Process.run('sh', ['-c', 'command -v $tool']);
  final path = '${result.stdout}'.trim();
  return path.isEmpty ? null : path;
}

Future<_Host> _host({
  bool android = true,
  bool ios = false,
  bool setsid = true,
  bool avdmanager = true,
}) async {
  final root = await Directory.systemTemp.createTemp('devboot');
  addTearDown(() => root.delete(recursive: true));
  final host = _Host(root);
  await Directory(host.bin).create();
  await Directory(host.state).create();
  for (final tool in [..._tools, if (setsid) 'setsid']) {
    final path = await _which(tool);
    if (path != null) await Link('${host.bin}/$tool').create(path);
  }
  Future<void> shim(String name, String body) async {
    await File('${host.bin}/$name').writeAsString(body);
    await Process.run('chmod', ['+x', '${host.bin}/$name']);
  }

  await shim('sleep', '#!/bin/sh\nexec ${await _which('sleep')} 0.05\n');

  if (android) {
    await shim('adb', _adb);
    await shim('emulator', _emulator);
    if (avdmanager) await shim('avdmanager', _avdmanager);
  }
  if (ios) {
    await shim('xcrun', _xcrun);
    await host.file('devices.json').writeAsString(_devices);
    await host.file('types.json').writeAsString(_types);
    await host.file('runtimes.json').writeAsString(_runtimes);
  }
  return host;
}

const _pixel = StoppedDevice(
  kind: DeviceKind.android,
  id: 'Pixel_9.api-36',
  name: 'Pixel_9.api-36',
);

void main() {
  group('listing', () {
    test(
      'emulators carry their avd, phones do not, simulators come booted',
      () {
        final devices = parseDeviceList(
          'E emulator-5554 Pixel_9\n'
          'noise\n'
          'A R5CT1234 Pixel 8\n'
          'A 0123ABCD\n'
          '@simctl\n$_devices',
        );
        expect(devices.map((device) => device.name), [
          'Pixel_9',
          'Pixel 8',
          '0123ABCD',
          'iPhone 17 Pro Max',
        ]);
        expect(devices[0].avd, 'Pixel_9');
        expect(devices[0].managed, isTrue);
        expect(devices[1].avd, isNull);
        expect(devices[1].managed, isFalse);
        expect(devices[3].kind, DeviceKind.simulator);
        expect(devices[3].id, '40172ED1-4DBE-4C01-A8F0-31CF4679636D');
        expect(devices[3].runtime, _ios265);
        expect(devices[3].managed, isTrue);
      },
    );

    test('no simulator output lists none, a broken one throws', () {
      expect(
        parseDeviceList('E emulator-5554 Pixel_9\n@simctl\n'),
        hasLength(1),
      );
      expect(
        () => parseDeviceList('@simctl\n{"devices": '),
        throwsFormatException,
      );
    });

    test('a stopped listing names its tools and every shut down device', () {
      final listing = parseStoppedList(
        'T A\nE Pixel_9\nE Small.api-34\nT I\n@simctl\n$_devices',
      );
      expect(listing.tools, {DeviceKind.android, DeviceKind.simulator});
      final names = listing.devices.map((device) => device.name).toList();
      expect(names.take(2), ['Pixel_9', 'Small.api-34']);
      expect(listing.devices, hasLength(2 + 22));
      expect(names, isNot(contains('iPhone 17 Pro Max')));
      expect(names, contains('iPhone 17 · iOS 27.0'));
      expect(names, contains('iPhone 17 · iOS 26.5'));
      expect(names, contains('iPhone 17 Pro'));
      expect(names, contains('native-parity-iphone'));
      expect(names.where((name) => name.startsWith('Pixel')), ['Pixel_9']);
    });

    test('a shared name takes its runtime; an unavailable one is dropped', () {
      const json = '''
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
    {"udid": "A", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true},
    {"udid": "C", "name": "iPhone Air", "state": "Shutdown", "isAvailable": false}
  ],
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
    {"udid": "B", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true},
    {"udid": "D", "name": "iPhone Air", "state": "Shutdown", "isAvailable": true}
  ]
}}''';
      expect(
        parseDeviceList('@simctl\n$json').single.name,
        'iPhone 17 Pro · iOS 27.0',
      );
      expect(
        parseStoppedList('T I\n@simctl\n$json').devices.map((d) => d.name),
        ['iPhone 17 Pro · iOS 26.5', 'iPhone Air'],
      );
    });

    test('the runtime label comes from the runtime key', () {
      expect(runtimeLabel(_ios27), 'iOS 27.0');
      expect(
        runtimeLabel('com.apple.CoreSimulator.SimRuntime.watchOS-11-2'),
        'watchOS 11.2',
      );
    });

    test('an answer is the last outcome line, or none', () {
      expect(parseOutcome('noise\nOK\n'), (
        ok: true,
        serial: null,
        error: null,
      ));
      expect(parseOutcome('B emulator-5556\n').serial, 'emulator-5556');
      expect(parseOutcome('E PANIC: no engine\n').error, 'PANIC: no engine');
      expect(parseOutcome('E\n').error, 'failed');
      expect(parseOutcome('').error, 'no answer');
    });
  });

  group('catalog', () {
    test('android reads profiles and images, X has no avdmanager', () {
      final catalog = parseAndroidCatalog(
        'P pixel_7\nP medium_phone\nS system-images;android-36;google_apis;x86_64\nS system-images;android-36;google_apis;x86_64\n',
      );
      expect(catalog.available, isTrue);
      expect(catalog.offered.map((entry) => entry.id), [
        'pixel_7',
        'medium_phone',
      ]);
      expect(
        catalog.imagesFor('pixel_7').single.id,
        'system-images;android-36;google_apis;x86_64',
      );
      expect(parseAndroidCatalog('X\n').available, isFalse);
    });

    test('ios offers only types some runtime runs, and runtimes by type', () {
      final catalog = parseSimulatorCatalog(
        '@devicetypes\n$_types\n@runtimes\n$_runtimes',
      );
      expect(catalog.profiles, hasLength(129));
      expect(catalog.images.map((entry) => entry.name), [
        'iOS 26.5',
        'iOS 27.0',
      ]);
      final offered = catalog.offered;
      expect(offered.length, lessThan(catalog.profiles.length));
      expect(offered.map((entry) => entry.name), contains('iPhone 17'));
      final iphone17 = offered.firstWhere((entry) => entry.name == 'iPhone 17');
      expect(catalog.imagesFor(iphone17.id), hasLength(2));
      final runs = {for (final image in catalog.images) ...?image.supports};
      for (final entry in offered) {
        expect(runs, contains(entry.id));
      }
    });

    test('ios runtimes without supported types offer every type', () {
      final catalog = parseSimulatorCatalog(
        '@devicetypes\n{"devicetypes":[{"identifier":"t1","name":"One"},{"identifier":"t2","name":"Two"}]}\n'
        '@runtimes\n{"runtimes":[{"identifier":"r1","name":"iOS 1.0","isAvailable":true},{"identifier":"r2","name":"iOS 0.9","isAvailable":false}]}',
      );
      expect(catalog.offered.map((entry) => entry.id), ['t1', 't2']);
      expect(catalog.imagesFor('t1').single.id, 'r1');
      expect(parseSimulatorCatalog('X\n').available, isFalse);
    });
  });

  group('commands', () {
    test('every name reaches the host quoted', () {
      const odd = StoppedDevice(
        kind: DeviceKind.simulator,
        id: "a'b",
        name: 'x',
      );
      expect(
        DeviceCommands.boot(odd, cold: false),
        contains("id='\\''a'\\''\\'\\'''\\''b'\\''"),
      );
      expect(
        DeviceCommands.create(
          const NewDevice(
            kind: DeviceKind.android,
            name: 'P',
            profile: 'pixel_7',
            image: 'system-images;android-36;google_apis;x86_64',
          ),
        ),
        contains("image='\\''system-images;android-36;google_apis;x86_64'\\''"),
      );
    });

    test('a cold boot skips the snapshot, a warm one does not', () {
      expect(
        DeviceCommands.boot(_pixel, cold: true),
        contains('-no-snapshot-load'),
      );
      expect(
        DeviceCommands.boot(_pixel, cold: false),
        isNot(contains('-no-snapshot-load')),
      );
      expect(
        DeviceCommands.boot(_pixel, cold: false),
        contains('head -c 65536'),
      );
    });

    test('every script parses', () async {
      final scripts = [
        DeviceCommands.list(),
        DeviceCommands.stopped(),
        DeviceCommands.boot(_pixel, cold: true),
        DeviceCommands.boot(_pixel, cold: false),
        DeviceCommands.boot(
          const StoppedDevice(kind: DeviceKind.simulator, id: 'U', name: 'x'),
          cold: false,
        ),
        DeviceCommands.shutDown(
          const HostDevice(
            kind: DeviceKind.android,
            id: 'emulator-5556',
            name: 'x',
            avd: 'x',
          ),
        ),
        DeviceCommands.shutDown(
          const HostDevice(kind: DeviceKind.simulator, id: 'U', name: 'x'),
        ),
        DeviceCommands.delete(
          kind: DeviceKind.android,
          id: 'x',
          serial: 'emulator-5556',
        ),
        DeviceCommands.delete(kind: DeviceKind.simulator, id: 'U'),
        DeviceCommands.catalog(DeviceKind.android),
        DeviceCommands.catalog(DeviceKind.simulator),
        DeviceCommands.create(
          const NewDevice(
            kind: DeviceKind.android,
            name: 'x',
            profile: 'p',
            image: 'i',
          ),
        ),
        DeviceCommands.create(
          const NewDevice(
            kind: DeviceKind.simulator,
            name: 'x y',
            profile: 'p',
            image: 'i',
          ),
        ),
      ];
      for (final script in scripts) {
        final inner = script.replaceFirst('sh -c ', 'sh -n -c ');
        final result = await Process.run('sh', ['-c', inner]);
        expect(result.exitCode, 0, reason: '${result.stderr}\n$script');
      }
    });
  });

  group('on a host', () {
    test(
      'the stopped list leaves out what runs and what has no safe name',
      () async {
        final host = await _host(ios: true);
        await host
            .file('avds')
            .writeAsString('Pixel_9\nSmall.api-34\nbad name\n');
        await host.file('up').writeAsString('Pixel_9');
        final listing = parseStoppedList(
          await host.run(DeviceCommands.stopped()),
        );
        expect(listing.tools, {DeviceKind.android, DeviceKind.simulator});
        final names = listing.devices.map((device) => device.name).toList();
        expect(names.first, 'Small.api-34');
        expect(names, isNot(contains('Pixel_9')));
        expect(names, isNot(contains('bad name')));
        expect(names, contains('iPhone 17 · iOS 27.0'));
      },
    );

    test('no emulator and no xcrun lists no tools', () async {
      final host = await _host(android: false);
      final listing = parseStoppedList(
        await host.run(DeviceCommands.stopped()),
      );
      expect(listing.tools, isEmpty);
      expect(listing.devices, isEmpty);
    });

    test('the list names emulators by avd, falling back to getprop', () async {
      final host = await _host(ios: true);
      await host.file('up').writeAsString('Pixel_9');
      await host.file('phys').writeAsString('');
      await host.file('noname').writeAsString('');
      final devices = parseDeviceList(await host.run(DeviceCommands.list()));
      expect(devices[0].avd, 'Pixel_9');
      expect(devices[0].id, 'emulator-5556');
      expect(devices[1].name, 'Pixel 8');
      expect(devices[1].id, 'R5CT1234');
      expect(devices[1].avd, isNull);
      expect(devices.where((d) => d.name == 'Pixel 8'), hasLength(1));
      expect(devices.last.name, 'iPhone 17 Pro Max');
    });

    for (final cold in [false, true]) {
      test(
        'a ${cold ? 'cold' : 'warm'} boot answers once the device has booted',
        () async {
          final host = await _host();
          final out = await host.run(DeviceCommands.boot(_pixel, cold: cold));
          expect(parseOutcome(out).serial, 'emulator-5556');
          expect(host.file('argv').readAsLinesSync(), [
            '-avd',
            'Pixel_9.api-36',
            '-no-window',
            '-no-audio',
            if (cold) '-no-snapshot-load',
          ]);
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }

    test('a boot answers on an image with no emu avd name', () async {
      final host = await _host();
      await host.file('noname').writeAsString('');
      final out = await host.run(DeviceCommands.boot(_pixel, cold: false));
      expect(parseOutcome(out).serial, 'emulator-5556');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a boot without setsid detaches through perl', () async {
      if (await _which('perl') == null) return markTestSkipped('no perl');
      final host = await _host(setsid: false);
      expect(File('${host.bin}/setsid').existsSync(), isFalse);
      final out = await host.run(DeviceCommands.boot(_pixel, cold: false));
      expect(parseOutcome(out).serial, 'emulator-5556');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('an emulator that dies says its last line', () async {
      final host = await _host();
      await host.file('die').writeAsString('');
      final out = await host.run(DeviceCommands.boot(_pixel, cold: false));
      expect(
        parseOutcome(out).error,
        "PANIC: Missing emulator engine program for 'x86' CPU.",
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a simulator boot failure says the error line', () async {
      final host = await _host(android: false, ios: true);
      final ok = await host.run(
        DeviceCommands.boot(
          const StoppedDevice(kind: DeviceKind.simulator, id: 'U1', name: 'x'),
          cold: false,
        ),
      );
      expect(parseOutcome(ok).ok, isTrue);
      final bad = await host.run(
        DeviceCommands.boot(
          const StoppedDevice(kind: DeviceKind.simulator, id: 'BAD', name: 'x'),
          cold: false,
        ),
      );
      expect(
        parseOutcome(bad).error,
        startsWith('An error was encountered processing the command'),
      );
      expect(host.calls, ['xcrun simctl boot U1', 'xcrun simctl boot BAD']);
    });

    test('shut down kills the emulator and waits for it to leave', () async {
      final host = await _host();
      await host.file('up').writeAsString('Pixel_9');
      final out = await host.run(
        DeviceCommands.shutDown(
          const HostDevice(
            kind: DeviceKind.android,
            id: 'emulator-5556',
            name: 'Pixel_9',
            avd: 'Pixel_9',
          ),
        ),
      );
      expect(parseOutcome(out).ok, isTrue);
      expect(host.calls, ['adb -s emulator-5556 emu kill', 'adb devices']);
    });

    test('deleting a running emulator stops it first', () async {
      final host = await _host();
      await host.file('up').writeAsString('Pixel_9');
      final out = await host.run(
        DeviceCommands.delete(
          kind: DeviceKind.android,
          id: 'Pixel_9',
          serial: 'emulator-5556',
        ),
      );
      expect(parseOutcome(out).ok, isTrue);
      expect(host.calls, [
        'adb -s emulator-5556 emu kill',
        'adb devices',
        'avdmanager delete avd -n Pixel_9',
      ]);
    });

    test('a refused create says the error line', () async {
      final host = await _host();
      await host.file('avdfail').writeAsString('');
      final out = await host.run(
        DeviceCommands.create(
          const NewDevice(
            kind: DeviceKind.android,
            name: 'P',
            profile: 'pixel_7',
            image: 'system-images;x',
          ),
        ),
      );
      expect(
        parseOutcome(out).error,
        'Error: Package path is not valid. Valid system image paths are:',
      );
      expect(host.calls, [
        'avdmanager create avd -n P -k system-images;x -d pixel_7',
      ]);
    });

    test('the android catalog walks the sdk the emulator lives in', () async {
      final host = await _host();
      final sdk = '${host.root.path}/sdk';
      await Directory('$sdk/system-images/android-36/google_apis/x86_64')
          .create(recursive: true);
      await Directory('$sdk/emulator').create(recursive: true);
      await File('${host.bin}/emulator').rename('$sdk/emulator/emulator');
      final out = await host.run(
        DeviceCommands.catalog(DeviceKind.android),
        env: {'PATH': '${host.bin}:$sdk/emulator'},
      );
      final catalog = parseAndroidCatalog(out);
      expect(catalog.profiles.map((entry) => entry.id), [
        'pixel_7',
        'medium_phone',
      ]);
      expect(
        catalog.images.single.id,
        'system-images;android-36;google_apis;x86_64',
      );
    });

    test('the android catalog says when there is no avdmanager', () async {
      final host = await _host(avdmanager: false);
      final out = await host.run(DeviceCommands.catalog(DeviceKind.android));
      expect(parseAndroidCatalog(out).available, isFalse);
    });

    test('the ios catalog reads both lists', () async {
      final host = await _host(android: false, ios: true);
      final catalog = parseSimulatorCatalog(
        await host.run(DeviceCommands.catalog(DeviceKind.simulator)),
      );
      expect(catalog.images, hasLength(2));
      expect(catalog.profiles, hasLength(129));
    });
  });
}
