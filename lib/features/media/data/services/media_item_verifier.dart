import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/media_source_resolver_registry.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/services/media_source_resolver.dart';
import 'package:submersion/features/media/domain/value_objects/verify_result.dart';

/// Checks one media item's source and persists what it finds.
///
/// The only other caller of `MediaSourceResolver.verify` that writes the
/// result is `LocalFilesDiagnosticsService.reverifyAll`, which is a bulk
/// sweep wired directly to `LocalFileResolver` rather than dispatching
/// through the registry. This exists so a user can check a single item of
/// any source type, and it mirrors that service's persistence contract
/// exactly: a divergence would let a one-off check and the bulk sweep
/// disagree about the same row.
class MediaItemVerifier {
  MediaItemVerifier({
    required MediaSourceResolverRegistry registry,
    required MediaRepository repository,
    DateTime Function()? now,
  }) : _registry = registry,
       _repository = repository,
       _now = now ?? DateTime.now;

  final MediaSourceResolverRegistry _registry;
  final MediaRepository _repository;
  final DateTime Function() _now;

  Future<VerifyResult> verify(MediaItem item) async {
    final MediaSourceResolver resolver;
    try {
      resolver = _registry.resolverFor(item.sourceType);
    } on UnsupportedError {
      // A row whose source type has no registered resolver is a programmer
      // error, but the blast radius here must stay one item. Reporting a
      // transient failure and writing nothing is the honest outcome:
      // nothing was checked, so no verification date is owed either.
      return VerifyResult.transientError;
    }

    final result = await resolver.verify(item);
    final stamp = _now();

    // A volume that is not mounted, or a file that is present but
    // momentarily unreadable, is a recoverable condition rather than a dead
    // pointer. The orphan flag is sticky, so setting it here would leave the
    // row marked missing after the share came back.
    if (result == VerifyResult.volumeOffline ||
        result == VerifyResult.transientError) {
      await _repository.updateMedia(item.copyWith(lastVerifiedAt: stamp));
      return result;
    }

    await _repository.updateMedia(
      item.copyWith(
        isOrphaned: result != VerifyResult.available,
        lastVerifiedAt: stamp,
      ),
    );
    return result;
  }
}
