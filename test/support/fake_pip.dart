import 'dart:async';

import 'package:dazzle/application/pip.dart';

/// A window that records what it was told rather than asking an activity.
class FakePip implements PipSurface {
  FakePip({this.here = true});

  final bool here;
  var entries = 0;
  final modes = StreamController<bool>.broadcast();

  @override
  Future<bool> available() async => here;

  @override
  Future<bool> enter() async {
    entries++;
    return here;
  }

  @override
  Stream<bool> mode() => modes.stream;
}
