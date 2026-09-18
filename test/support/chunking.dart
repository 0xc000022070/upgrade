import 'dart:math';
import 'dart:typed_data';

/// ssh gives back what arrived, not what was sent, so a frame, an escape sequence or a
/// JSON line can be cut anywhere.
class Split {
  const Split(this.seed, this.chunks);

  /// The seed this split came from, so a red test can be run again on the same cut.
  final int seed;

  final List<Uint8List> chunks;

  /// Typed the way ssh hands them over. `utf8.decoder` and every other byte transformer is
  /// written against `List<int>`, so a `Stream<Uint8List>` is rejected at the transform —
  /// which is the point. Widening this would hide the one shape the device reads from.
  Stream<Uint8List> get stream => Stream<Uint8List>.fromIterable(chunks);

  String get reason {
    final sizes = chunks.map((chunk) => chunk.length).toList();
    final head = sizes.take(8).join(',');
    final tail = sizes.length > 8 ? ',… ${sizes.length} chunks' : '';
    return switch (seed) {
      _wholeSeed => 'whole',
      _byteSeed => 'a byte at a time',
      _ => 'seed $seed, chunks $head$tail',
    };
  }

  @override
  String toString() => reason;
}

const _wholeSeed = -1;
const _byteSeed = -2;

/// Fixed, because a suite that picks a new one every run is a suite that goes red on a
/// commit that changed nothing.
const chunkingSeed = 0x0DA22;

/// The two degenerate cuts are always first and are what most framing bugs answer to; the
/// random ones are for the boundary nobody would pick.
Iterable<Split> splitsOf(
  List<int> bytes, {
  int runs = 12,
  int seed = chunkingSeed,
}) sync* {
  final whole = Uint8List.fromList(bytes);
  yield Split(_wholeSeed, [whole]);
  yield Split(_byteSeed, [
    for (var i = 0; i < whole.length; i++) whole.sublist(i, i + 1),
  ]);
  for (var run = 0; run < runs; run++) {
    final runSeed = seed + run;
    yield Split(runSeed, _cut(whole, Random(runSeed)));
  }
}

List<Uint8List> _cut(Uint8List bytes, Random random) {
  final chunks = <Uint8List>[];
  var at = 0;
  while (at < bytes.length) {
    // At least one byte, at most the rest: a zero-length chunk is something a socket never
    // delivers.
    final take = 1 + random.nextInt(bytes.length - at);
    chunks.add(bytes.sublist(at, at + take));
    at += take;
  }
  return chunks.isEmpty ? [Uint8List(0)] : chunks;
}
