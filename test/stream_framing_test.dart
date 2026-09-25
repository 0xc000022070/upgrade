import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/herdr_socket.dart';
import 'package:dazzle/platform/vnc/framebuffer.dart';
import 'package:dazzle/platform/vnc/rfb_client.dart';
import 'package:dazzle/platform/vnc/rfb_messages.dart';

import 'support/chunking.dart';
import 'support/herdr_link.dart';
import 'support/vnc_channel.dart';

List<int> _pixelAt(Framebuffer buffer, int x, int y) {
  final at = buffer.offsetOf(x, y);
  return buffer.pixels.sublist(at, at + 4);
}

void main() {
  group(
    'the herdr socket is framed by its newlines and not by its packets',
    () {
      String line(Object? message) => '${jsonEncode(message)}\n';

      test('a reply comes out whole however the bytes were cut', () async {
        final answer = line({
          'id': 'dazzle:0',
          'result': agentListResult('w1:p1', status: 'blocked'),
        });

        for (final split in splitsOf(utf8.encode(answer))) {
          final link = FakeHerdrLink(scripted: split.stream);
          final reply = await HerdrApi(() async => link.link)
              .call('agent.list');
          final agents = HerdrClient.parseSessionAgents(
            reply,
            session: 'default',
          );

          expect(agents.single.paneId, 'w1:p1', reason: split.reason);
          expect(agents.single.state.word, 'blocked', reason: split.reason);
          expect(link.shut, isTrue, reason: split.reason);
        }
      });

      test(
        'a subscription reads its events however the bytes were cut',
        () async {
          final feed =
              line({
                'id': 'dazzle:0',
                'result': {'type': 'subscription_started'},
              }) +
              line({
                'event': 'pane.agent_status_changed',
                'data': {'pane_id': 'w1:p1'},
              }) +
              line({
                'event': 'pane_updated',
                'data': {'pane_id': 'w1:p2'},
              });

          for (final split in splitsOf(utf8.encode(feed))) {
            final link = FakeHerdrLink(scripted: split.stream);
            final events = await HerdrApi(() async => link.link)
                .subscribe(
                  HerdrRequests.paneStatus((session: 'default', pane: 'w1:p1')),
                )
                .toList();

            expect(events.map((event) => event.kind), [
              'pane_agent_status_changed',
              'pane_updated',
            ], reason: split.reason);
          }
        },
      );
    },
  );

  group('the rfb reader is framed by its lengths and not by its packets', () {
    test('the handshake reads the same screen however it was cut', () async {
      final bytes = serverHandshake(width: 1920, height: 1080, name: 'nyx');

      for (final split in splitsOf(bytes)) {
        final channel = FakeVncChannel();
        final client = RfbClient(
          incoming: channel.stream,
          outgoing: channel.sink,
        );

        for (final chunk in split.chunks) {
          channel.feed(chunk);
        }
        final init = await client.handshake();

        expect(init.width, 1920, reason: split.reason);
        expect(init.height, 1080, reason: split.reason);
        expect(init.name, 'nyx', reason: split.reason);

        await client.close();
        await channel.dispose();
      }
    });

    test('a Raw rect lands the same pixels however it was cut', () async {
      final update = <int>[
        Rfb.serverFramebufferUpdate,
        ...updateHeader(1),
        ...rectHeader(
          x: 1,
          y: 1,
          width: 2,
          height: 1,
          encoding: Rfb.encodingRaw,
        ),
        0x10, 0x20, 0x30, 0x00, //
        0x40, 0x50, 0x60, 0x00,
      ];

      for (final split in splitsOf(update)) {
        final channel = FakeVncChannel();
        final client = RfbClient(
          incoming: channel.stream,
          outgoing: channel.sink,
        );
        channel.feed(serverHandshake(width: 8, height: 4));
        await client.handshake();

        final frame = client.frames.first;
        for (final chunk in split.chunks) {
          channel.feed(chunk);
        }
        client.run().ignore();

        final buffer = await frame;
        expect(_pixelAt(buffer, 1, 1), [
          0x10,
          0x20,
          0x30,
          0xFF,
        ], reason: split.reason);
        expect(_pixelAt(buffer, 2, 1), [
          0x40,
          0x50,
          0x60,
          0xFF,
        ], reason: split.reason);

        await client.close();
        await channel.dispose();
      }
    });
  });

  group('the terminal is framed by its escapes and not by its packets', () {
    final transcript = utf8.encode(
      '\x1b]0;dev@dazzle-host\x07'
      'caf\u00e9 \u65e5\u672c\u8a9e \u2500\u2500\r\n'
      '\x1b[31mred\x1b[0m plain\r\n'
      '\u00e9\u00e9\u00e9\u00e9\u00e9\r\n',
    );

    /// The chunks go in as they came off the wire: a character or an escape cut between
    /// two of them is the engine's to hold across the cut.
    TerminalController played(Split split) {
      final terminal = TerminalController(
        config: const TerminalConfig(cols: 40, rows: 10),
      );
      addTearDown(terminal.dispose);
      for (final chunk in split.chunks) {
        terminal.write(chunk);
      }
      return terminal;
    }

    String rendered(TerminalController terminal, FormatterFormat format) {
      final formatter = terminal.createFormatter(format: format, trim: true);
      try {
        return formatter.format();
      } finally {
        formatter.dispose();
      }
    }

    test('the same bytes print the same screen however they are cut', () {
      final want = rendered(
        played(splitsOf(transcript).first),
        FormatterFormat.plain,
      );
      expect(want.split('\n').first, 'café 日本語 ──');

      for (final split in splitsOf(transcript)) {
        expect(
          rendered(played(split), FormatterFormat.plain),
          want,
          reason: split.reason,
        );
      }
    });

    test('a colour opened either side of a cut still ends where it ends', () {
      final want = rendered(
        played(splitsOf(transcript).first),
        FormatterFormat.vt,
      );
      expect(want, contains('\x1b['));

      for (final split in splitsOf(transcript)) {
        expect(
          rendered(played(split), FormatterFormat.vt),
          want,
          reason: split.reason,
        );
      }
    });

    test('the title arrives whole however the OSC is cut', () {
      for (final split in splitsOf(transcript)) {
        expect(played(split).title, 'dev@dazzle-host', reason: split.reason);
      }
    });
  });
  group('the splits themselves', () {
    final vector = Uint8List.fromList(List<int>.generate(64, (i) => i));

    test('every cut puts the same bytes back together', () {
      for (final split in splitsOf(vector)) {
        final rejoined = <int>[for (final chunk in split.chunks) ...chunk];
        expect(rejoined, vector, reason: split.reason);
      }
    });

    test('no cut ever produces an empty chunk', () {
      for (final split in splitsOf(vector)) {
        expect(
          split.chunks.map((chunk) => chunk.length),
          everyElement(greaterThan(0)),
          reason: split.reason,
        );
      }
    });

    test('the same seed cuts the same way twice', () {
      final first = splitsOf(vector, runs: 4).toList();
      final second = splitsOf(vector, runs: 4).toList();

      expect(
        first.map((split) => split.chunks.map((chunk) => chunk.length)),
        second.map((split) => split.chunks.map((chunk) => chunk.length)),
      );
    });

    test('the degenerate cuts are always tried', () {
      final splits = splitsOf(vector, runs: 0).toList();

      expect(splits.first.chunks, hasLength(1));
      expect(splits[1].chunks, hasLength(vector.length));
    });
  });
}
