import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/core/services/media_store/media_store_attach_state.dart';
import 'package:submersion/core/services/media_store/store_marker.dart';

/// The admission check [MediaStoreWorker] runs before every transfer (design
/// spec section 13): this device must still be attached to the store the
/// runtime was built for, and the store must still carry that store's
/// marker. A false answer suspends the drain.
///
/// Attach state is re-read on every call, not captured: a disconnect can
/// land while a drain is running, and the rest of that drain must stop.
///
/// A marker that is present but not the attached one means the store was
/// wiped and re-minted, or repointed. The spec's answer is to suspend and let
/// the user decide; [adoptMarker], when supplied, is the one exception. On
/// iCloud the container is fixed per Apple ID, so a foreign marker can only be
/// the app's own two-device race (issue #1356), and the runtime passes an
/// adopter that re-attaches this device to it. A missing marker is never
/// adopted: there is nothing to adopt, and minting is the connect flow's job.
class MediaStorePreflight {
  MediaStorePreflight({
    required MediaStoreAttachState attachState,
    required MediaObjectStore store,
    required String attachedStoreId,
    Future<void> Function(StoreMarker marker)? adoptMarker,
  }) : _attachState = attachState,
       _store = store,
       _attachedStoreId = attachedStoreId,
       _adoptMarker = adoptMarker;

  final MediaStoreAttachState _attachState;
  final MediaObjectStore _store;
  final Future<void> Function(StoreMarker marker)? _adoptMarker;
  final _log = LoggerService.forClass(MediaStorePreflight);
  String _attachedStoreId;

  /// The store this check holds the runtime to: the id it was built with,
  /// or the marker it adopted since.
  String get attachedStoreId => _attachedStoreId;

  /// Whether the drain may proceed. Throws when the marker cannot be read;
  /// the worker treats that the same as a false answer.
  Future<bool> call() async {
    final currentId = await _attachState.attachedStoreId();
    if (currentId == null || currentId != _attachedStoreId) return false;
    final marker = await StoreMarkerStore(store: _store).read();
    if (marker == null) return false;
    if (marker.storeId == currentId) return true;
    final adopt = _adoptMarker;
    if (adopt == null) return false;
    _log.info(
      'Adopting media store marker ${marker.storeId} in place of $currentId',
    );
    await adopt(marker);
    _attachedStoreId = marker.storeId;
    return true;
  }
}
