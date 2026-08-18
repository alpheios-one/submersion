import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/features/dive_log/data/services/profile_analysis_service.dart';
import 'package:submersion/features/dive_log/presentation/providers/profile_analysis_provider.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/statistics/data/repositories/deco_classification_cache.dart';

/// Fingerprint of every input that can change a computed classification.
///
/// Deliberately coarse: the dive's `updated_at` moves whenever the dive row or
/// its profile is written, so it stands in for a profile revision without
/// hashing the samples themselves. The separators matter, so that a shifted
/// digit in one field cannot impersonate its neighbour.
String decoInputsHash({
  required int engineVersion,
  required int gfLow,
  required int gfHigh,
  required int diveUpdatedAt,
}) => 'v$engineVersion/$gfLow-$gfHigh/$diveUpdatedAt';

/// Classifies dives that carry no recorded deco signal by running the same
/// analysis the dive detail page runs (#623).
///
/// Reading [profileAnalysisProvider] rather than reimplementing the deco test
/// is the point of the exercise: the bug was the statistics card and the dive
/// page answering the same question from different layers, and a second
/// implementation would let them drift apart again.
class DecoClassificationService {
  const DecoClassificationService();

  static final _log = LoggerService.forClass(DecoClassificationService);

  /// Returns `diveId -> hadDeco` for every dive in [revisions] that could be
  /// classified. [revisions] maps dive id to that dive's `dives.updated_at`,
  /// as returned by `StatisticsRepository.scanRecordedDecoSignals`.
  ///
  /// Dives whose analysis yields nothing (no usable profile) are absent from
  /// the result and stay unclassified rather than defaulting to no-deco.
  ///
  /// Cached answers are consulted per dive before any analysis runs, so a warm
  /// library does no compute at all. Uncached dives are processed in chunks
  /// with their analysis invalidated afterwards: [profileAnalysisProvider] and
  /// [analysisDiveProvider] are keepAlive families, so a library-wide pass
  /// would otherwise retain every profile's curves for the whole session.
  Future<Map<String, bool>> classify(
    Ref ref,
    Map<String, int> revisions, {
    int chunkSize = 25,
  }) async {
    if (revisions.isEmpty) return const {};

    // The analysis uses the dive's own gradient factors when it has both, and
    // the diver's settings otherwise, so both feed the fingerprint.
    final settingsGfLow = ref.read(gfLowProvider);
    final settingsGfHigh = ref.read(gfHighProvider);

    final cache = DecoClassificationCacheRepository();
    final results = <String, bool>{};
    final pending = revisions.keys.toList(growable: false);

    for (var start = 0; start < pending.length; start += chunkSize) {
      final end = start + chunkSize < pending.length
          ? start + chunkSize
          : pending.length;
      for (final diveId in pending.sublist(start, end)) {
        var analysisRead = false;
        try {
          final dive = await ref.read(analysisDiveProvider(diveId).future);
          if (dive == null) continue;

          final hash = decoInputsHash(
            engineVersion: analysisEngineVersion,
            gfLow: dive.gradientFactorLow ?? settingsGfLow,
            gfHigh: dive.gradientFactorHigh ?? settingsGfHigh,
            diveUpdatedAt: revisions[diveId]!,
          );

          final cached = await cache.getValid({diveId}, hash);
          final hit = cached[diveId];
          if (hit != null) {
            results[diveId] = hit;
            continue;
          }

          analysisRead = true;
          final analysis = await ref.read(
            profileAnalysisProvider(diveId).future,
          );
          if (analysis == null || analysis.ndlCurve.isEmpty) continue;

          final hadDeco = analysis.hadDecoObligation;
          results[diveId] = hadDeco;
          await cache.put(diveId, hadDeco: hadDeco, inputsHash: hash);
        } catch (e, stackTrace) {
          _log.error(
            'Failed to classify deco obligation for dive $diveId',
            error: e,
            stackTrace: stackTrace,
          );
        } finally {
          if (analysisRead) ref.invalidate(profileAnalysisProvider(diveId));
          ref.invalidate(analysisDiveProvider(diveId));
        }
      }
    }
    return results;
  }
}
