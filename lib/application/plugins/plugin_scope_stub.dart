import 'package:flutter/widgets.dart';

/// [inheritPluginScope] where `dart:ffi` is absent. Plugins run on Luau over FFI, so
/// without it no plugin owns a surface: the answer is the native one's for no owner.
Widget inheritPluginScope(
  BuildContext context,
  Widget child, {
  String? surface,
}) => surface == null ? child : const SizedBox.shrink();
