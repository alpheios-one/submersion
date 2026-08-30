import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_computer/data/repositories/transmitter_repository.dart';
import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';

/// Provider for the transmitter registry repository.
final transmitterRepositoryProvider = Provider<TransmitterRepository>((ref) {
  return TransmitterRepository();
});

/// Registry entries for a dive computer, ordered by channel index.
/// Refreshes automatically whenever the `transmitters` table changes.
final transmittersForComputerProvider =
    FutureProvider.family<List<TransmitterEntity>, String>((
      ref,
      diveComputerId,
    ) async {
      final repository = ref.watch(transmitterRepositoryProvider);
      ref.invalidateSelfWhen(repository.watchTransmittersChanges());
      return repository.getForComputer(diveComputerId);
    });

/// Channel indices actually seen in downloads from a dive computer, ordered
/// ascending. Refreshes automatically whenever `dive_tanks` changes (i.e.
/// after every import).
final usedChannelIndexesForComputerProvider =
    FutureProvider.family<List<int>, String>((ref, diveComputerId) async {
      final repository = ref.watch(transmitterRepositoryProvider);
      ref.invalidateSelfWhen(repository.watchDiveTanksChanges());
      return repository.getUsedChannelIndexes(diveComputerId);
    });

/// Channels seen in downloads that have no registry entry yet -- the
/// non-blocking "these channels aren't mapped" hint from issue #1365's
/// import step 3. Ordered ascending.
final unassignedChannelIndexesForComputerProvider =
    FutureProvider.family<List<int>, String>((ref, diveComputerId) async {
      final used = await ref.watch(
        usedChannelIndexesForComputerProvider(diveComputerId).future,
      );
      final mapped = await ref.watch(
        transmittersForComputerProvider(diveComputerId).future,
      );
      final mappedChannels = mapped.map((e) => e.channelIndex).toSet();
      return used.where((c) => !mappedChannels.contains(c)).toList();
    });

/// Mutations (create/update/delete) for a dive computer's transmitter
/// registry. List reads live on [transmittersForComputerProvider]; this
/// notifier just wraps the repository and lets a screen await the result of
/// a write without threading a `ref.invalidate` call through the UI.
class TransmitterListNotifier extends StateNotifier<AsyncValue<void>> {
  final TransmitterRepository _repository;
  final Ref _ref;
  final String diveComputerId;

  TransmitterListNotifier(this._repository, this._ref, this.diveComputerId)
    : super(const AsyncValue.data(null));

  Future<void> upsert(TransmitterEntity entry) async {
    state = const AsyncValue.loading();
    try {
      await _repository.upsert(entry);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    } finally {
      _ref.invalidate(transmittersForComputerProvider(diveComputerId));
    }
  }

  Future<void> delete(String id) async {
    state = const AsyncValue.loading();
    try {
      await _repository.delete(id);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    } finally {
      _ref.invalidate(transmittersForComputerProvider(diveComputerId));
    }
  }
}

final transmitterListNotifierProvider = StateNotifierProvider.autoDispose
    .family<TransmitterListNotifier, AsyncValue<void>, String>((
      ref,
      diveComputerId,
    ) {
      final repository = ref.watch(transmitterRepositoryProvider);
      return TransmitterListNotifier(repository, ref, diveComputerId);
    });
