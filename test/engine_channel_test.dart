import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';
import 'package:upgrade/platform/shell/udp_path.dart';
import 'package:flutter_test/flutter_test.dart';

final _key = MoshKey(Uint8List.fromList(List.generate(16, (i) => i * 7)));

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

EngineServerPacket _data(
  int offset,
  List<int> bytes, {
  bool jump = false,
  int inputAck = 0,
}) => EngineServerPacket(
  jump: jump,
  timestamp: 0,
  inputAck: inputAck,
  sizeGen: 0,
  streamEnd: offset + bytes.length,
  offset: offset,
  data: Uint8List.fromList(bytes),
);

class FakeEngineServer {
  FakeEngineServer._(this.socket, this.cipher) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!.data;
        if (engineFromServer(packet)) continue;
        final client = EngineClientPacket.decode(cipher.decrypt(packet));
        if (client == null) continue;
        clientAddress = datagram.address;
        clientPort = datagram.port;
        ports.add(datagram.port);
        received.add(client);
      }
    });
  }

  static Future<FakeEngineServer> bind() async => FakeEngineServer._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    MoshPacketCipher.aesOcb(_key),
  );

  final RawDatagramSocket socket;
  final MoshPacketCipher cipher;
  final received = StreamController<EngineClientPacket>.broadcast();
  final ports = <int>{};
  InternetAddress? clientAddress;
  int? clientPort;
  int _sequence = 0;
  int lastTimestamp = engineNoTimestamp;

  int get port => socket.port;

  void send(EngineServerPacket packet) {
    final sealed = sealEngineServerPacket(
      cipher,
      _sequence++,
      EngineServerPacket(
        jump: packet.jump,
        timestamp: 0,
        timestampReply: lastTimestamp,
        inputAck: packet.inputAck,
        sizeGen: packet.sizeGen,
        streamEnd: packet.streamEnd,
        offset: packet.offset,
        data: packet.data,
      ).encode(),
    );
    socket.send(sealed, clientAddress!, clientPort!);
  }

  Future<EngineClientPacket> next(bool Function(EngineClientPacket) test) =>
      received.stream
          .firstWhere((packet) {
            lastTimestamp = packet.timestamp;
            return test(packet);
          })
          .timeout(const Duration(seconds: 5));

  void close() {
    socket.close();
    unawaited(received.close());
  }
}

class RefusingSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  RefusingSocket(this._inner, {required this.refusing}) {
    _inner.listen(
      _stream.add,
      onError: _stream.addError,
      onDone: _stream.close,
    );
  }

  final RawDatagramSocket _inner;
  final _stream = StreamController<RawSocketEvent>();
  bool refusing;
  var closed = false;
  var sendsAfterClose = 0;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed) {
      sendsAfterClose++;
      return 0;
    }
    if (!refusing) return _inner.send(buffer, address, port);
    scheduleMicrotask(() {
      _stream.addError(
        const SocketException(
          'Send failed',
          osError: OSError('Operation not permitted', 1),
          port: 0,
        ),
      );
      close();
    });
    return 0;
  }

  @override
  void close() {
    closed = true;
    _inner.close();
  }

  @override
  Datagram? receive() => _inner.receive();

  @override
  int get port => _inner.port;

  @override
  InternetAddress get address => _inner.address;

  @override
  bool get readEventsEnabled => _inner.readEventsEnabled;

  @override
  set readEventsEnabled(bool value) => _inner.readEventsEnabled = value;

  @override
  bool get writeEventsEnabled => _inner.writeEventsEnabled;

  @override
  set writeEventsEnabled(bool value) => _inner.writeEventsEnabled = value;

  @override
  bool get multicastLoopback => _inner.multicastLoopback;

  @override
  set multicastLoopback(bool value) => _inner.multicastLoopback = value;

  @override
  int get multicastHops => _inner.multicastHops;

  @override
  set multicastHops(int value) => _inner.multicastHops = value;

  @override
  NetworkInterface? get multicastInterface => null;

  @override
  set multicastInterface(NetworkInterface? value) {}

  @override
  bool get broadcastEnabled => _inner.broadcastEnabled;

  @override
  set broadcastEnabled(bool value) => _inner.broadcastEnabled = value;

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) =>
      _inner.joinMulticast(group, interface);

  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface]) =>
      _inner.leaveMulticast(group, interface);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}

