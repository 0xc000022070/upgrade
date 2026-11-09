import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/platform/plugins/store.dart';

export 'package:upgrade/platform/plugins/store.dart' show BuiltinArrival;

class NativePluginModule {
  const NativePluginModule({
    required this.id,
    required this.directory,
    required this.surfaces,
    this.deactivate,
    this.arrives = BuiltinArrival.adopted,
    this.splitFrom,
  });
  final String id;
  final String directory;
  final Map<String, WidgetBuilder> surfaces;
  final void Function(Ref ref)? deactivate;
  final BuiltinArrival arrives;

  /// The builtin this one was carved out of: an install that already has it
  /// starts this one in the same on/off state.
  final String? splitFrom;
}
