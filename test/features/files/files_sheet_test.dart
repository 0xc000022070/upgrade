import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart' show hostsProvider;
import 'package:upgrade/application/files/host_file_link.dart';
import 'package:upgrade/application/files/phone_inbox.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/files/files_sheet.dart';
import 'package:upgrade/features/files/send_sheet.dart';
import 'package:upgrade/platform/ssh/host_files.dart' show FileRoute;

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
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
  var closed = false;

  @override
  Host get host => _nyx;

  @override
  Future<String> home() async => '/home/luis';

  @override
  Future<List<DirEntry>?> list(String directory) async => tree[directory];

  @override
  Future<FileWrite> put(
    String path,
    FileBody body, {
    int sharing = 1,
    PutProgress? onProgress,
  }) async {
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
  }) async {
    await into.writeAsBytes(List.filled(size, 1));
    return const FileWrite.landed(FileRoute.sftp);
  }

  @override
  Future<String?> copy({String? text, String? imageAt, String? mime}) async {
    copies.add(text ?? '$imageAt as $mime');
    return null;
  }

  @override
  void close() => closed = true;
}

void main() {
  setUp(stubDeviceChannels);

  late _FakeFiles files;

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
        overrides: [
          hostFilesOpenerProvider.overrideWithValue((_) async => files),
          hostsProvider.overrideWith((ref) => Stream.value(const [_nyx])),
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
    await open(tester, (context) => showHostFiles(context, _nyx));

    expect(find.text('~'), findsOneWidget);
    expect(top(tester, 'src'), lessThan(top(tester, 'notes.txt')));
    expect(top(tester, 'notes.txt'), lessThan(top(tester, '.bashrc')));
    expect(find.text('main.dart'), findsNothing);

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('a file offers share, save and send', (tester) async {
    await open(tester, (context) => showHostFiles(context, _nyx));

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
      (context) async => picked = await pickHostFolder(context, _nyx),
    );

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('/home/luis/src'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('files-put-here')));
    await tester.pumpAndSettle();

    expect(picked, '/home/luis/src');
    expect(files.closed, isTrue);
  });

  testWidgets('put here stays in reach under a long home', (tester) async {
    files.tree['/home/luis'] = [for (var i = 0; i < 80; i++) _dir('dir$i')];
    await open(tester, (context) => pickHostFolder(context, _nyx));

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

    await tester.tap(find.text('nyx'));
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

    await tester.tap(find.text('nyx'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-put-here')));
    await tester.pumpAndSettle();

    expect(files.puts.keys.single, startsWith('/home/luis/shared-'));
    expect(String.fromCharCodes(files.puts.values.single), 'hello');
    await tester.pumpAndSettle(sendSheetLinger);
  });
}
