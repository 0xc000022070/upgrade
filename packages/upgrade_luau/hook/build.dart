import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const revision = 'c54f558b4d5748ab0658610b8ce0c432053e41eb';
const digest =
    'de4123cdb8be3e948c3fc8167bf018a3b2422adfe3db3b2fdd3ba941b777250a';
const components = ['Common', 'Ast', 'Bytecode', 'Compiler', 'VM'];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final archive = File.fromUri(
      input.outputDirectory.resolve('luau-$revision.tar.gz'),
    );
    await archive.parent.create(recursive: true);
    if (!await archive.exists()) {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          Uri.parse(
            'https://codeload.github.com/luau-lang/luau/tar.gz/$revision',
          ),
        )).close();
        if (response.statusCode != 200) {
          throw StateError('Luau source download failed');
        }
        final temp = File('${archive.path}.part');
        await response.pipe(temp.openWrite());
        if (sha256.convert(await temp.readAsBytes()).toString() != digest) {
          throw StateError('Luau source digest mismatch');
        }
        await temp.rename(archive.path);
      } finally {
        client.close(force: true);
      }
    }
    final bytes = await archive.readAsBytes();
    if (sha256.convert(bytes).toString() != digest) {
      throw StateError('Luau source digest mismatch');
    }
    final source = Directory.fromUri(
      input.outputDirectory.resolve('luau-$revision/'),
    );
    final extracted = File.fromUri(source.uri.resolve('.complete'));
    if (!await extracted.exists()) {
      for (final entry in TarDecoder().decodeBytes(
        GZipDecoder().decodeBytes(bytes),
      )) {
        if (!entry.isFile) continue;
        final relative = entry.name.split('/').skip(1).join('/');
        if (!components.contains(relative.split('/').first) &&
            relative != 'LICENSE.txt') {
          continue;
        }
        final file = File.fromUri(source.uri.resolve(relative));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content);
      }
      await extracted.writeAsString(revision, flush: true);
    }
    final sources = ['src/runtime.cpp'];
    for (final component in components) {
      await for (final file in Directory.fromUri(
        source.uri.resolve('$component/src/'),
      ).list()) {
        if (file is File && file.path.endsWith('.cpp')) sources.add(file.path);
      }
    }
    await CBuilder.library(
      name: 'upgrade_luau',
      assetName: 'upgrade_luau.dart',
      sources: sources..sort(),
      includes: [
        for (final component in components)
          source.uri.resolve('$component/include/').toFilePath(),
      ],
      language: Language.cpp,
      std: 'c++17',
      libraries: [
        if (input.config.code.targetOS == OS.android ||
            input.config.code.targetOS == OS.linux)
          'm',
      ],
      cppLinkStdLib: input.config.code.targetOS == OS.android
          ? 'c++_static'
          : null,
      defines: {'LUAU_EXTERN_C': '1'},
      flags: [
        '-fvisibility=hidden',
        if (input.config.code.targetOS == OS.android ||
            input.config.code.targetOS == OS.linux)
          '-Wl,-z,defs',
      ],
    ).run(input: input, output: output);
  });
}
