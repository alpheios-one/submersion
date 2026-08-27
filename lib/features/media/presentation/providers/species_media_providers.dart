import 'package:submersion/core/providers/provider.dart';

import 'package:submersion/features/media/data/repositories/media_species_repository.dart';

final mediaSpeciesRepositoryProvider = Provider<MediaSpeciesRepository>((ref) {
  return MediaSpeciesRepository();
});

/// Photo-tag rows per species, the twin of `speciesSightingCountsProvider`:
/// the catalog manager refuses to delete a species that either one counts.
final speciesTagCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  final repository = ref.watch(mediaSpeciesRepositoryProvider);
  ref.invalidateSelfWhen(repository.watchTagChanges());
  return repository.tagCountsBySpecies();
});
