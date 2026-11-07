import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart' show hostsProvider;
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/files/files_sheet.dart';
import 'package:upgrade/features/files/host_transfers.dart'
    show copyGone, unreadFolder;
import 'package:upgrade/features/files/send_sheet.dart';
import 'package:upgrade/features/files/transfer_bar.dart';
import 'package:upgrade/platform/ssh/host_files.dart' show FileRoute;
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

const _oak = Host(
  id: 'h2',
  name: 'oak',
  address: '100.64.0.2',
  port: 22,
  user: 'luis',
  keyId: 'key-1',
);

DirEntry _dir(String name) =>
    DirEntry(name: name, kind: DirEntryKind.directory, size: 0);

DirEntry _file(String name, int size) =>
    DirEntry(name: name, kind: DirEntryKind.file, size: size);

final class _FakeFiles implements HostFiles {
  _FakeFiles(this.tree);

  final Map<String, List<DirEntry>> tree;
  final puts = <String, List<int>>{};
  final copies = <String>[];
  @override
  var closed = false;
  var unreadable = false;
  final failOnce = <String>{};
  String? copyFails;

  @override
  Host get host => _oak;

  @override
  Future<String> home() async => '/home/luis';

  @override
  Future<List<DirEntry>?> list(String directory) async =>
      unreadable || closed ? null : tree[directory];

  @override
  Future<FileWrite> put(
    String path,
    FileBody body, {
    int sharing = 1,
    PutProgress? onProgress,
  }) async {
    if (failOnce.remove(path.split('/').last)) {
      return const FileWrite.failed(FileRoute.sftp, 'denied');
    }
    puts[path] = await body.read();
    return const FileWrite.landed(FileRoute.sftp);
  }

  @override
  Future<FileWrite> get(
    String path,
    File into, {
    required int size,
    int sharing = 1,
    PutProgress? onProgress,
    TransferStop? stop,
  }) async {
    await into.writeAsBytes(List.filled(size, 1));
    return const FileWrite.landed(FileRoute.sftp);
  }

  @override
  Future<String?> copy({String? text, String? imageAt, String? mime}) async {
    copies.add(text ?? '$imageAt as $mime');
    return copyFails;
  }

  @override
  void close() => closed = true;
}

