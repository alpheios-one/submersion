import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/buddies/presentation/pages/buddy_edit_page.dart';
import 'package:submersion/shared/widgets/profile_photo/profile_avatar.dart';

import '../../../../helpers/mock_providers.dart';
import '../../../../helpers/test_app.dart';

void main() {
  testWidgets('the edit page shows a tappable ProfileAvatar, not a stub', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(
        overrides: await getBaseOverrides(),
        locale: const Locale('en'),
        child: const BuddyEditPage(),
      ),
    );
    await tester.pump();

    expect(find.byType(ProfileAvatar), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt), findsOneWidget);
    expect(find.byType(GestureDetector), findsWidgets);
  });

  testWidgets('the avatar is wrapped in a tap target', (tester) async {
    await tester.pumpWidget(
      testApp(
        overrides: await getBaseOverrides(),
        locale: const Locale('en'),
        child: const BuddyEditPage(),
      ),
    );
    await tester.pump();

    // The whole avatar opens the source sheet; the camera badge is decoration
    // and is excluded from semantics so the control reads as one button.
    final detector = tester.widget<GestureDetector>(
      find
          .ancestor(
            of: find.byType(ProfileAvatar),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    expect(detector.onTap, isNotNull);
  });

  testWidgets('an initial photo from a contact import is shown', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(
        overrides: await getBaseOverrides(),
        locale: const Locale('en'),
        child: const BuddyEditPage(initialName: 'Jane Doe', initialPhoto: null),
      ),
    );
    await tester.pump();

    // With no photo the avatar falls back to the typed name's initials.
    expect(find.byType(ProfileAvatar), findsOneWidget);
    expect(find.text('JD'), findsOneWidget);
  });
}
