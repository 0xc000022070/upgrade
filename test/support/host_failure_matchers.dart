import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';

TypeMatcher<HostFailure> isFailureOf(HostFailureKind kind) =>
    isA<HostFailure>().having((failure) => failure.kind, 'kind', kind);
