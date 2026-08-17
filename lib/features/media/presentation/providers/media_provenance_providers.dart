import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_provenance.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';

/// The newest upload row for one media id, reduced to the domain shape.
///
/// Mirrors the guarding in [mediaBadgeStateProvider]: the repository resolves
/// its database lazily, so an uninitialized local cache surfaces a StateError
/// from `watchLatestForMedia` rather than from the watch, and both must sit
/// inside the guard. Widget tests routinely run without that database, and a
/// media item's provenance is not worth failing a tree over.
// no-tick: already reactive on a real change stream (watchLatestForMedia).
final mediaQueueFactsProvider = StreamProvider.family<QueueFacts?, String>((
  ref,
  mediaId,
) {
  try {
    return ref
        .watch(mediaTransferQueueRepositoryProvider)
        .watchLatestForMedia(mediaId)
        .map(
          (row) => row == null
              ? null
              : QueueFacts(state: row.state, error: row.errorMessage),
        );
  } on StateError {
    return Stream.value(null);
  }
});

/// Origin and backup facts for one media item.
///
/// Cheap by contract, because PR 3's grid badge derives from this on every
/// visible tile. It may watch [mediaStoreAttachedProvider] and
/// [mediaQueueFactsProvider]; it must NOT watch [mediaStoreRuntimeProvider]
/// or [mediaStoreStatusHintProvider], whose construction does a keychain
/// read, builds the object store, kicks a queue drain and can trigger a
/// verify sweep. A test pins that by overriding the runtime with a throwing
/// builder.
///
/// Both async dependencies are read through `.value` with a safe default, so
/// this never surfaces a loading state to a grid that has to build
/// synchronously. "Not yet known" reads the same as "not attached", which is
/// the conservative direction: it under-claims backup coverage rather than
/// over-claiming it.
final mediaProvenanceProvider = Provider.family<MediaProvenance, MediaItem>((
  ref,
  item,
) {
  final attached = ref.watch(mediaStoreAttachedProvider).value ?? false;
  final queue = ref.watch(mediaQueueFactsProvider(item.id)).value;
  return MediaProvenance.from(item, storeAttached: attached, queue: queue);
});

/// Which cloud store is attached, for display.
class MediaStoreIdentity {
  const MediaStoreIdentity({
    required this.providerType,
    required this.displayHint,
  });

  /// 's3', 'dropbox', 'googledrive' or 'icloud'.
  final String providerType;

  /// "bucket @ host" for S3; for the managed providers this is just the
  /// provider's own name, because that is all the connect flow records.
  final String displayHint;
}

/// The attached store's identity, or null when none is attached.
///
/// PANEL ONLY. Do not watch this from a grid tile. It reads the active store
/// descriptor, and its dependency chain can construct the store runtime,
/// which is the expensive path [mediaProvenanceProvider] is written to avoid.
///
/// Reads [MediaStoresRepository.getActive] directly rather than reusing
/// [mediaStoreStatusHintProvider], which collapses the provider type into the
/// hint string and loses the distinction the panel wants to show.
final mediaStoreIdentityProvider = FutureProvider<MediaStoreIdentity?>((
  ref,
) async {
  final descriptor = await ref.watch(mediaStoresRepositoryProvider).getActive();
  if (descriptor == null) return null;
  return MediaStoreIdentity(
    providerType: descriptor.providerType,
    displayHint: descriptor.displayHint,
  );
});
