import 'dart:io';
import 'dart:typed_data';

import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec_exception.dart';

/// Ceiling on the inflated size of one series body.
///
/// zlib is a compression bomb vector: a few kilobytes of stored blob can
/// inflate to hundreds of megabytes, and the sample-count guard only runs
/// once the whole body is already in memory. A blob arriving from a peer is
/// decoded inside the sync merge, so an unbounded inflate is an OOM kill of
/// the app on every sync attempt.
///
/// The bound is deliberately generous. The largest plausible real series,
/// a multi-hour dive sampled every second with every field present, costs a
/// few megabytes; 64 MB leaves two orders of magnitude of headroom over any
/// series a dive computer can produce.
const int kMaxInflatedSeriesBodyBytes = 64 * 1024 * 1024;

// ZLibCodec has no const constructor, so this is `final`, not `const`.
final ZLibCodec _zlib = ZLibCodec(level: 6);

/// Inflates a stored series blob, refusing anything whose inflated body
/// exceeds [maxBytes].
///
/// Throws [ProfileSeriesCodecException] both for bytes that are not a zlib
/// stream and for a body over the cap. The cap is enforced while inflating,
/// so an oversized body is never fully materialised.
Uint8List inflateSeriesBody(
  Uint8List bytes, {
  int maxBytes = kMaxInflatedSeriesBodyBytes,
}) {
  final sink = _CappedByteSink(maxBytes);
  try {
    _zlib.decoder.startChunkedConversion(sink)
      ..add(bytes)
      ..close();
  } on ProfileSeriesCodecException {
    rethrow;
  } catch (e) {
    throw ProfileSeriesCodecException('not a zlib stream: $e');
  }
  return sink.takeBytes();
}

/// Collects the inflater's output chunks and aborts once they exceed
/// [limit], so the cap costs at most one chunk of overshoot.
class _CappedByteSink implements Sink<List<int>> {
  _CappedByteSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder();
  int _length = 0;

  @override
  void add(List<int> chunk) {
    _length += chunk.length;
    if (_length > limit) {
      throw ProfileSeriesCodecException(
        'the body would inflate past the $limit byte cap',
      );
    }
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
