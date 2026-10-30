/// The explorer's one glyph per row, drawn from the Nerd Font the app already carries for
/// a shell prompt rather than the house vectors.
library;

import 'package:flutter/widgets.dart';

import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/typography.dart';
import 'package:upgrade/features/code/syntax.dart';

const _folderClosed = 0xea83;
const _folderOpen = 0xeaf7;
const _file = 0xe64e;

/// A language [languageOf] does not mark with a glyph of its own falls through to
/// [_file], the same as one it does not recognise at all.
const _byLanguage = <String, int>{
  'dart': 0xe64c,
  'javascript': 0xe60c,
  'typescript': 0xe628,
  'go': 0xe627,
  'rust': 0xe68b,
  'python': 0xe606,
  'c': 0xe649,
  'cpp': 0xe646,
  'java': 0xe66d,
  'kotlin': 0xe634,
  'scala': 0xe68e,
  'bash': 0xe691,
  'yaml': 0xe6a8,
  'ini': 0xe615,
  'json': 0xe60b,
  'sql': 0xe64d,
  'nix': 0xf313,
  'lua': 0xe620,
  'markdown': 0xe609,
  'dockerfile': 0xe650,
  'makefile': 0xe673,
  'css': 0xe614,
  'scss': 0xe603,
  'xml': 0xe619,
  'graphql': 0xe662,
  'properties': 0xe615,
};

class FileIcon extends StatelessWidget {
  const FileIcon.directory({super.key, required bool open})
    : _codepoint = open ? _folderOpen : _folderClosed;

  FileIcon.file(SyntaxLanguage? language, {super.key})
    : _codepoint = _byLanguage[language?.name] ?? _file;

  final int _codepoint;

  @override
  Widget build(BuildContext context) {
    return Text(
      String.fromCharCode(_codepoint),
      // A Nerd Font glyph is a full em wide, so at [IconSizes.glyph] it fills the
      // slot exactly and has nowhere to grow: answering the text size would cut it
      // off at the slot's edge rather than enlarge it.
      textScaler: TextScaler.noScaling,
      style: TextStyle(
        fontFamily: FontFamilies.monoSymbols,
        fontSize: IconSizes.glyph,
        height: 1,
        color: context.tokens.textMuted,
      ),
    );
  }
}
