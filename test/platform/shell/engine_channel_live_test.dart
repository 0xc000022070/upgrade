import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';
import 'package:upgrade/platform/shell/udp_path.dart';
import 'package:flutter_test/flutter_test.dart';

final _binary = Platform.environment['UPGRADED_BIN'];

const _patience = Duration(seconds: 10);
const _size = EngineSize(80, 24, widthPx: 800, heightPx: 480);

String? get _skip {
  final binary = _binary;
  if (binary == null || binary.isEmpty) return 'UPGRADED_BIN is not set';
  final stat = FileStat.statSync(binary);
  if (stat.type != FileSystemEntityType.file || stat.mode & 0x49 == 0) {
    return 'UPGRADED_BIN is not an executable: $binary';
  }
  return null;
}

class _Sandbox {
  _Sandbox(this.root);

  final Directory root;
  late final String owner;

  Map<String, String> get _environment => {
    for (final entry in Platform.environment.entries)
      if (entry.key != 'UPGRADED_CONFIG') entry.key: entry.value,
    'UPGRADED_STATE': '${root.path}/state',
    'HOME': '${root.path}/home',
    'XDG_CONFIG_HOME': '${root.path}/home/config',
  };

  static Future<_Sandbox> create() async {
    final root = await Directory.systemTemp.createTemp('upgraded-live-');
    await Directory('${root.path}/state').create();
    await Directory('${root.path}/home').create();
    final sandbox = _Sandbox(root);
    final probe = await sandbox.raw({'service': 'lifecycle', 'op': 'probe'});
    final result = probe['result'] as Map<String, Object?>;
    sandbox.owner = result['owner'] as String;
    return sandbox;
  }

  Future<Map<String, Object?>> raw(Map<String, Object?> request) async {
    final process = await Process.start(
      _binary!,
      const [],
      environment: _environment,
      includeParentEnvironment: false,
    );
    process.stdin.write(jsonEncode(request));
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    expect(code, 0, reason: await err);
    return jsonDecode(await out) as Map<String, Object?>;
  }

  Future<Map<String, Object?>> shell(
    String op,
    Map<String, Object?> args,
  ) async {
    final answer = await raw({
      'service': 'shell/1',
      'op': op,
      'owner': owner,
      'args': args,
    });
    expect(answer['ok'], isTrue, reason: '$answer');
    return answer['result'] as Map<String, Object?>;
  }

  Future<Map<String, Object?>> start(String tab) => shell('start', {
    'tab': tab,
    'cols': _size.cols,
    'rows': _size.rows,
    'width_px': _size.widthPx,
    'height_px': _size.heightPx,
    'command': ['/bin/sh'],
  });

  Future<List<Object?>> shells() async =>
      (await shell('list', {}))['shells'] as List<Object?>;

  Future<void> teardown() async {
    try {
      await raw({'service': 'lifecycle', 'op': 'teardown', 'owner': owner});
    } finally {
      await root.delete(recursive: true);
    }
  }
}

class _Tap {
  _Tap(this.channel) {
    _subscription = channel.events.listen((event) {
      events.add(event);
      if (event is EnginePty) {
        _text.write(utf8.decode(event.bytes, allowMalformed: true));
      }
    });
  }

  final EngineChannel channel;
  final events = <EngineEvent>[];
  final _text = StringBuffer();
  late final StreamSubscription<EngineEvent> _subscription;

  String get text => _text.toString();

  Future<void> until(String what, bool Function() done) async {
    final deadline = DateTime.now().add(_patience);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('never saw $what; pty so far: ${jsonEncode(text)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void type(String text) => channel.send(utf8.encode(text));

  Future<void> cancel() => _subscription.cancel();
}

Future<_Tap> _dial(Map<String, Object?> started) async {
  final channel = UdpEngineChannel(
    address: InternetAddress.loopbackIPv4,
    port: started['port']! as int,
    cipher: MoshPacketCipher.aesOcb(MoshKey.parse(started['key']! as String)),
    size: _size,
  );
  await channel.start();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return _Tap(channel);
}

void main() {
  test(
    'the phone channel drives a real engine shell end to end',
    () async {
      final sandbox = await _Sandbox.create();
      addTearDown(sandbox.teardown);
      final tab = 'live${pid.toRadixString(36)}';

      final started = await sandbox.start(tab);
      expect(started['resumed'], isFalse);
      final tap = await _dial(started);
      final first = tap.channel;
      addTearDown(first.close);
      addTearDown(tap.cancel);

      await tap.until('a first record', () => tap.events.isNotEmpty);
      expect(tap.events.first, isA<EngineSnapshot>());

      tap.type('echo hi-\$((40+2))\n');
      await tap.until('hi-42', () => tap.text.contains('hi-42'));

      first.resize(100, 30, widthPx: 1000, heightPx: 600);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      tap.type('stty size\n');
      await tap.until('30 100', () => tap.text.contains('30 100'));

      tap.type(
        "printf '\\033_Ga=T,f=24,s=1,v=1,i=7;AAAA\\033\\\\'; "
        'echo done-\$((1+1))\n',
      );
      await tap.until('done-2', () => tap.text.contains('done-2'));
      await tap.cancel();
      await first.close();

      final resumed = await sandbox.start(tab);
      expect(resumed['resumed'], isTrue);
      expect(resumed['key'], isNot(started['key']));
      final again = await _dial(resumed);
      final second = again.channel;
      addTearDown(second.close);
      addTearDown(again.cancel);
      await again.until(
        'the keyframe and its images',
        () => again.events.length >= 2,
      );
      expect(again.events[0], isA<EngineSnapshot>());
      final images = again.events[1];
      expect(images, isA<EnginePty>());
      expect(utf8.decode((images as EnginePty).bytes), contains('i=7'));

      await second.close(end: true);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await sandbox.shells()).isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the shell outlived close(end): ${await sandbox.shells()}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a started shell behind a port nothing answers on is silent inside the '
    'window, and its own port is not',
    () async {
      final sandbox = await _Sandbox.create();
      addTearDown(sandbox.teardown);
      final started = await sandbox.start('mute${pid.toRadixString(36)}');
      final cipher = MoshPacketCipher.aesOcb(
        MoshKey.parse(started['key']! as String),
      );
      const window = Duration(milliseconds: 1500);

      final vacant = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final nobody = vacant.port;
      vacant.close();
      final deaf = UdpEngineChannel(
        address: InternetAddress.loopbackIPv4,
        port: nobody,
        cipher: cipher,
        size: _size,
        contactWindow: window,
      );
      addTearDown(deaf.close);
      final watch = Stopwatch()..start();
      await deaf.start();
      await expectLater(
        deaf.firstContact,
        throwsA(
          isA<UdpSilent>()
              .having((silent) => silent.port, 'port', nobody)
              .having(
                (silent) => '$silent',
                'verdict',
                contains('after 1500ms'),
              ),
        ),
      );
      expect(watch.elapsed, lessThan(window * 2));

      final heard = UdpEngineChannel(
        address: InternetAddress.loopbackIPv4,
        port: started['port']! as int,
        cipher: cipher,
        size: _size,
        contactWindow: window,
      );
      addTearDown(heard.close);
      await heard.start();
      await heard.firstContact;
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
