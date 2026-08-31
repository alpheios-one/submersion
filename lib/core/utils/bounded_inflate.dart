import 'dart:convert';
import 'dart:typed_data';

/// Thrown when a compressed blob cannot be inflated within its caps.
///
/// One declared type, so a cap breach and a malformed stream arrive as the
/// same thing and a caller can name it in an `on` clause. The platform
/// raises a bare `FormatException` for bad input, which is too broad to
/// catch around a decode of any size: `utf8.decode` and `jsonDecode` raise
/// it too, and catching all three together cannot tell them apart.
class BoundedInflateException implements Exception {
  const BoundedInflateException(this.message);

  final String message;

  @override
  String toString() => 'BoundedInflateException: $message';
}

/// Inflates a compressed blob, refusing anything that expands past
/// [maxBytes] or arrives longer than [maxBlobBytes].
///
/// [codec] selects the wire format: pass `gzip` or `zlib`. Both are handed
/// to the same chunked decoder, so a compression bomb is abandoned at the
/// first chunk over the cap rather than after the whole body is in memory.
/// `gzip.decode` on its own has no such escape: the peak is reached inside
/// the native filter before a caller sees a single byte, so nothing
/// downstream can prevent it.
///
/// Both caps are required. A shared helper must never lend one call site a
/// bound that was sized for another payload, and the two caps answer
/// different questions: [maxBlobBytes] bounds what is copied into the native
/// filter, [maxBytes] bounds what comes back out.
///
/// Throws [BoundedInflateException] if [bytes] is longer than
/// [maxBlobBytes], is not a stream [codec] can read, or inflates past
/// [maxBytes]. An [ArgumentError] for a negative cap is a programming error
/// and is left to surface.
///
/// Not a completeness check. Both zlib and gzip accept a truncated stream,
/// returning the bytes they managed to inflate with no error, so callers
/// must frame their own payload rather than trusting the length they get
/// back.
///
/// Not a format check either. Dart's gzip decoder sniffs the header and
/// reads a zlib stream just as happily, so [codec] selects an intent, not a
/// guarantee about what arrived.
Uint8List inflateBounded(
  Uint8List bytes, {
  required Codec<List<int>, List<int>> codec,
  required int maxBytes,
  required int maxBlobBytes,
}) {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
  }
  if (maxBlobBytes < 0) {
    throw ArgumentError.value(
      maxBlobBytes,
      'maxBlobBytes',
      'must not be negative',
    );
  }
  // Before the conversion, not inside the sink: the filter copies the whole
  // input natively before it emits a first chunk, so a sink-side check never
  // sees an oversized blob. Bytes appended after a complete stream are
  // copied and then silently discarded, which is a spike with no output to
  // measure it by.
  if (bytes.length > maxBlobBytes) {
    throw BoundedInflateException(
      'blob of ${bytes.length} byte(s) exceeds the $maxBlobBytes allowed',
    );
  }
  final sink = _BoundedByteSink(maxBytes);
  try {
    final input = codec.decoder.startChunkedConversion(sink);
    input
      ..add(bytes)
      ..close();
  } on FormatException catch (e) {
    throw BoundedInflateException('not a readable stream: ${e.message}');
  }
  return sink.takeBytes();
}

/// Collects inflated chunks and throws as soon as they pass [_maxBytes].
class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this._maxBytes);

  final int _maxBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (_builder.length + chunk.length > _maxBytes) {
      // Thrown from inside the decoder's own add, which unwinds it.
      throw BoundedInflateException(
        'inflated body exceeds the $_maxBytes byte(s) allowed',
      );
    }
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