void main() {
  group('packets', () {
    test('a client packet is laid out as wire.rs lays it out', () {
      final packet = EngineClientPacket(
        timestamp: 1,
        ack: 9,
        keyframe: 2,
        sizeGen: 3,
        size: const EngineSize(80, 24, widthPx: 800, heightPx: 480),
        inputOffset: 4,
        input: _bytes('ls\r'),
      );
      final bytes = packet.encode();

      expect(bytes, [
        ...[1, 1, 0, 1, 0xff, 0xff],
        ...[0, 0, 0, 0, 0, 0, 0, 9],
        ...[0, 0, 0, 2, 0, 0, 0, 3],
        ...[0, 80, 0, 24, 3, 32, 1, 224],
        ...[0, 0, 0, 0, 0, 0, 0, 4],
        ...[0x6c, 0x73, 0x0d],
      ]);
      final decoded = EngineClientPacket.decode(bytes)!;
      expect(decoded.ack, 9);
      expect(
        decoded.size,
        const EngineSize(80, 24, widthPx: 800, heightPx: 480),
      );
      expect(decoded.inputOffset, 4);
      expect(decoded.input, _bytes('ls\r'));
      expect(decoded.close, isFalse);
    });

    test('headers are 30 and 26 bytes, and input fits the plaintext cap', () {
      final bare = EngineClientPacket(
        close: true,
        timestamp: 0,
        ack: 0,
        keyframe: 1,
        sizeGen: 0,
        size: const EngineSize(1, 1),
      ).encode();
      expect(bare.length, engineClientHeader);
      expect(bare[1], 2);
      expect(
        const EngineServerPacket(
          timestamp: 0,
          inputAck: 0,
          sizeGen: 0,
          streamEnd: 0,
        ).encode().length,
        engineServerHeader,
      );
      expect(engineMaxInput, 1162);
      expect(engineMaxData, 1166);
    });

    test('a server packet round trips with its jump and data', () {
      final packet = EngineServerPacket(
        jump: true,
        timestamp: 5,
        timestampReply: 6,
        inputAck: 7,
        sizeGen: 3,
        streamEnd: 100,
        offset: 90,
        data: Uint8List.fromList([1, 2, 3]),
      );
      final decoded = EngineServerPacket.decode(packet.encode())!;
      expect(decoded.jump, isTrue);
      expect(decoded.timestampReply, 6);
      expect(decoded.inputAck, 7);
      expect(decoded.streamEnd, 100);
      expect(decoded.offset, 90);
      expect(decoded.data, [1, 2, 3]);
    });

    test('a different version is no packet', () {
      final bytes = const EngineServerPacket(
        timestamp: 0,
        inputAck: 0,
        sizeGen: 0,
        streamEnd: 0,
      ).encode()..[0] = 2;
      expect(EngineServerPacket.decode(bytes), isNull);
      expect(EngineServerPacket.decode(Uint8List(10)), isNull);
    });

    test('a server packet is sealed with bit 63 and opens with the Mosh '
        'cipher', () {
      final cipher = MoshPacketCipher.aesOcb(_key);
      final sealed = sealEngineServerPacket(cipher, 5, _bytes('hello'));

      expect(sealed.sublist(0, 8), [0x80, 0, 0, 0, 0, 0, 0, 5]);
      expect(engineFromServer(sealed), isTrue);
      expect(MoshNonce.fromWire(sealed.sublist(0, 8)).sequence, 5);
      expect(cipher.decrypt(sealed), _bytes('hello'));

      final mine = cipher.encrypt(nonce: 5, plaintext: _bytes('hello'));
      expect(engineFromServer(mine), isFalse);
      sealed[sealed.length - 1] ^= 1;
      expect(() => cipher.decrypt(sealed), throwsA(anything));
    });
  });

  group('records', () {
    test('records reassemble across packets split at every byte', () {
      final stream = [
        ...engineRecord(1, _bytes('hi')),
        ...engineRecord(2, _bytes('GHOSTSNP')),
        ...engineRecord(1, const []),
        ...engineRecord(3, [0xff, 0xff, 0xff, 0xf1]),
      ];
      final reader = EngineRecordReader();
      final events = <EngineEvent>[];
      for (final byte in stream) {
        events.addAll(reader.add(Uint8List.fromList([byte])));
      }

      expect(events, hasLength(4));
      expect((events[0] as EnginePty).bytes, _bytes('h'));
      expect((events[1] as EnginePty).bytes, _bytes('i'));
      expect((events[2] as EngineSnapshot).bytes, _bytes('GHOSTSNP'));
      expect((events[3] as EngineExit).status, -15);
    });

    test('an unknown kind is skipped whole', () {
      final reader = EngineRecordReader();
      final events = reader.add(
        Uint8List.fromList([
          ...engineRecord(9, _bytes('later')),
          ...engineRecord(1, _bytes('ok')),
        ]),
      );
      expect(events.single, isA<EnginePty>());
      expect((events.single as EnginePty).bytes, _bytes('ok'));
    });
  });

  group('the receiver', () {
    test('a fresh client waits for its keyframe and takes it at any '
        'offset', () {
      final receiver = EngineReceiver();
      final early = engineRecord(1, _bytes('early'));
      expect(receiver.take(_data(0, early)), isEmpty);
      expect(receiver.ack, 0);

      final frame = [
        ...engineRecord(2, _bytes('SNAP')),
        ...engineRecord(1, _bytes('x')),
      ];
      final events = receiver.take(_data(500, frame, jump: true));
      expect(events.map((event) => event.runtimeType), [
        EngineSnapshot,
        EnginePty,
      ]);
      expect(receiver.ack, 500 + frame.length);
      expect(receiver.awaitingKeyframe, isFalse);
    });

    test('data is taken only at the ack, and an overlap only past it', () {
      final receiver = EngineReceiver(awaitingKeyframe: false);
      final record = engineRecord(1, _bytes('abcdef'));

      final first = receiver.take(_data(0, record.sublist(0, 7)));
      expect((first.single as EnginePty).bytes, _bytes('ab'));
      expect(receiver.take(_data(0, record.sublist(0, 7))), isEmpty);
      final rest = receiver.take(_data(5, record.sublist(5)));
      expect((rest.single as EnginePty).bytes, _bytes('cdef'));
      expect(receiver.ack, record.length);
    });

    test('data ahead of a hole is held and delivered once the hole '
        'fills', () {
      final receiver = EngineReceiver(awaitingKeyframe: false);
      final one = engineRecord(1, _bytes('one'));
      final two = engineRecord(1, _bytes('two'));
      final three = engineRecord(1, _bytes('three'));
      final at2 = one.length;
      final at3 = at2 + two.length;

      expect(receiver.take(_data(at3, three)), isEmpty);
      expect(receiver.take(_data(at2, two)), isEmpty);
      expect(receiver.ack, 0);

      final events = receiver.take(_data(0, one));
      expect(events.map((event) => (event as EnginePty).bytes), [
        _bytes('one'),
        _bytes('two'),
        _bytes('three'),
      ]);
      expect(receiver.ack, at3 + three.length);
    });

    test('data held ahead of a keyframe survives the keyframe, and data '
        'behind it is dropped', () {
      final receiver = EngineReceiver();
      final stale = engineRecord(1, _bytes('stale'));
      final frame = engineRecord(2, _bytes('SNAP'));
      final after = engineRecord(1, _bytes('after'));

      expect(receiver.take(_data(10, stale)), isEmpty);
      expect(receiver.take(_data(100 + frame.length, after)), isEmpty);

      final events = receiver.take(_data(100, frame, jump: true));
      expect(events.map((event) => event.runtimeType), [
        EngineSnapshot,
        EnginePty,
      ]);
      expect((events.last as EnginePty).bytes, _bytes('after'));
      expect(receiver.ack, 100 + frame.length + after.length);
    });

    test('a jump drops the partial record and parses fresh', () {
      final receiver = EngineReceiver(awaitingKeyframe: false);
      final cut = engineRecord(2, _bytes('half a snapshot'));
      expect(receiver.take(_data(0, cut.sublist(0, 8))), isEmpty);
      expect(receiver.ack, 8);

      final fresh = engineRecord(2, _bytes('SNAP'));
      final events = receiver.take(_data(40, fresh, jump: true));
      expect((events.single as EngineSnapshot).bytes, _bytes('SNAP'));
      expect(receiver.ack, 40 + fresh.length);

      expect(receiver.take(_data(40, fresh, jump: true)), isEmpty);
    });
  });

  group('the outbox', () {
    test('chunks to the cap, drops what is acked and rewinds to it', () {
      final outbox = EngineOutbox()
        ..add(Uint8List(2000))
        ..add(_bytes('ls'));
      final (first, a) = outbox.next()!;
      final (second, b) = outbox.next()!;
      expect((first, a.length), (0, engineMaxInput));
      expect((second, b.length), (engineMaxInput, 2002 - engineMaxInput));
      expect(outbox.next(), isNull);
      expect(outbox.inFlight, isTrue);

      outbox.acknowledge(1000);
      expect(outbox.base, 1000);
      outbox.rewind();
      final (again, c) = outbox.next()!;
      expect((again, c.length), (1000, 1002));
      expect(c.sublist(c.length - 2), _bytes('ls'));

      outbox.acknowledge(2002);
      expect(outbox.inFlight, isFalse);
      expect(outbox.unsent, isFalse);
    });
  });

  group('over UDP', () {
    late FakeEngineServer server;
    late UdpEngineChannel channel;

    setUp(() async {
      server = await FakeEngineServer.bind();
      channel = UdpEngineChannel(
        address: InternetAddress.loopbackIPv4,
        port: server.port,
        cipher: MoshPacketCipher.aesOcb(_key),
        size: const EngineSize(100, 40),
      );
    });

    tearDown(() async {
      await channel.close();
      server.close();
    });

    test('asks for a keyframe, takes it across packets, and resends input '
        'the server lost', () async {
      final events = <EngineEvent>[];
      channel.events.listen(events.add);

      final hello = server.next((_) => true);
      await channel.start();
      final first = await hello;
      expect(first.keyframe, channel.keyframe);
      expect(first.keyframe, isNot(0));
      expect(first.ack, 0);
      expect(first.size, const EngineSize(100, 40));
      expect(first.sizeGen, 1);
      expect(first.timestamp, isNot(engineNoTimestamp));

      final stream = Uint8List.fromList([
        ...engineRecord(2, _bytes('GHOSTSNP')),
        ...engineRecord(1, _bytes('\$ ')),
      ]);
      final acked = server.next((packet) => packet.ack == 20 + stream.length);
      server.send(_data(20, stream.sublist(0, 6), jump: true));
      server.send(_data(26, stream.sublist(6)));
      await acked;
      expect(events.map((event) => event.runtimeType), [
        EngineSnapshot,
        EnginePty,
      ]);

      final lost = server.next((packet) => packet.input != null);
      channel.send(_bytes('ls\r'));
      final dropped = await lost;
      expect(dropped.inputOffset, 0);
      final again = await server.next((packet) => packet.input != null);
      expect(again.inputOffset, 0);
      expect(again.input, _bytes('ls\r'));

      server.send(
        EngineServerPacket(
          timestamp: 0,
          inputAck: 3,
          sizeGen: 0,
          streamEnd: 20 + stream.length,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final more = server.next((packet) => packet.input != null);
      channel.send(_bytes('q'));
      final next = await more;
      expect(next.inputOffset, 3);
      expect(next.input, _bytes('q'));
    });

    test(
      'input waits for the first server packet and starts at its input_ack',
      () async {
        final hello = server.next((_) => true);
        await channel.start();
        await hello;
        var inputs = 0;
        final counting = server.received.stream.listen((packet) {
          if (packet.input != null) inputs++;
        });
        channel.send(_bytes('ls\r'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(inputs, 0);

        final queued = server.next((packet) => packet.input != null);
        server.send(_data(0, const [], jump: true, inputAck: 500));
        final first = await queued;
        expect(first.inputOffset, 500);
        expect(first.input, _bytes('ls\r'));
        await counting.cancel();
      },
    );

    test('a channel resumed from a closed one keeps its keyframe id, its '
        'place mid-record and its unconfirmed input', () async {
      final events = <EngineEvent>[];
      channel.events.listen(events.add);
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final stream = Uint8List.fromList([
        ...engineRecord(2, _bytes('SNAP')),
        ...engineRecord(1, _bytes('hello')),
      ]);
      final split = stream.length - 3;
      final acked = server.next((packet) => packet.ack == 20 + split);
      server.send(_data(20, stream.sublist(0, split), jump: true));
      await acked;
      final typed = server.next((packet) => packet.input != null);
      channel.send(_bytes('x'));
      await typed;
      await channel.close();
      final state = channel.resumable!;
      expect(state.emitted, events.length);

      final next = UdpEngineChannel(
        address: InternetAddress.loopbackIPv4,
        port: server.port,
        cipher: MoshPacketCipher.aesOcb(_key),
        size: const EngineSize(100, 40),
        resume: state,
      );
      addTearDown(next.close);
      expect(next.keyframe, channel.keyframe);
      final carried = <EngineEvent>[];
      next.events.listen(carried.add);
      final again = server.next((_) => true);
      await next.start();
      expect((await again).ack, 20 + split);

      final resent = server.next((packet) => packet.input != null);
      server.send(_data(20 + split, stream.sublist(split)));
      final input = await resent;
      expect(input.inputOffset, 0);
      expect(input.input, _bytes('x'));
      expect(carried.single, isA<EnginePty>());
      expect((carried.single as EnginePty).bytes, _bytes('llo'));
    });

    test('a resumed channel renumbers what it kept from the server\'s input '
        'ack when that ack is past it all', () async {
      final outbox = EngineOutbox()..add(_bytes('ab'));
      final next = UdpEngineChannel(
        address: InternetAddress.loopbackIPv4,
        port: server.port,
        cipher: MoshPacketCipher.aesOcb(_key),
        size: const EngineSize(100, 40),
        resume: EngineResume(
          keyframe: 7,
          receiver: EngineReceiver(awaitingKeyframe: false),
          outbox: outbox,
          emitted: 0,
        ),
      );
      addTearDown(next.close);
      final hello = server.next((_) => true);
      await next.start();
      await hello;
      final typed = server.next((packet) => packet.input != null);
      server.send(
        EngineServerPacket(
          jump: false,
          timestamp: 0,
          timestampReply: engineNoTimestamp,
          inputAck: 50,
          sizeGen: 1,
          streamEnd: 0,
        ),
      );
      final input = await typed;
      expect(input.inputOffset, 50);
      expect(input.input, _bytes('ab'));
    });

    test(
      'a channel that never got its keyframe leaves nothing to resume',
      () async {
        await channel.start();
        await channel.close();
        expect(channel.resumable, isNull);
      },
    );

    test('two channels never ask for the same keyframe', () {
      final ids = {
        for (var i = 0; i < 64; i++)
          UdpEngineChannel(
            address: InternetAddress.loopbackIPv4,
            port: 1,
            cipher: MoshPacketCipher.aesOcb(_key),
            size: const EngineSize(1, 1),
          ).keyframe,
      };
      expect(ids, hasLength(64));
      expect(ids, isNot(contains(0)));
    });

    group('before the first packet', () {
      late UdpEngineChannel probe;

      setUp(() {
        probe = UdpEngineChannel(
          address: InternetAddress.loopbackIPv4,
          port: server.port,
          cipher: MoshPacketCipher.aesOcb(_key),
          size: const EngineSize(100, 40),
          firstResend: const Duration(milliseconds: 40),
          contactWindow: const Duration(milliseconds: 600),
          contactTries: 1,
        );
      });

      tearDown(() => probe.close());

      test('the hello is resent at a doubling interval, and an unanswered '
          'window is silent', () async {
        final watch = Stopwatch()..start();
        final arrivals = <int>[];
        final counting = server.received.stream.listen(
          (_) => arrivals.add(watch.elapsedMilliseconds),
        );
        await probe.start();

        await expectLater(
          probe.firstContact,
          throwsA(
            isA<UdpSilent>()
                .having((silent) => silent.port, 'port', server.port)
                .having(
                  (silent) => silent.window,
                  'window',
                  const Duration(milliseconds: 600),
                ),
          ),
        );
        await counting.cancel();
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(arrivals.length, inInclusiveRange(4, 6));
        final gaps = [
          for (var i = 1; i < arrivals.length; i++)
            arrivals[i] - arrivals[i - 1],
        ];
        expect(gaps[2], greaterThan(gaps[0]));
      });

      test('a window missed is tried again from a fresh socket before it '
          'is silent', () async {
        final retry = UdpEngineChannel(
          address: InternetAddress.loopbackIPv4,
          port: server.port,
          cipher: MoshPacketCipher.aesOcb(_key),
          size: const EngineSize(100, 40),
          contactWindow: const Duration(milliseconds: 200),
        );
        addTearDown(retry.close);
        final hello = server.next((_) => true);
        await retry.start();
        await hello;
        final first = server.clientPort;

        final moved = server.next((_) => server.clientPort != first);
        await moved;
        server.send(_data(0, Uint8List(0)));
        await retry.firstContact.timeout(const Duration(seconds: 2));
        expect(server.ports, hasLength(2));
      });

      test('one packet heard is contact, and the window passing after it '
          'changes nothing', () async {
        final hello = server.next((_) => true);
        await probe.start();
        await hello;
        server.send(_data(0, Uint8List(0)));

        await probe.firstContact.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await expectLater(probe.firstContact, completes);
      });
    });

    test('a resize bumps the generation and goes at once', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final resized = server.next((packet) => packet.sizeGen == 2);
      channel.resize(91, 37, widthPx: 1820, heightPx: 1554);
      expect(
        (await resized).size,
        const EngineSize(91, 37, widthPx: 1820, heightPx: 1554),
      );

      channel.resize(91, 37, widthPx: 1820, heightPx: 1554);
      final measured = server.next((packet) => packet.sizeGen != 2);
      channel.resize(91, 37, widthPx: 1911, heightPx: 1591);
      final next = await measured;
      expect(next.sizeGen, 3);
      expect(
        next.size,
        const EngineSize(91, 37, widthPx: 1911, heightPx: 1591),
      );
    });

    group('when the system refuses a send', () {
      late List<RefusingSocket> sockets;
      late List<Object> errors;
      late UdpEngineChannel refused;

      void open({required int refusing}) {
        sockets = [];
        errors = [];
        refused = UdpEngineChannel(
          address: InternetAddress.loopbackIPv4,
          port: server.port,
          cipher: MoshPacketCipher.aesOcb(_key),
          size: const EngineSize(100, 40),
          heartbeat: const Duration(milliseconds: 50),
          binder: (host, port) async {
            final socket = RefusingSocket(
              await RawDatagramSocket.bind(host, port),
              refusing: sockets.length < refusing,
            );
            sockets.add(socket);
            return socket;
          },
        );
        refused.errors.listen(errors.add);
        addTearDown(refused.close);
      }

      test('it says so once, binds again on the next tick, and never writes '
          'into the closed socket', () async {
        open(refusing: 3);
        final hello = server.next((_) => true);
        await refused.start();
        await hello;

        expect(sockets, hasLength(4));
        expect(sockets.take(3).every((socket) => socket.closed), isTrue);
        expect(
          sockets.map((socket) => socket.sendsAfterClose),
          everyElement(0),
        );
        expect(errors, hasLength(1));
        expect((errors.single as SocketException).osError?.errorCode, 1);
      });

      test('input typed while the socket is down goes out on the next one, '
          'and the stream goes on', () async {
        open(refusing: 0);
        final hello = server.next((_) => true);
        await refused.start();
        await hello;
        final ok = engineRecord(1, _bytes('ok'));
        final synced = server.next((packet) => packet.ack == ok.length);
        server.send(_data(0, ok, jump: true));
        await synced;

        sockets.single.refusing = true;
        final typed = server.next((packet) => packet.input != null);
        refused.send(_bytes('ls\n'));
        final packet = await typed;

        expect(packet.input, _bytes('ls\n'));
        expect(server.ports, hasLength(2));
        expect(sockets.first.sendsAfterClose, 0);
        expect(errors, hasLength(1));

        final ptys = refused.events
            .expand((event) => [if (event is EnginePty) event.bytes])
            .take(2)
            .toList();
        server.send(_data(ok.length, engineRecord(1, _bytes('ls'))));
        expect(await ptys, [_bytes('ok'), _bytes('ls')]);
      });
    });

    test('a record that lands before anyone listens waits for them', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final record = engineRecord(2, _bytes('SNAP'));
      final acked = server.next((packet) => packet.ack == record.length);
      server.send(_data(0, record, jump: true));
      await acked;

      final first = await channel.events.first;
      expect((first as EngineSnapshot).bytes, _bytes('SNAP'));
    });

    test('an exit record ends with the status', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final exit = channel.events.firstWhere((event) => event is EngineExit);
      server.send(_data(0, engineRecord(3, [0, 0, 0, 0]), jump: true));
      expect(((await exit) as EngineExit).status, 0);
    });

    test('a rehome speaks from a new socket and keeps the stream', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final first = server.clientPort;
      final record = engineRecord(1, _bytes('one'));
      final acked = server.next((packet) => packet.ack == record.length);
      server.send(_data(0, record, jump: true));
      await acked;

      final moved = server.next((packet) => server.clientPort != first);
      await channel.rehome();
      final packet = await moved;
      expect(packet.ack, record.length);
      expect(packet.keyframe, channel.keyframe);
      expect(server.ports, hasLength(2));

      final ptys = channel.events
          .expand((event) => [if (event is EnginePty) event.bytes])
          .take(2)
          .toList();
      server.send(_data(record.length, engineRecord(1, _bytes('two'))));
      expect(await ptys, [_bytes('one'), _bytes('two')]);
    });

    test('a suspended channel sends nothing until it is rehomed', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final synced = channel.contacts.first;
      server.send(_data(0, const [], jump: true));
      await synced;
      await channel.suspend();
      var heard = 0;
      final counting = server.received.stream.listen((_) => heard++);
      channel.send(_bytes('x'));
      channel.poke();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(heard, 0);
      final back = server.next((packet) => packet.input != null);
      await channel.rehome();
      expect((await back).input, _bytes('x'));
      await counting.cancel();
    });

    test('closing with end sends the close flag', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      final closing = server.next((packet) => packet.close);
      await channel.close(end: true);
      expect((await closing).close, isTrue);
    });

    test('a packet in the phone\'s own direction is dropped', () async {
      final hello = server.next((_) => true);
      await channel.start();
      await hello;
      var contacts = 0;
      channel.contacts.listen((_) => contacts++);
      final forged = server.cipher.encrypt(
        nonce: 1,
        plaintext: _data(0, engineRecord(1, _bytes('x')), jump: true).encode(),
      );
      server.socket.send(forged, server.clientAddress!, server.clientPort!);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(contacts, 0);
    });
  });
}
