import 'dart:io';

class Serial {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

Future<void> replaceFile(File file, String text) async {
  await file.parent.create(recursive: true);
  final next = File('${file.path}.next');
  await next.writeAsString(text, flush: true);
  await next.rename(file.path);
}
