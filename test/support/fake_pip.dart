import 'dart:async';
import 'dart:ui' show Size;

import 'package:striked/application/pip.dart';

class FakePip implements PipSurface {
  FakePip({this.here = true});

  final bool here;
  var entries = 0;
  Size? aspect;
  final modes = StreamController<bool>.broadcast();

  @override
  Future<bool> available() async => here;

  @override
  Future<bool> enter({Size? aspect}) async {
    entries++;
    this.aspect = aspect;
    return here;
  }

  @override
  Stream<bool> mode() => modes.stream;
}
