import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/vnc/apple_auth.dart';
import 'package:striked/platform/vnc/framebuffer.dart';
import 'package:striked/platform/vnc/keysyms.dart';
import 'package:striked/platform/vnc/rect_encoding.dart';
import 'package:striked/platform/vnc/rfb_client.dart';
import 'package:striked/platform/vnc/rfb_messages.dart';
import 'package:striked/platform/vnc/vnc_auth.dart';
import 'package:striked/platform/vnc/vnc_failure.dart';

import '../../support/vnc_channel.dart';

Uint8List expectedClientHandshake() {
  final out = <int>[
    ...'RFB 003.008\n'.codeUnits,
    Rfb.securityNone,
    1,
    ...RfbClientMessages.setPixelFormat(),
    ...RfbClientMessages.setEncodings(RectEncoding.offer),
  ];
  return Uint8List.fromList(out);
}

/// Sixteen bytes counting up, the challenge every vector below answers.
final challenge = List<int>.generate(16, (i) => i);
final appleModulus = hex('7fffffffffffffffffffffffffffffff');
final applePublic = hex('0000000000000000000000000000088b');

Uint8List expectedPasswordHandshake(String password) => Uint8List.fromList([
  ...'RFB 003.008\n'.codeUnits,
  Rfb.securityVncAuth,
  ...vncAuthResponse(password, challenge),
  1,
  ...RfbClientMessages.setPixelFormat(),
  ...RfbClientMessages.setEncodings(RectEncoding.offer),
]);

Uint8List hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

