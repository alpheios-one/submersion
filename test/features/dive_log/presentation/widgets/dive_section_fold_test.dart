import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/presentation/widgets/dive_section_fold.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

void main() {
  Widget host({
    required bool isExpanded,
    required ValueChanged<bool> onToggle,
    VoidCallback? onBuildContent,
    int? reorderIndex,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DiveSectionFold(
          title: 'Notes',
          icon: Icons.notes,
          isExpanded: isExpanded,
          onToggle: onToggle,
          reorderIndex: reorderIndex,
          contentBuilder: (context) {
            onBuildContent?.call();
            return const Text('CONTENT');
          },
        ),
      ),
    );
  }

  testWidgets('folded, it shows the title and no content', (tester) async {
    await tester.pumpWidget(host(isExpanded: false, onToggle: (_) {}));

    expect(find.text('Notes'), findsOneWidget);
    expect(find.byIcon(Icons.notes), findsOneWidget);
    expect(find.text('CONTENT'), findsNothing);
  });

  // The point of the list layout: twenty sections cost twenty header rows,
  // not twenty charts.
  testWidgets('folded, the content is never built', (tester) async {
    var built = 0;
    await tester.pumpWidget(
      host(isExpanded: false, onToggle: (_) {}, onBuildContent: () => built++),
    );
    await tester.pumpAndSettle();

    expect(built, 0);
  });

  testWidgets('unfolded, it shows the content', (tester) async {
    await tester.pumpWidget(host(isExpanded: true, onToggle: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('CONTENT'), findsOneWidget);
  });

  testWidgets('tapping the header asks for the opposite state', (tester) async {
    final requested = <bool>[];
    await tester.pumpWidget(host(isExpanded: false, onToggle: requested.add));

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(requested, [true]);

    await tester.pumpWidget(host(isExpanded: true, onToggle: requested.add));
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(requested, [true, false]);
  });

  // No Card of its own: the sections it folds bring their own, and a card
  // inside a card reads as a mistake.
  testWidgets('draws a divider rather than a card', (tester) async {
    await tester.pumpWidget(host(isExpanded: false, onToggle: (_) {}));

    expect(find.byType(Card), findsNothing);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('announces the action it will take to screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(isExpanded: false, onToggle: (_) {}));
    expect(
      find.bySemanticsLabel(RegExp('Expand Notes section')),
      findsOneWidget,
    );

    await tester.pumpWidget(host(isExpanded: true, onToggle: (_) {}));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp('Collapse Notes section')),
      findsOneWidget,
    );

    handle.dispose();
  });

  group('drag handle', () {
    testWidgets('there is none without a reorder index', (tester) async {
      await tester.pumpWidget(host(isExpanded: false, onToggle: (_) {}));

      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
    });

    testWidgets('a reorder index adds one', (tester) async {
      await tester.pumpWidget(
        host(isExpanded: false, onToggle: (_) {}, reorderIndex: 3),
      );

      expect(find.byIcon(Icons.drag_handle), findsOneWidget);
      final listener = tester.widget<ReorderableDragStartListener>(
        find.byType(ReorderableDragStartListener),
      );
      expect(listener.index, 3);
    });

    // The handle drags; it must not double as a fold toggle, or a missed
    // grab silently opens the section.
    testWidgets('tapping the handle does not toggle the fold', (tester) async {
      final toggles = <bool>[];
      await tester.pumpWidget(
        host(isExpanded: false, onToggle: toggles.add, reorderIndex: 0),
      );

      await tester.tap(find.byIcon(Icons.drag_handle));
      await tester.pumpAndSettle();
      expect(toggles, isEmpty);

      // The rest of the row still toggles.
      await tester.tap(find.text('Notes'));
      await tester.pumpAndSettle();
      expect(toggles, [true]);
    });
  });
}
