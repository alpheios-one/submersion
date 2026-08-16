import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/features/media/data/services/media_serving_recorder.dart';

/// Process-wide recorder of how each media item was most recently resolved.
///
/// A plain Provider with a concrete default, so no consumer test needs an
/// override to construct a widget tree that renders media. Tests that want
/// to assert on what was recorded override it with their own instance.
final mediaServingRecorderProvider = Provider<MediaServingRecorder>(
  (ref) => MediaServingRecorder(),
);
