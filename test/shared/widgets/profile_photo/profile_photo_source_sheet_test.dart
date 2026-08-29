import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/widgets/profile_photo/profile_photo_source_sheet.dart';

import '../../../helpers/test_app.dart';

Future<void> _open(
  WidgetTester tester, {
  required bool hasPhoto,
  required bool allowContacts,
}) async {
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      child: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showProfilePhotoSourceSheet(
            context: context,
            hasPhoto: hasPhoto,
            allowContacts: allowContacts,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('hides Remove Photo when there is no photo', (tester) async {
    await _open(tester, hasPhoto: false, allowContacts: false);
    expect(find.text('Profile Photo'), findsOneWidget);
    expect(find.text('Remove Photo'), findsNothing);
  });

  testWidgets('shows Remove Photo when a photo exists', (tester) async {
    await _open(tester, hasPhoto: true, allowContacts: false);
    expect(find.text('Remove Photo'), findsOneWidget);
  });

  testWidgets('hides Choose from Contacts when not allowed', (tester) async {
    await _open(tester, hasPhoto: false, allowContacts: false);
    expect(find.text('Choose from Contacts'), findsNothing);
  });

  testWidgets('shows Choose from Contacts when allowed', (tester) async {
    await _open(tester, hasPhoto: false, allowContacts: true);
    expect(find.text('Choose from Contacts'), findsOneWidget);
  });

  testWidgets('always offers a library or file option', (tester) async {
    await _open(tester, hasPhoto: false, allowContacts: false);
    final hasLibrary = find.text('Choose from Library').evaluate().isNotEmpty;
    final hasFile = find.text('Choose File').evaluate().isNotEmpty;
    expect(hasLibrary || hasFile, isTrue);
  });

  testWidgets('tapping a source returns it', (tester) async {
    ProfilePhotoSource? chosen;

    await tester.pumpWidget(
      testApp(
        locale: const Locale('en'),
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              chosen = await showProfilePhotoSourceSheet(
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

    expect(chosen, ProfilePhotoSource.remove);
  });

  testWidgets('a source sheet with contacts allowed still lists the other '
      'options', (tester) async {
    await _open(tester, hasPhoto: true, allowContacts: true);
    expect(find.text('Choose from Contacts'), findsOneWidget);
    expect(find.text('Remove Photo'), findsOneWidget);
  });
}
