import 'package:flutter/material.dart';

import 'package:dazzle/design/tokens.dart';

/// The house tokens, wired the way `DazzleApp` wires them, so a widget test's
/// `MaterialApp` resolves `context.tokens` the same way the real app does.
final testTheme = ThemeData(extensions: const [DazzleTokens.house]);
