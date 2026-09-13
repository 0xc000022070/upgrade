import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NativePluginModule {
  const NativePluginModule({
    required this.id,
    required this.directory,
    required this.surfaces,
    this.deactivate,
  });
  final String id;
  final String directory;
  final Map<String, WidgetBuilder> surfaces;
  final void Function(Ref ref)? deactivate;
}
