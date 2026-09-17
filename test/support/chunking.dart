import 'dart:math';
import 'dart:typed_data';

/// One way a socket could have handed a byte vector over.
///
/// Every parser in this app reads from a stream it does not control the
/// framing of: ssh gives back what arrived, not what was sent, so a frame, an
/// escape sequence or a JSON line can be cut anywhere. Tests that feed a whole
/// vector in one chunk prove the parse and nothing about the framing, and a
/// test that picks its own boundaries only ever proves the boundary somebody
/// already thought of.
class Split {
  const Split(this.seed, this.chunks);

  /// The seed this split came from, so a red test can be run again on the
  /// same cut. [reason] is what carries it into the failure.
  final int seed;

  final List<Uint8List> chunks;

  /// The chunks as a stream, typed the way a parser takes them: `utf8.decoder`
  /// and every other byte transformer are written against `List<int>`, and a
  /// `Stream<Uint8List>` is rejected at the transform rather than at the call.
  Stream<List<int>> get stream => Stream<List<int>>.fromIterable(chunks);

  /// What to hand `expect`'s `reason`, so a failure says which cut broke it
  /// rather than leaving the reader to guess which of the runs it was.
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

/// The default seed. Fixed, because a suite that picks a new one every run is
/// a suite that goes red on a commit that changed nothing.
const chunkingSeed = 0x0DA22;

/// The cuts worth trying on [bytes]: the whole vector, a byte at a time, then
/// [runs] random ones.
///
/// The two degenerate cuts are always first and are what most framing bugs
/// answer to; the random ones are for the boundary nobody would pick, and each
/// carries its seed so a failure can be reproduced.
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
    // At least one byte, at most the rest: a zero-length chunk is something a
    // socket never delivers, and testing one would prove a case that cannot
    // happen.
    final take = 1 + random.nextInt(bytes.length - at);
    chunks.add(bytes.sublist(at, at + take));
    at += take;
  }
  return chunks.isEmpty ? [Uint8List(0)] : chunks;
}
