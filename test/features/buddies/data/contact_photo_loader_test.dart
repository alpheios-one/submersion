import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/buddies/data/services/contact_photo_loader.dart';

import '../../../helpers/test_app.dart';

Contact _contact({Uint8List? fullSize, Uint8List? thumbnail}) => Contact(
  id: 'c1',
  displayName: 'Jane Doe',
  photo: fullSize == null && thumbnail == null
      ? null
      : Photo(fullSize: fullSize, thumbnail: thumbnail),
);

/// Runs [loadContactPhoto] with the native picker replaced and returns its
/// result plus the built context, so snackbars can be asserted.
Future<Uint8List?> _run(
  WidgetTester tester,
  Future<Contact?> Function() picker,
) async {
  Uint8List? result;
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      child: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await loadContactPhoto(
              context,
              pickContactOverride: picker,
            );
          },
          child: const Text('load'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('load'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return result;
}

void main() {
  testWidgets('prefers the full resolution photo over the thumbnail', (
    tester,
  ) async {
    // A contact thumbnail is typically 96x96 or 150x150, well under the 512
    // the codec stores, so it is a fallback rather than a preference.
    final full = Uint8List.fromList([1, 1, 1, 1]);
    final thumb = Uint8List.fromList([2, 2]);

    final result = await _run(
      tester,
      () async => _contact(fullSize: full, thumbnail: thumb),
    );

    expect(result, full);
  });

  testWidgets('falls back to the thumbnail when there is no full size', (
    tester,
  ) async {
    final thumb = Uint8List.fromList([2, 2]);

    final result = await _run(tester, () async => _contact(thumbnail: thumb));

    expect(result, thumb);
  });

  testWidgets('a contact with no photo reports it plainly, not as an error', (
    tester,
  ) async {
    final result = await _run(tester, () async => _contact());

    expect(result, isNull);
    expect(find.text('That contact does not have a photo.'), findsOneWidget);
  });

  testWidgets('cancelling the picker returns null and says nothing', (
    tester,
  ) async {
    final result = await _run(tester, () async => null);

    expect(result, isNull);
    // Cancelling is not a failure, so no message is shown.
    expect(find.text('That contact does not have a photo.'), findsNothing);
  });

  test('property access needs no permission off Android', () {
    // The native picker is permissionless on both platforms, and asking it for
    // properties always works on iOS. Only Android needs READ_CONTACTS, which
    // is why the iOS build shows no address-book prompt for a contact photo.
    if (Platform.isAndroid) return;
    expectLater(ensureContactPropertyAccess(), completion(isTrue));
  });
}
