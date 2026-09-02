import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/divers/data/repositories/diver_weight_entry_repository.dart';
import 'package:submersion/features/divers/domain/entities/diver_weight_entry.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';

/// Repository provider
final diverWeightEntryRepositoryProvider = Provider<DiverWeightEntryRepository>(
  (ref) {
    return DiverWeightEntryRepository();
  },
);

/// Dated body-mass entries for the active diver, newest first.
///
/// Self-invalidates whenever the `diver_weight_entries` table changes (a
/// sync apply, a local create/edit/delete, ...).
final diverWeightEntriesProvider = FutureProvider<List<DiverWeightEntry>>((
  ref,
) async {
  final repository = ref.watch(diverWeightEntryRepositoryProvider);
  final diverId = await ref.watch(validatedCurrentDiverIdProvider.future);
  if (diverId == null) return const [];

  ref.invalidateSelfWhen(repository.watchChanges());

  return repository.getEntriesForDiver(diverId);
});

/// The active diver's most recent body-mass entry (null when none recorded).
final latestDiverWeightProvider = FutureProvider<DiverWeightEntry?>((
  ref,
) async {
  final entries = await ref.watch(diverWeightEntriesProvider.future);
  return entries.isEmpty ? null : entries.first;
});

/// The active diver's most recent recorded height in centimetres: the newest
/// entry that carries one. Height is optional per entry and changes far more
/// slowly than weight, so a newer weight-only entry must not discard it.
final latestDiverHeightProvider = FutureProvider<double?>((ref) async {
  final entries = await ref.watch(diverWeightEntriesProvider.future);
  for (final entry in entries) {
    if (entry.heightCm != null) return entry.heightCm;
  }
  return null;
});
