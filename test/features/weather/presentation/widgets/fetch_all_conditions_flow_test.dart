import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/weather/data/services/bulk_conditions_service.dart';
import 'package:submersion/features/weather/data/services/weather_service.dart';
import 'package:submersion/features/weather/presentation/widgets/fetch_all_conditions_flow.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/test_database.dart';

String _payload() {
  final times = [
    for (var h = 0; h < 24; h++)
      '2024-06-15T${h.toString().padLeft(2, '0')}:00',
  ];
  return jsonEncode({
    'hourly': {
      'time': times,
      'temperature_2m': [for (var _ in times) 27.0],
      'relative_humidity_2m': [for (var _ in times) 70.0],
      'precipitation': [for (var _ in times) 0.0],
      'cloud_cover': [for (var _ in times) 10.0],
      'wind_speed_10m': [for (var _ in times) 18.0],
      'wind_direction_10m': [for (var _ in times) 90.0],
      'surface_pressure': [for (var _ in times) 1013.0],
      'weathercode': [for (var _ in times) 0],
    },
  });
}

void main() {
  late AppDatabase db;
  late DiveRepository repository;

  setUp(() async {
    db = await setUpTestDatabase();
    repository = DiveRepository();
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  Future<void> insertSite(String id, double lat, double lon) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.diveSites)
        .insert(
          DiveSitesCompanion.insert(
            id: id,
            name: 'Site $id',
            createdAt: now,
            updatedAt: now,
            latitude: Value(lat),
            longitude: Value(lon),
          ),
        );
  }

  Future<void> insertDive(String id, String siteId, DateTime at) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: id,
            diveDateTime: at.millisecondsSinceEpoch,
            createdAt: now,
            updatedAt: now,
            siteId: Value(siteId),
          ),
        );
  }

  ({Widget widget, List<Uri> requests}) harness() {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response(_payload(), 200);
    });
    final service = BulkConditionsService(
      diveRepository: repository,
      weatherService: WeatherService(client: client),
      requestDelay: Duration.zero,
    );
    return (
      widget: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Pin the locale so assertions read the English strings.
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showFetchAllConditionsFlow(
                context: context,
                service: service,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
      requests: requests,
    );
  }

  testWidgets('confirm dialog names how many dives are missing conditions', (
    tester,
  ) async {
    await insertSite('s1', 12.5, -68.25);
    await insertDive('d1', 's1', DateTime.utc(2024, 6, 15, 9));
    await insertDive('d2', 's1', DateTime.utc(2024, 6, 16, 9));

    final (:widget, :requests) = harness();
    await tester.pumpWidget(widget);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Fetch conditions?'), findsOneWidget);
    expect(
      find.textContaining('2 dives are missing conditions'),
      findsOneWidget,
    );
    expect(requests, isEmpty);
  });

  testWidgets('cancelling the confirm dialog fetches nothing', (tester) async {
    await insertSite('s1', 12.5, -68.25);
    await insertDive('d1', 's1', DateTime.utc(2024, 6, 15, 9));

    final (:widget, :requests) = harness();
    await tester.pumpWidget(widget);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(requests, isEmpty);
    final row = await (db.select(
      db.dives,
    )..where((t) => t.id.equals('d1'))).getSingle();
    expect(row.humidity, isNull);
  });

  testWidgets('confirming fills the dives and reports what it did', (
    tester,
  ) async {
    await insertSite('s1', 12.5, -68.25);
    await insertDive('d1', 's1', DateTime.utc(2024, 6, 15, 9));

    final (:widget, :requests) = harness();
    await tester.pumpWidget(widget);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();

    expect(find.text('Conditions fetched'), findsOneWidget);
    expect(find.textContaining('1 dive updated'), findsOneWidget);

    final row = await (db.select(
      db.dives,
    )..where((t) => t.id.equals('d1'))).getSingle();
    expect(row.humidity, 70.0);
  });

  testWidgets('says so when no dive is missing conditions', (tester) async {
    final (:widget, :requests) = harness();
    await tester.pumpWidget(widget);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Fetch conditions?'), findsNothing);
    expect(find.text('No dives are missing conditions.'), findsOneWidget);
    expect(requests, isEmpty);
  });
}
