import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/domain/blending/cylinder_template.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/cylinder_template_manager.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<WidgetRef> _pump(WidgetTester tester) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => _TestSettingsNotifier(const AppSettings()),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, _) {
                captured = ref;
                return const CylinderTemplateManager();
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('starts seeded with the blending-bench sizes', (tester) async {
    // Issue #1335 follow-up: seeded here the same way mix templates are, so
    // the billing card's dropdown has something to offer on a first run.
    final ref = await _pump(tester);
    expect(find.text('No saved cylinder sizes yet.'), findsNothing);
    expect(
      ref.read(blenderCylinderTemplatesProvider),
      CylinderTemplate.seedTemplates,
    );
  });

  testWidgets('adding a template appends it and persists', (tester) async {
    final ref = await _pump(tester);
    ref.read(blenderCylinderTemplatesProvider.notifier).state = const [];
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Deco bottle');
    await tester.enterText(find.byType(TextField).last, '3');
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(ref.read(blenderCylinderTemplatesProvider), const [
      CylinderTemplate(name: 'Deco bottle', liters: 3),
    ]);
    expect(find.text('Deco bottle'), findsOneWidget);
  });

  testWidgets('a duplicate is refused with a reason', (tester) async {
    final ref = await _pump(tester);
    ref.read(blenderCylinderTemplatesProvider.notifier).state = const [
      CylinderTemplate(name: 'Deco bottle', liters: 3),
    ];
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Deco bottle');
    await tester.enterText(find.byType(TextField).last, '3');
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(find.text('This cylinder size is already saved.'), findsOneWidget);
    expect(ref.read(blenderCylinderTemplatesProvider), hasLength(1));
  });

  testWidgets('a blank size is refused', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField).first, 'Deco bottle');
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(
      find.text('Enter a name and a size greater than zero.'),
      findsOneWidget,
    );
  });

  testWidgets('deleting removes the template', (tester) async {
    final ref = await _pump(tester);
    ref.read(blenderCylinderTemplatesProvider.notifier).state = const [
      CylinderTemplate(name: 'Deco bottle', liters: 3),
    ];
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();

    expect(ref.read(blenderCylinderTemplatesProvider), isEmpty);
  });
}