void main() {
  setUp(stubDeviceChannels);

  late _FakeFiles files;
  var unreachable = 0;
  var opened = 0;

  setUp(() {
    files = _FakeFiles({
      '/home/luis': [_file('.bashrc', 10), _file('notes.txt', 3), _dir('src')],
      '/home/luis/src': [_file('main.dart', 40)],
    });
  });

  Future<void> open(
    WidgetTester tester,
    Future<void> Function(BuildContext context) show,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          hostFilesOpenerProvider.overrideWithValue((_) async {
            if (unreachable-- > 0) throw const SocketException('unreachable');
            opened++;
            return files..closed = false;
          }),
          hostsProvider.overrideWith((ref) => Stream.value(const [_oak])),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () => show(context),
              child: const Center(child: Text('OPEN')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('the tree opens at home, folders first and dotfiles last', (
    tester,
  ) async {
    await open(tester, (context) => showHostFiles(context, _oak));

    expect(find.byKey(const ValueKey('files-dir-/home/luis')), findsOneWidget);
    expect(top(tester, 'src'), lessThan(top(tester, 'notes.txt')));
    expect(top(tester, 'notes.txt'), lessThan(top(tester, '.bashrc')));
    expect(find.text('main.dart'), findsNothing);

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);
    final target = find.byKey(const ValueKey('files-target'));
    expect(find.descendant(of: target, matching: find.text('~/')), findsOne);
    expect(find.descendant(of: target, matching: find.text('src')), findsOne);
  });

  testWidgets('folders, then files, then dot folders, then dotfiles, each '
      'by name whatever the case', (tester) async {
    files.tree['/home/luis'] = [
      _file('b.txt', 1),
      _dir('.cache'),
      _file('.zshrc', 1),
      _dir('Zeta'),
      _file('A.txt', 1),
      _file('.bashrc', 1),
      _dir('alpha'),
      _dir('.Config'),
    ];
    await open(tester, (context) => showHostFiles(context, _oak));

    final names = [
      'alpha',
      'Zeta',
      'A.txt',
      'b.txt',
      '.cache',
      '.Config',
      '.bashrc',
      '.zshrc',
    ];
    final tops = [for (final name in names) top(tester, name)];
    expect(tops, [...tops]..sort());
    expect(tops.toSet(), hasLength(names.length));
  });

  testWidgets('a link that died is opened again by the next tap', (
    tester,
  ) async {
    await open(tester, (context) => showHostFiles(context, _oak));
    final before = opened;
    files.closed = true;

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(opened, before + 1);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.byKey(const ValueKey('files-dir-/home/luis')), findsOneWidget);
  });

  testWidgets('a file offers share, save and send', (tester) async {
    await open(tester, (context) => showHostFiles(context, _oak));

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(find.text('SHARE'), findsOneWidget);
    expect(find.text('SAVE TO PHONE'), findsOneWidget);
    expect(find.text('SEND TO HOST'), findsOneWidget);
  });

  testWidgets('picking answers the folder tapped, and closes the link', (
    tester,
  ) async {
    String? picked;
    await open(
      tester,
      (context) async => picked = await pickHostFolder(context, _oak),
    );

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('files-target')),
        matching: find.text('src'),
      ),
      findsOne,
    );
    await tester.tap(find.byKey(const ValueKey('files-put-here')));
    await tester.pumpAndSettle();

    expect(picked, '/home/luis/src');
    expect(files.closed, isTrue);
  });

  testWidgets('put here stays in reach under a long home', (tester) async {
    files.tree['/home/luis'] = [for (var i = 0; i < 80; i++) _dir('dir$i')];
    await open(tester, (context) => pickHostFolder(context, _oak));

    final put = find.byKey(const ValueKey('files-put-here'));
    expect(put, findsOneWidget);
    expect(
      tester.getRect(put).bottom,
      lessThanOrEqualTo(
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
      ),
    );
    expect(put.hitTestable(), findsOneWidget);
  });

  testWidgets('shared text sent to the clipboard goes on as text', (
    tester,
  ) async {
    await open(
      tester,
      (context) => showSendSheet(context, const [SharedText('hello')]),
    );

    await tester.tap(find.text('oak'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-clipboard')));
    await tester.pump();
    await tester.pump();

    expect(files.copies, ['hello']);
    expect(find.text('COPIED'), findsOneWidget);
    await tester.pumpAndSettle(sendSheetLinger);
  });

  testWidgets('shared text sent to a folder is written as a file there', (
    tester,
  ) async {
    await open(
      tester,
      (context) => showSendSheet(context, const [SharedText('hello')]),
    );

    await tester.tap(find.text('oak'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-put-here')));
    await tester.pumpAndSettle();

    expect(files.puts.keys.single, startsWith('/home/luis/shared-'));
    expect(String.fromCharCodes(files.puts.values.single), 'hello');
    await tester.pumpAndSettle(sendSheetLinger);
  });

  testWidgets('a share none of which could be read says so', (tester) async {
    await open(
      tester,
      (context) => showSendSheet(context, const [], unreadable: 2),
    );

    expect(find.text('2 UNREADABLE'), findsOneWidget);
    expect(find.byKey(const ValueKey('send-clipboard')), findsNothing);
    expect(find.text('CLOSE'), findsOneWidget);
  });

  testWidgets('a send beside an unreadable share stays open to say so', (
    tester,
  ) async {
    await open(
      tester,
      (context) =>
          showSendSheet(context, const [SharedText('hello')], unreadable: 1),
    );

    await tester.tap(find.text('oak'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-clipboard')));
    await tester.pumpAndSettle(sendSheetLinger);

    expect(files.copies, ['hello']);
    expect(find.text('COPIED · 1 UNREADABLE'), findsOneWidget);
  });

  testWidgets('a folder that cannot be read takes nothing', (tester) async {
    await open(
      tester,
      (context) => showSendSheet(context, const [SharedText('hello')]),
    );

    await tester.tap(find.text('oak'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-folder')));
    await tester.pumpAndSettle();
    files.unreadable = true;
    await tester.tap(find.byKey(const ValueKey('files-put-here')));
    await tester.pumpAndSettle();

    expect(files.puts, isEmpty);
    expect(find.text('FOLDER · $unreadFolder'), findsOneWidget);
  });

  group('shared files', () {
    late Directory scratch;
    late List<SharedItem> shared;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('send-');
      shared = [
        for (final name in ['a.txt', 'b.txt'])
          SharedFile(
            path: (File('${scratch.path}/$name')..writeAsStringSync(name)).path,
            name: name,
            size: 5,
            mime: 'text/plain',
          ),
      ];
    });

    tearDown(() {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    });

    /// Real file IO runs outside the fake clock: pump real time until [done] holds, and
    /// leave a miss to the expect after it.
    Future<void> settle(
      WidgetTester tester,
      Finder tap,
      bool Function() done,
    ) async {
      await tester.runAsync(() async {
        await tester.tap(tap);
        for (var i = 0; i < 200 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pump();
    }

    bool shows(String text) => find.text(text).evaluate().isNotEmpty;

    testWidgets('a retry sends only the file that failed', (tester) async {
      files.failOnce.add('b.txt');
      await open(tester, (context) => showSendSheet(context, shared));

      await tester.tap(find.byKey(const ValueKey('send-folder')));
      await tester.pumpAndSettle();
      await settle(
        tester,
        find.byKey(const ValueKey('files-put-here')),
        () => shows('UPLOADING · 1 FAILED'),
      );
      expect(files.puts.keys, ['/home/luis/a.txt']);
      expect(find.text('UPLOADING · 1 FAILED'), findsOneWidget);

      await settle(
        tester,
        find.byKey(const ValueKey('send-retry')),
        () => shows('IN luis'),
      );
      expect(files.puts.keys, ['/home/luis/a.txt', '/home/luis/b.txt']);
      expect(find.text('IN luis'), findsOneWidget);
      await tester.pumpAndSettle(sendSheetLinger);
    });

    testWidgets('a failed upload can be retried after its sheet closed', (
      tester,
    ) async {
      files.failOnce.add('b.txt');
      late BuildContext root;
      await open(tester, (context) {
        root = context;
        return showSendSheet(context, shared);
      });

      await tester.tap(find.byKey(const ValueKey('send-folder')));
      await tester.pumpAndSettle();
      await settle(
        tester,
        find.byKey(const ValueKey('files-put-here')),
        () => shows('UPLOADING · 1 FAILED'),
      );
      expect(find.text('UPLOADING · 1 FAILED'), findsOneWidget);
      Navigator.of(tester.element(find.byType(SendSheet))).pop();
      await tester.pumpAndSettle();
      expect(File((shared[1] as SharedFile).path).existsSync(), isTrue);

      unawaited(showTransfers(root));
      await tester.pumpAndSettle();
      await settle(
        tester,
        find.byKey(const ValueKey('transfers-0-retry')),
        () =>
            files.puts.length == 2 &&
            !File((shared[1] as SharedFile).path).existsSync(),
      );
      expect(files.puts.keys, ['/home/luis/a.txt', '/home/luis/b.txt']);
      expect(File((shared[1] as SharedFile).path).existsSync(), isFalse);
    });

    testWidgets('a copy the phone lost is not offered again', (tester) async {
      files.failOnce.add('b.txt');
      await open(tester, (context) => showSendSheet(context, shared));

      await tester.tap(find.byKey(const ValueKey('send-folder')));
      await tester.pumpAndSettle();
      await settle(
        tester,
        find.byKey(const ValueKey('files-put-here')),
        () => shows('UPLOADING · 1 FAILED'),
      );
      File((shared[1] as SharedFile).path).deleteSync();
      await settle(
        tester,
        find.byKey(const ValueKey('send-retry')),
        () => shows('IN luis · 1 FAILED'),
      );

      expect(files.puts.keys, ['/home/luis/a.txt']);
      expect(find.text('IN luis · 1 FAILED'), findsOneWidget);
      expect(find.text(copyGone), findsOneWidget);
      expect(find.byKey(const ValueKey('send-retry')), findsNothing);
    });

    testWidgets('a send whose copies are all gone copies nothing', (
      tester,
    ) async {
      await open(tester, (context) => showSendSheet(context, shared));
      for (final file in shared.cast<SharedFile>()) {
        File(file.path).deleteSync();
      }

      await settle(
        tester,
        find.byKey(const ValueKey('send-clipboard')),
        () => shows('2 FAILED'),
      );
      expect(find.text('2 FAILED'), findsOneWidget);
    });

    testWidgets('a lost copy does not hide a clipboard that failed', (
      tester,
    ) async {
      files.failOnce.add('b.txt');
      await open(tester, (context) => showSendSheet(context, shared));

      await settle(
        tester,
        find.byKey(const ValueKey('send-clipboard')),
        () => find.byKey(const ValueKey('send-retry')).evaluate().isNotEmpty,
      );
      File((shared[1] as SharedFile).path).deleteSync();
      files.copyFails = 'no clipboard';
      await settle(
        tester,
        find.byKey(const ValueKey('send-retry')),
        () => shows('UPLOADING · 1 FAILED · CLIPBOARD · no clipboard'),
      );

      expect(
        find.text('UPLOADING · 1 FAILED · CLIPBOARD · no clipboard'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('send-landed')), findsOneWidget);
    });

    testWidgets('a host without a clipboard still says where files went', (
      tester,
    ) async {
      files.copyFails = 'no clipboard';
      await open(tester, (context) => showSendSheet(context, shared));

      await settle(
        tester,
        find.byKey(const ValueKey('send-clipboard')),
        () => shows('CLIPBOARD · no clipboard'),
      );
      expect(find.text('CLIPBOARD · no clipboard'), findsOneWidget);
      final landed = tester.widget<SelectableText>(
        find.byKey(const ValueKey('send-landed')),
      );
      expect(landed.data!.split('\n'), unorderedEquals(files.puts.keys));

      files.copyFails = null;
      await settle(
        tester,
        find.byKey(const ValueKey('send-clipboard')),
        () => files.copies.length == 2,
      );
      expect(files.puts, hasLength(2));
      expect(files.copies.last, landed.data);
      await tester.pumpAndSettle(sendSheetLinger);
    });
  });

  testWidgets('an unreachable host can be tried again', (tester) async {
    unreachable = 1;
    await open(tester, (context) => showHostFiles(context, _oak));
    expect(find.byKey(const ValueKey('files-error')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('files-reconnect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-error')), findsNothing);
    expect(find.text('notes.txt'), findsOneWidget);
  });
}
