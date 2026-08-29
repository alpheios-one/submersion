import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/widgets/profile_photo/profile_photo_picker.dart';

import '../../../helpers/test_app.dart';

void main() {
  testWidgets('Contacts is hidden when no contactPhotoLoader is supplied', (
    tester,
  ) async {
    // allowContacts and contactPhotoLoader are separate parameters, so a
    // caller can ask for the option without supplying a way to fulfil it.
    // Offering it anyway would show a menu item that silently does nothing.
    await tester.pumpWidget(
      testApp(
        locale: const Locale('en'),
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => pickProfilePhoto(
              context: context,
              hasPhoto: false,
              allowContacts: true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Choose from Contacts'), findsNothing);
  });

  testWidgets('Contacts is shown when a loader is supplied', (tester) async {
    await tester.pumpWidget(
      testApp(
        locale: const Locale('en'),
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => pickProfilePhoto(
              context: context,
              hasPhoto: false,
              allowContacts: true,
              contactPhotoLoader: (_) async => Uint8List.fromList([1, 2, 3]),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Choose from Contacts'), findsOneWidget);
  });

  testWidgets('Remove Photo returns a removed result', (tester) async {
    ProfilePhotoResult? result;

    await tester.pumpWidget(
      testApp(
        locale: const Locale('en'),
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await pickProfilePhoto(
                context: context,
                hasPhoto: true,
                allowContacts: false,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Remove Photo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(result, isNotNull);
    expect(result!.removed, isTrue);
    expect(result!.bytes, isNull);
  });
}
