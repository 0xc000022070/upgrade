// ignore_for_file: implementation_imports, invalid_use_of_internal_member -- TerminalSession.terminal is the only view of the live storage limit
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/src/controller/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  test(
    'a restored controller stores an image as large as a fresh one',
    () async {
      final source = Terminal(cols: 20, rows: 5);
      final snapshot = source.encodeSnapshot();
      source.dispose();
      final controller = TerminalController.fromSnapshot(
        snapshot,
        preserveSnapshotColors: false,
      ) as TerminalSession;
      addTearDown(controller.dispose);
      await controller.restored;

      const side = 1700;
      final payload = base64Encode(
        ZLibCodec().encode(Uint8List(side * side * 4)),
      );
      controller.terminal.write(
        Uint8List.fromList(
          utf8.encode(
            '\x1b_Ga=t,f=32,o=z,s=$side,v=$side,i=7,q=2;$payload\x1b\\',
          ),
        ),
      );

      expect(
        controller.terminal.kittyImageStorageLimit,
        controller.config.kittyImageStorageLimit,
      );
      expect(KittyGraphics.of(controller.terminal)?.image(7), isNotNull);
    },
  );
}
