import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/media/presentation/widgets/ambiguous_dive_sheet.dart';

void main() {
  Widget host(String diveId, Dive? dive) {
    return ProviderScope(
      overrides: [diveProvider(diveId).overrideWith((ref) async => dive)],
      child: MaterialApp(
        home: Scaffold(
          body: AmbiguousDiveTile(diveId: diveId, onTap: () {}),
        ),
      ),
    );
  }

  testWidgets('a numbered dive shows its number', (tester) async {
    await tester.pumpWidget(
      host(
        'd1',
        Dive(id: 'd1', diveNumber: 7, dateTime: DateTime(2026, 6, 12)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('#7'), findsOneWidget);
  });

  testWidgets('a dive with no number, name, or site falls back to its id', (
    tester,
  ) async {
    // Nothing to show would otherwise be an empty title.
    await tester.pumpWidget(
      host('d1', Dive(id: 'd1', dateTime: DateTime(2026, 6, 12))),
    );
    await tester.pumpAndSettle();
    expect(find.text('d1'), findsOneWidget);
    expect(find.text(''), findsNothing);
  });
}
