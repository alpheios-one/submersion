import 'dart:async';

/// Default reporting granularity for [withByteProgress]: every 4 MiB consumed.
const int defaultByteProgressInterval = 4 << 20;

/// Passes [source] through unchanged while reporting the running byte count
/// to [onProgress]: once every [interval] bytes and once more when the stream
/// ends, so the final report always equals the total bytes consumed even for
/// a stream shorter than one interval.
///
/// Used by the base-file parse passes to turn a long, otherwise silent scan
/// into a stream of liveness ticks for the isolate client and the sync
/// progress bar (issue #1421).
Stream<List<int>> withByteProgress(
  Stream<List<int>> source, {
  required void Function(int consumed) onProgress,
  int interval = defaultByteProgressInterval,
}) async* {
  var consumed = 0;
  var nextReport = interval;
  await for (final chunk in source) {
    consumed += chunk.length;
    if (consumed >= nextReport) {
      onProgress(consumed);
      nextReport = consumed + interval;
    }
    yield chunk;
  }
  onProgress(consumed);
}
