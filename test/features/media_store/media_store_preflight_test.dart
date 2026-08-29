import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/core/services/media_store/media_store_attach_state.dart';
import 'package:submersion/core/services/media_store/store_keys.dart';
import 'package:submersion/core/services/media_store/store_marker.dart';
import 'package:submersion/features/media_store/data/media_store_preflight.dart';

import '../../helpers/in_memory_media_object_store.dart';

/// The admission check the worker runs before every transfer (design spec
/// section 13): this device must still be attached to the store the runtime
/// was built for, and the bucket must still carry that store's marker.
void main() {
  late MediaStoreAttachState attachState;
  late InMemoryMediaObjectStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    attachState = MediaStoreAttachState(
      prefs: await SharedPreferences.getInstance(),
    );
    store = InMemoryMediaObjectStore();
  });

  void writeMarker(String storeId) {
    store.objects[StoreKeys.markerKey] = utf8.encode(
      jsonEncode({'storeId': storeId, 'formatVersion': 1, 'createdAt': ''}),
    );
  }

  Future<void> attach(String storeId) =>
      attachState.setAttached(storeId, providerType: CloudProviderType.icloud);

  test('passes when the container marker matches the attached store', () async {
    await attach('a');
    writeMarker('a');
    final preflight = MediaStorePreflight(
      attachState: attachState,
      store: store,
      attachedStoreId: 'a',
    );
    expect(await preflight(), isTrue);
  });

  test('suspends once this device has detached', () async {
    await attach('a');
    writeMarker('a');
    final preflight = MediaStorePreflight(
      attachState: attachState,
      store: store,
      attachedStoreId: 'a',
    );
    await attachState.clear();
    expect(await preflight(), isFalse);
  });

  test('suspends when the attachment changed under the runtime', () async {
    await attach('a');
    writeMarker('c');
    final preflight = MediaStorePreflight(
      attachState: attachState,
      store: store,
      attachedStoreId: 'a',
    );
    await attach('c');
    expect(await preflight(), isFalse);
  });

  test('suspends on a foreign marker when adoption is not offered', () async {
    await attach('a');
    writeMarker('b');
    final preflight = MediaStorePreflight(
      attachState: attachState,
      store: store,
      attachedStoreId: 'a',
    );
    expect(await preflight(), isFalse);
    expect(await attachState.attachedStoreId(), 'a');
  });

  // Issue #1356: on iCloud the container is the identity, so a marker this
  // device does not recognise can only be the app's own two-device race.
  // Adopting it is what the manual disconnect/reconnect workaround did.
  test(
    'adopts the container marker on a mismatch when adoption is offered',
    () async {
      await attach('a');
      writeMarker('b');
      final adopted = <String>[];
      final preflight = MediaStorePreflight(
        attachState: attachState,
        store: store,
        attachedStoreId: 'a',
        adoptMarker: (marker) async {
          adopted.add(marker.storeId);
          await attach(marker.storeId);
        },
      );

      expect(await preflight(), isTrue);
      expect(adopted, ['b']);
      expect(preflight.attachedStoreId, 'b');

      // Settled: the next check passes against the adopted id without
      // adopting again.
      expect(await preflight(), isTrue);
      expect(adopted, ['b']);
    },
  );

  test('suspends on a missing marker even when adoption is offered', () async {
    await attach('a');
    final adopted = <String>[];
    final preflight = MediaStorePreflight(
      attachState: attachState,
      store: store,
      attachedStoreId: 'a',
      adoptMarker: (marker) async => adopted.add(marker.storeId),
    );
    expect(await preflight(), isFalse);
    expect(adopted, isEmpty);
  });

  test(
    'a marker read that fails propagates for the worker to suspend on',
    () async {
      await attach('a');
      store.failNextWith = const MediaStoreException(
        'still downloading: smv1/store.json',
        kind: MediaStoreErrorKind.transient,
      );
      final preflight = MediaStorePreflight(
        attachState: attachState,
        store: store,
        attachedStoreId: 'a',
      );
      await expectLater(preflight(), throwsA(isA<MediaStoreException>()));
    },
  );

  test('exposes the marker it settled on', () async {
    await attach('a');
    writeMarker('a');
    final preflight = MediaStorePreflight(
      attachState: attachState,
      store: store,
      attachedStoreId: 'a',
    );
    await preflight();
    expect(preflight.attachedStoreId, 'a');
    expect(StoreMarker.fromJson({'storeId': 'a'})!.storeId, 'a');
  });
}