void main() {
  group('vnc authentication', () {
    // Computed outside the app: openssl des-ede3-ecb, no padding, over the challenge, keyed
    // with the mirrored password bytes three times over.
    test('an 8-character password answers the challenge as DES does', () {
      expect(
        vncAuthResponse('password', challenge),
        hex('b866924125c8eebb9debc1db61c538e2'),
      );
    });

    test('a short password is zero-padded to the key', () {
      expect(
        vncAuthResponse('pw', challenge),
        hex('858600d9af143c9e6541d3dd92a835d0'),
      );
    });

    test(
      'Apple DH returns encrypted credentials followed by its public key',
      () {
        final response = appleAuthResponse(
          username: 'luisnquin',
          password: 'secret',
          generator: 3,
          modulus: appleModulus,
          serverPublic: applePublic,
          privateKey: BigInt.from(5),
          randomBytes: Uint8List.new,
        );

        expect(response, hasLength(144));
        expect(response.sublist(128), hex('000000000000000000000000000000f3'));
        expect(
          response.sublist(0, 128),
          hex(
            '462dd13bbf2ae7c91fca518d03ba3293'
            '59e512c7d58cca13e249f23f90dd87ba'
            '59e512c7d58cca13e249f23f90dd87ba'
            '59e512c7d58cca13e249f23f90dd87ba'
            'd749ce973373ea41e673997ac94e1b19'
            '59e512c7d58cca13e249f23f90dd87ba'
            '59e512c7d58cca13e249f23f90dd87ba'
            '59e512c7d58cca13e249f23f90dd87ba',
          ),
        );
      },
    );

    test('a macOS username selects Apple DH over classic VNC auth', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
        username: 'luisnquin',
        password: 'secret',
      );
      addTearDown(client.close);

      channel.feed(
        serverHandshake(
          version: 'RFB 003.889\n',
          securityTypes: const [30, 2],
          appleGenerator: 3,
          appleModulus: appleModulus,
          applePublic: applePublic,
          name: 'rose',
        ),
      );
      final init = await client.handshake();

      expect(init.name, 'rose');
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent.sublist(0, 13), [
        ...'RFB 003.008\n'.codeUnits,
        Rfb.securityAppleDh,
      ]);
      expect(channel.sent, hasLength(13 + 144 + 1 + 20 + 20));
    });

    test('Apple DH needs an explicit screen username', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
        password: 'secret',
      );
      addTearDown(client.close);

      channel.feed(serverHandshake(securityTypes: const [30]));
      await expectLater(client.handshake(), throwsA(isA<VncUsernameNeeded>()));
    });

    test(
      'a list of VncAuth only, with a password, reaches ServerInit',
      () async {
        final channel = FakeVncChannel();
        addTearDown(channel.dispose);
        final client = RfbClient(
          incoming: channel.stream,
          outgoing: channel.sink,
          password: 'password',
        );
        addTearDown(client.close);

        channel.feed(
          serverHandshake(
            securityTypes: const [2],
            challenge: challenge,
            name: 'rose',
          ),
        );
        final init = await client.handshake();

        expect(init.name, 'rose');
        await Future<void>.delayed(Duration.zero);
        expect(channel.sent, expectedPasswordHandshake('password'));
      },
    );

    test('None is taken over VncAuth whatever the row holds', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
        password: 'password',
      );
      addTearDown(client.close);

      channel.feed(serverHandshake(securityTypes: const [2, 1]));
      await client.handshake();

      await Future<void>.delayed(Duration.zero);
      expect(channel.sent, expectedClientHandshake());
    });

    test('VncAuth without a password on the row is password needed', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
      );
      addTearDown(client.close);

      channel.feed(serverHandshake(securityTypes: const [2]));
      final failure = await client.handshake().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );

      expect(failure, isA<VncPasswordNeeded>());
      expect((failure! as VncFailure).reason('rose'), 'VNC password missing');
      expect((failure as VncFailure).detail, 'server offers 2');
    });

    test(
      'a failed SecurityResult is password rejected, with the reason',
      () async {
        final channel = FakeVncChannel();
        addTearDown(channel.dispose);
        final client = RfbClient(
          incoming: channel.stream,
          outgoing: channel.sink,
          password: 'wrong',
        );
        addTearDown(client.close);

        channel.feed(
          serverHandshake(
            securityTypes: const [2],
            challenge: challenge,
            securityResult: 1,
            reason: 'Authentication failed',
          ),
        );
        final failure = await client.handshake().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );

        expect(failure, isA<VncAuthRejected>());
        expect(
          (failure! as VncFailure).reason('rose'),
          'VNC credentials rejected',
        );
        expect((failure as VncFailure).detail, 'Authentication failed');
      },
    );

    test('a 3.3 server naming VncAuth gets the same exchange', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
        password: 'pw',
      );
      addTearDown(client.close);

      channel.feed(
        serverHandshake(
          version: 'RFB 003.003\n',
          securityTypes: const [2],
          challenge: challenge,
        ),
      );
      await client.handshake();

      await Future<void>.delayed(Duration.zero);
      expect(
        channel.sent,
        Uint8List.fromList([
          ...'RFB 003.003\n'.codeUnits,
          // 3.3 offers no choice, so none is sent back: the response follows the version line.
          ...vncAuthResponse('pw', challenge),
          1,
          ...RfbClientMessages.setPixelFormat(),
          ...RfbClientMessages.setEncodings(RectEncoding.offer),
        ]),
      );
    });
  });

  group('handshake', () {
    test('reads width, height and name, and emits the exact client bytes', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
      );
      addTearDown(client.close);

      channel.feed(serverHandshake(width: 1920, height: 1080, name: 'nyx'));
      final init = await client.handshake();

      expect(init.width, 1920);
      expect(init.height, 1080);
      expect(init.name, 'nyx');
      expect(init.pixelFormat.bitsPerPixel, 32);
      expect(init.pixelFormat.redShift, 16);
      expect(client.version, RfbVersion.v3_8);

      // Flushed through the sink's stream, so the write has to be given a turn.
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent, expectedClientHandshake());
    });

    test('asks for ZRLE, CopyRect, Raw and DesktopSize, in that order', () {
      final encodings = ByteData.sublistView(
        RfbClientMessages.setEncodings(RectEncoding.offer),
      );
      expect(encodings.getUint16(2), 4);
      expect(
        [for (var i = 0; i < 4; i++) encodings.getInt32(4 + i * 4)],
        [
          Rfb.encodingZrle,
          Rfb.encodingCopyRect,
          Rfb.encodingRaw,
          Rfb.encodingDesktopSize,
        ],
      );
    });

    test('an unknown security list is auth unsupported', () async {
      final channel = FakeVncChannel();
      addTearDown(channel.dispose);
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
      );
      addTearDown(client.close);

      channel.feed(serverHandshake(securityTypes: const [33]));

      final failure = await client.handshake().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(failure, isA<VncAuthUnsupported>());
      expect((failure! as VncFailure).reason('nyx'), 'auth unsupported');
    });

    test(
      'an empty security list is auth unsupported, with the server reason',
      () async {
        final channel = FakeVncChannel();
        addTearDown(channel.dispose);
        final client = RfbClient(
          incoming: channel.stream,
          outgoing: channel.sink,
        );
        addTearDown(client.close);

        channel.feed([
          ...'RFB 003.008\n'.codeUnits,
          0,
          ...u32(9),
          ...'too many'.codeUnits,
          // The reason string, one byte short of its length, then the byte that completes it: the
          // reader must not stop at a chunk boundary.
          '!'.codeUnitAt(0),
        ]);

        final failure = await client.handshake().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        expect(failure, isA<VncAuthUnsupported>());
        expect((failure! as VncFailure).detail, 'too many!');
      },
    );

    test('a stream that ends mid-handshake is stream closed', () async {
      final channel = FakeVncChannel();
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
      );
      addTearDown(client.close);

      channel.feed('RFB 003.0'.codeUnits);
      await channel.endStream();

      await expectLater(client.handshake(), throwsA(isA<VncStreamClosed>()));
      await channel.dispose();
    });
  });

  group('failure words', () {
    test('a refused channel is tunnel refused', () {
      final failure = asVncFailure(
        SSHChannelOpenError(1, 'administratively prohibited'),
      );
      expect(failure, isA<VncTunnelRefused>());
      expect(failure!.reason('nyx'), 'tunnel refused');
    });

    test(
      'a rejected key, an unresolved name and a dead host keep their words',
      () {
        expect(
          asVncFailure(SSHAuthFailError('no more auth methods'))!.reason('nyx'),
          'key rejected',
        );
        expect(
          asVncFailure(const SocketException('Failed host lookup: nyx'))!
              .reason('NYX'),
          'nyx unresolved',
        );
        expect(
          asVncFailure(const SocketException('Connection refused'))!
              .reason('NYX'),
          'nyx unreachable',
        );
      },
    );

    test('an error that is not the transport is left alone', () {
      expect(asVncFailure(StateError('mine')), isNull);
    });
  });

  group('framebuffer updates', () {
    Future<(FakeVncChannel, RfbClient)> live({
      int width = 8,
      int height = 4,
    }) async {
      final channel = FakeVncChannel();
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
      );
      channel.feed(serverHandshake(width: width, height: height));
      await client.handshake();
      return (channel, client);
    }

    test('a Raw rect lands its pixels and emits one frame', () async {
      final (channel, client) = await live();
      addTearDown(channel.dispose);
      addTearDown(client.close);

      final frame = client.frames.first;
      channel.feed([
        Rfb.serverFramebufferUpdate,
        ...updateHeader(1),
        ...rectHeader(
          x: 1,
          y: 1,
          width: 2,
          height: 1,
          encoding: Rfb.encodingRaw,
        ),
        // BGRX, and the X byte is deliberately zero.
        0x10, 0x20, 0x30, 0x00,
        0x40, 0x50, 0x60, 0x00,
      ]);
      unawaitedRun(client);

      final buffer = await frame;
      expect(pixelAt(buffer, 1, 1), [0x10, 0x20, 0x30, 0xFF]);
      expect(pixelAt(buffer, 2, 1), [0x40, 0x50, 0x60, 0xFF]);
      expect(pixelAt(buffer, 0, 0), [0, 0, 0, 0xFF]);
    });

    test('a CopyRect moves pixels that already landed', () async {
      final (channel, client) = await live();
      addTearDown(channel.dispose);
      addTearDown(client.close);

      final frames = client.frames.take(2).toList();
      channel.feed([
        Rfb.serverFramebufferUpdate,
        ...updateHeader(1),
        ...rectHeader(
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          encoding: Rfb.encodingRaw,
        ),
        0x11,
        0x22,
        0x33,
        0xFF,
        Rfb.serverFramebufferUpdate,
        ...updateHeader(1),
        ...rectHeader(
          x: 5,
          y: 2,
          width: 1,
          height: 1,
          encoding: Rfb.encodingCopyRect,
        ),
        ...u16(0),
        ...u16(0),
      ]);
      unawaitedRun(client);

      final buffer = (await frames).last;
      expect(pixelAt(buffer, 5, 2), [0x11, 0x22, 0x33, 0xFF]);
    });

    test(
      'a DesktopSize resizes and the next request stops being incremental',
      () async {
        final (channel, client) = await live();
        addTearDown(channel.dispose);
        addTearDown(client.close);

        final frame = client.frames.first;
        channel.feed([
          Rfb.serverFramebufferUpdate,
          ...updateHeader(1),
          ...rectHeader(
            x: 0,
            y: 0,
            width: 16,
            height: 8,
            encoding: Rfb.encodingDesktopSize,
          ),
        ]);
        unawaitedRun(client);

        final buffer = await frame;
        expect(buffer.width, 16);
        expect(buffer.height, 8);

        await Future<void>.delayed(Duration.zero);
        final before = channel.sent.length;
        await client.requestUpdate();
        await Future<void>.delayed(Duration.zero);
        final request = channel.sent.sublist(before);
        expect(request[0], Rfb.messageFramebufferUpdateRequest);
        expect(request[1], 0, reason: 'a resize invalidates every coordinate');
        expect(ByteData.sublistView(request).getUint16(6), 16);
        expect(ByteData.sublistView(request).getUint16(8), 8);
      },
    );

    test('a Bell and a ServerCutText do not derail the reader', () async {
      final (channel, client) = await live();
      addTearDown(channel.dispose);
      addTearDown(client.close);

      final frame = client.frames.first;
      channel.feed([
        Rfb.serverBell,
        Rfb.serverCutText,
        0,
        0,
        0,
        ...u32(2),
        ...'hi'.codeUnits,
        Rfb.serverFramebufferUpdate,
        ...updateHeader(1),
        ...rectHeader(
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          encoding: Rfb.encodingRaw,
        ),
        1,
        2,
        3,
        0xFF,
      ]);
      unawaitedRun(client);

      expect(pixelAt(await frame, 0, 0), [1, 2, 3, 0xFF]);
    });

    test('an unknown message type stops the pump with a reason', () async {
      final (channel, client) = await live();
      addTearDown(channel.dispose);
      addTearDown(client.close);

      final error = client.frames.first.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      channel.feed([200]);
      unawaitedRun(client);

      expect(await error, isA<VncStreamClosed>());
    });
  });

  group('input', () {
    Future<(FakeVncChannel, RfbClient)> live() async {
      final channel = FakeVncChannel();
      final client = RfbClient(
        incoming: channel.stream,
        outgoing: channel.sink,
      );
      channel.feed(serverHandshake(width: 8, height: 4));
      await client.handshake();
      await Future<void>.delayed(Duration.zero);
      return (channel, client);
    }

    test(
      'a letter, ENTER, ESC and a sticky CTRL each write one KeyEvent',
      () async {
        final (channel, client) = await live();
        addTearDown(channel.dispose);
        addTearDown(client.close);

        final before = channel.sent.length;
        // What the strip does for a CTRL-held letter: modifier down, key down, key up, modifier
        // up.
        client
          ..sendKey(Keysyms.control, down: true)
          ..sendKey(Keysyms.forCharacter('c'), down: true)
          ..sendKey(Keysyms.forCharacter('c'), down: false)
          ..sendKey(Keysyms.control, down: false)
          ..sendKey(Keysyms.enter, down: true)
          ..sendKey(Keysyms.enter, down: false)
          ..sendKey(Keysyms.escape, down: true)
          ..sendKey(Keysyms.escape, down: false);
        await Future<void>.delayed(Duration.zero);

        final written = channel.sent.sublist(before);
        expect(written.length, 8 * 8);
        expect(keyEvents(written), [
          (Keysyms.control, true),
          (0x63, true),
          (0x63, false),
          (Keysyms.control, false),
          (Keysyms.enter, true),
          (Keysyms.enter, false),
          (Keysyms.escape, true),
          (Keysyms.escape, false),
        ]);
      },
    );

    test(
      'a character outside Latin-1 goes through the Unicode keysym range',
      () {
        expect(Keysyms.forCharacter('a'), 0x61);
        expect(Keysyms.forCharacter('ñ'), 0xF1);
        expect(Keysyms.forCharacter('€'), 0x010020AC);
      },
    );

    test(
      'a PointerEvent carries the button mask and clamps to the screen',
      () async {
        final (channel, client) = await live();
        addTearDown(channel.dispose);
        addTearDown(client.close);

        final before = channel.sent.length;
        client
          ..sendPointer(x: 3, y: 2, buttonMask: RfbButtons.left)
          ..sendPointer(x: 900, y: 900, buttonMask: RfbButtons.none);
        await Future<void>.delayed(Duration.zero);

        final written = channel.sent.sublist(before);
        final first = ByteData.sublistView(written, 0, 6);
        expect(first.getUint8(0), Rfb.messagePointerEvent);
        expect(first.getUint8(1), RfbButtons.left);
        expect(first.getUint16(2), 3);
        expect(first.getUint16(4), 2);

        final second = ByteData.sublistView(written, 6, 12);
        expect(
          second.getUint16(2),
          7,
          reason: 'the last column of an 8px screen',
        );
        expect(second.getUint16(4), 3);
      },
    );
  });
}

/// Nothing awaits it, and its errors are read off [RfbClient.frames].
void unawaitedRun(RfbClient client) {
  client.run().ignore();
}

List<int> pixelAt(Framebuffer buffer, int x, int y) {
  final at = buffer.offsetOf(x, y);
  return buffer.pixels.sublist(at, at + 4);
}

List<(int, bool)> keyEvents(Uint8List written) {
  final data = ByteData.sublistView(written);
  return [
    for (var at = 0; at < written.length; at += 8)
      (data.getUint32(at + 4), data.getUint8(at + 1) == 1),
  ];
}
