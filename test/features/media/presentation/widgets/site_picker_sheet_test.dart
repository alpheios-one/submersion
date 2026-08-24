import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/media/presentation/widgets/site_picker_sheet.dart';

void main() {
  Widget host(void Function(String?) onPicked) {
    return ProviderScope(
      overrides: [
        sitesProvider.overrideWith(
          (ref) async => const [
            DiveSite(id: 's1', name: 'Blue Hole'),
            DiveSite(id: 's2', name: 'Elphinstone'),
          ],
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  onPicked(await showSitePickerSheet(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('picking a site resolves its id', (tester) async {
    String? picked = 'sentinel';
    await tester.pumpWidget(host((id) => picked = id));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Blue Hole'), findsOneWidget);
    await tester.tap(find.text('Elphinstone'));
    await tester.pumpAndSettle();

    expect(picked, 's2');
  });

  testWidgets('dismissing resolves null', (tester) async {
    String? picked = 'sentinel';
    await tester.pumpWidget(host((id) => picked = id));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tap the barrier above the sheet.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(picked, isNull);
  });
}
