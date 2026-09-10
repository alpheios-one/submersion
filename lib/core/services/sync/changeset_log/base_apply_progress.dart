import 'package:submersion/core/services/logger_service.dart';

/// Maps the three file passes of a peer base apply onto one 0.0 to 1.0
/// fraction (each pass is a third) and logs when each pass completes, so a
/// debug log of a large adoption shows steady progress instead of minutes of
/// silence (issue #1421).
///
/// Progress never moves backwards. If the worker-isolate apply fails part way
/// and the caller falls back to the inline apply, [restart] folds the three
/// inline passes into whatever share of the bar is still unspent.
class BaseApplyProgress {
  BaseApplyProgress(this._totalBytes, this._onProgress);

  static const int _passes = 3;

  final int _totalBytes;
  final void Function(double fraction)? _onProgress;
  final LoggerService _log = LoggerService.forClass(BaseApplyProgress);
  final Stopwatch _stopwatch = Stopwatch()..start();
  Duration _passStarted = Duration.zero;
  int _pass = 0;
  double _floor = 0.0;
  double _last = 0.0;

  /// Marks the start of zero-based [pass]; the previous pass is complete.
  void beginPass(int pass) {
    _logPassDone();
    _pass = pass;
    _emit(_pass / _passes);
  }

  /// Bytes of the file consumed so far in the current pass (inline path).
  void consumed(int bytes) => this.bytes(bytes, _totalBytes);

  /// Bytes of the file consumed so far in the current pass (worker path).
  void bytes(int consumed, int total) {
    final within = total <= 0 ? 1.0 : (consumed / total).clamp(0.0, 1.0);
    _emit((_pass + within) / _passes);
  }

  /// The apply is starting over from pass 1 (worker failed, inline fallback).
  /// Everything reported so far becomes the floor; the restarted passes fill
  /// the remainder, so the bar keeps moving and never rewinds.
  void restart() {
    _log.info(
      'Peer base apply restarting from pass 1 after '
      '${_stopwatch.elapsed.inSeconds}s',
    );
    _floor = _last;
    _pass = 0;
    _passStarted = _stopwatch.elapsed;
  }

  void done() {
    _logPassDone();
    _emit(1.0);
  }

  /// Logs the pass that just ended with its own duration and the running
  /// total, then starts timing the next one.
  void _logPassDone() {
    final now = _stopwatch.elapsed;
    _log.info(
      'Peer base pass ${_pass + 1}/$_passes done in '
      '${(now - _passStarted).inSeconds}s (${now.inSeconds}s total)',
    );
    _passStarted = now;
  }

  void _emit(double fraction) {
    final scaled = _floor + (1.0 - _floor) * fraction;
    if (scaled < _last) return;
    _last = scaled;
    _onProgress?.call(scaled);
  }
}
