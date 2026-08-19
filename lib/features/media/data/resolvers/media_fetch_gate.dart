import 'dart:async';
import 'dart:collection';

import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';

/// Caps simultaneous media-store fetches and collapses duplicate ones.
///
/// Nothing gated the store read path before #1175. Every visible grid tile
/// resolves independently -- `MediaItemView` kicks its own future from
/// `initState` -- so a screenful of store-backed thumbnails opened one HEAD
/// plus one GET per tile, all at once. A 140 px grid puts 30-60 tiles on
/// screen on desktop, each request is retried up to six times with backoff,
/// and none of them shared work with any other. Against a slow endpoint that
/// is a gallery of permanent shimmer; against a healthy one it is still a
/// burst most S3-compatible servers throttle.
///
/// Two independent problems, one object:
///
/// * **Concurrency.** [maxConcurrent] fetches run at a time; the rest queue.
///   Matching `GalleryThumbnailCache`'s cap, which solved the same shape of
///   problem for PhotoKit.
/// * **Coalescing.** Two callers asking for the same key share one fetch.
///   That is not a micro-optimisation here: media rows are content-addressed,
///   so the same photo linked to two dives is two rows with one hash, and
///   without this each issues its own download of identical bytes and both
///   race to write the same cache entry.
///
/// Deliberately NOT a byte cache. The bytes already have one -- `MediaCacheStore`,
/// on disk -- and holding them in memory as well is what the viewer's own
/// providers were doing wrong.
class MediaFetchGate {
  MediaFetchGate({this.maxConcurrent = 4}) : assert(maxConcurrent > 0);

  /// Ceiling on simultaneous fetches.
  final int maxConcurrent;

  /// Fetches currently running, so concurrent callers can share one.
  final Map<String, Future<MediaSourceData?>> _inFlight =
      <String, Future<MediaSourceData?>>{};

  /// Callers parked waiting for a slot.
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  int _running = 0;

  /// In-flight fetch count, for tests.
  int get runningCount => _running;

  /// Callers currently parked, for tests.
  int get waitingCount => _waiting.length;

  /// Runs [fetch] under the cap, sharing the result with any caller that asks
  /// for the same [key] while it is still running.
  Future<MediaSourceData?> run(
    String key,
    Future<MediaSourceData?> Function() fetch,
  ) {
    final pending = _inFlight[key];
    if (pending != null) return pending;

    // _run suspends at its first await before returning, so the assignment
    // below always lands before the finally block that clears it.
    final future = _run(key, fetch);
    _inFlight[key] = future;
    return future;
  }

  Future<MediaSourceData?> _run(
    String key,
    Future<MediaSourceData?> Function() fetch,
  ) async {
    await _acquire();
    try {
      return await fetch();
    } finally {
      _inFlight.remove(key);
      _release();
    }
  }

  Future<void> _acquire() {
    if (_running < maxConcurrent) {
      _running++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  /// FIFO, unlike `GalleryThumbnailCache`'s LIFO.
  ///
  /// That class serves newest-first on the argument that older waiters belong
  /// to tiles already scrolled away. It does not hold here: [run] hands a
  /// parked future to any later caller asking for the same key, so a waiter
  /// can have live tiles behind it, and newest-first would leave them shimmering
  /// for the whole of a long fling. Fairness is worth more than recency when a
  /// slot is 30-60 tiles deep.
  void _release() {
    if (_waiting.isEmpty) {
      _running--;
      return;
    }
    // The slot passes straight to the next waiter: _running stays put because
    // one fetch ends exactly as another begins.
    _waiting.removeFirst().complete();
  }
}
