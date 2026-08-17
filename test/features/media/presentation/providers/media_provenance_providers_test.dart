import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_provenance.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/presentation/providers/media_provenance_providers.dart';
import 'package:submersion/features/media_store/data/media_stores_repository.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';

MediaItem _item({
  MediaSourceType sourceType = MediaSourceType.platformGallery,
  DateTime? remoteUploadedAt,
}) => MediaItem(
  id: 'm1',
  mediaType: MediaType.photo,
  sourceType: sourceType,
  platformAssetId: 'asset-1',
  remoteUploadedAt: remoteUploadedAt,
  takenAt: DateTime.utc(2026),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

class _FakeStoresRepository implements MediaStoresRepository {
  _FakeStoresRepository(this._active);

  final MediaStoreDescriptor? _active;

  @override
  Future<MediaStoreDescriptor?> getActive() async => _active;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

// Riverpod 3 does not export the `Override` type, so extra overrides travel
// as dynamic and are cast at the call site.
ProviderContainer _container({
  bool attached = true,
  QueueFacts? queue,
  List<dynamic> extra = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      mediaStoreAttachedProvider.overrideWith((ref) async => attached),
      mediaQueueFactsProvider.overrideWith((ref, id) => Stream.value(queue)),
      ...extra.cast(),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('composes row facts with the attached flag', () async {
    final c = _container();
    // Prime the async dependencies the synchronous provider reads through.
    await c.read(mediaStoreAttachedProvider.future);

    final p = c.read(mediaProvenanceProvider(_item()));

    expect(p.origin.sourceType, MediaSourceType.platformGallery);
    expect(p.origin.pointer, 'asset-1');
    expect(p.backup.storeAttached, isTrue);
    expect(p.backup.eligible, isTrue);
    expect(p.backup.tier, BackupTier.none);
  });

  test('reports the queue row when one exists', () async {
    final c = _container(
      queue: const QueueFacts(state: 'failed', error: 'network down'),
    );
    await c.read(mediaStoreAttachedProvider.future);
    c.listen(mediaQueueFactsProvider('m1'), (_, _) {});
    await Future<void>.delayed(Duration.zero);

    final p = c.read(mediaProvenanceProvider(_item()));

    expect(p.backup.queueState, 'failed');
    expect(p.backup.queueError, 'network down');
  });

  test('a detached store still yields provenance', () async {
    final c = _container(attached: false);
    await c.read(mediaStoreAttachedProvider.future);

    expect(
      c.read(mediaProvenanceProvider(_item())).backup.storeAttached,
      false,
    );
  });

  // This is the guard that keeps the PR 3 grid badge affordable. Building the
  // media store runtime does a keychain read, constructs the object store,
  // kicks a transfer-queue drain and can trigger an auto verify sweep, which
  // is exactly why mediaStoreAttachedProvider exists. If a later change makes
  // this provider reach for the runtime, a throwing override turns that into
  // a test failure instead of a stuttering grid nobody traces back here.
  test('does not build the media store runtime', () async {
    final c = _container(
      extra: [
        mediaStoreRuntimeProvider.overrideWith(
          (ref) async => throw StateError('runtime must not be built'),
        ),
      ],
    );
    await c.read(mediaStoreAttachedProvider.future);

    expect(() => c.read(mediaProvenanceProvider(_item())), returnsNormally);
    expect(c.read(mediaProvenanceProvider(_item())).origin.pointer, 'asset-1');
  });

  group('mediaStoreIdentityProvider', () {
    test('is null when no store is attached', () async {
      final c = _container(
        extra: [
          mediaStoresRepositoryProvider.overrideWithValue(
            _FakeStoresRepository(null),
          ),
        ],
      );

      expect(await c.read(mediaStoreIdentityProvider.future), isNull);
    });

    test('reports the active descriptor provider type and hint', () async {
      final c = _container(
        extra: [
          mediaStoresRepositoryProvider.overrideWithValue(
            _FakeStoresRepository((
              id: 's1',
              providerType: 's3',
              displayHint: 'dive-media @ minio.host',
              lastSweepAt: null,
            )),
          ),
        ],
      );

      final identity = await c.read(mediaStoreIdentityProvider.future);

      expect(identity!.providerType, 's3');
      expect(identity.displayHint, 'dive-media @ minio.host');
    });
  });

  test(
    'an unprimed attached flag reads as not attached rather than throwing',
    () {
      // The provider must never surface a loading state to a tile: a grid
      // builds synchronously and cannot await anything.
      final c = _container();

      final p = c.read(mediaProvenanceProvider(_item()));

      expect(p.backup.storeAttached, isFalse);
      expect(p.origin.pointer, 'asset-1');
    },
  );
}
