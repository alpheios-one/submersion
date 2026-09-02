import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:submersion/features/media/data/services/local_bookmark_storage.dart';
import 'package:submersion/features/media/data/services/local_file_link_service.dart';
import 'package:submersion/features/media/data/services/local_media_platform.dart';
import 'package:submersion/features/media/presentation/providers/media_resolver_providers.dart';
import 'package:submersion/features/media/presentation/providers/photo_picker_providers.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_enqueue_provider.dart';

import 'local_file_link_service_provider_test.mocks.dart';

@GenerateMocks([LocalBookmarkStorage, LocalMediaPlatform])
void main() {
  test('localFileLinkServiceProvider assembles the service from its deps', () {
    final container = ProviderContainer(
      overrides: [
        localBookmarkStorageProvider.overrideWithValue(
          MockLocalBookmarkStorage(),
        ),
        localMediaPlatformProvider.overrideWithValue(MockLocalMediaPlatform()),
        mediaStoreEnqueueProvider.overrideWithValue((_) {}),
      ],
    );
    addTearDown(container.dispose);

    final service = container.read(localFileLinkServiceProvider);

    expect(service, isA<LocalFileLinkService>());
    expect(service.onMediaCreated, isNotNull);
  });
}
