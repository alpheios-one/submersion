import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_polyline_layer.dart';

NavTrack _route({GeoPoint? anchor, List<NavTrackPoint> points = const []}) =>
    NavTrack(
      id: 'r1',
      source: NavTrackSource.seacraftEnc,
      sourceRef: 'r1.csv',
      startTime: 1755856800000,
      endTime: 1755860400000,
      pointCount: points.length,
      anchorLatitude: anchor?.latitude,
      anchorLongitude: anchor?.longitude,
      points: points,
      createdAt: DateTime(2026, 8, 22),
      updatedAt: DateTime(2026, 8, 22),
    );

void main() {
  testWidgets('renders nothing without an anchor', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            options: const MapOptions(initialCenter: LatLng(0, 0)),
            children: [
              NavTrackPolylineLayer(
                route: _route(
                  points: [
                    const NavTrackPoint(
                      timestamp: 0,
                      north: 0,
                      east: 0,
                      depth: 1,
                    ),
                    const NavTrackPoint(
                      timestamp: 10,
                      north: 5,
                      east: 5,
                      depth: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(PolylineLayer), findsNothing);
    expect(find.byType(MarkerLayer), findsNothing);
  });

  testWidgets('draws polylines and start/end glyphs once anchored', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            options: const MapOptions(initialCenter: LatLng(47.0, 8.0)),
            children: [
              NavTrackPolylineLayer(
                route: _route(
                  anchor: const GeoPoint(47.0, 8.0),
                  points: [
                    const NavTrackPoint(
                      timestamp: 0,
                      north: 0,
                      east: 0,
                      depth: 1,
                    ),
                    const NavTrackPoint(
                      timestamp: 10,
                      north: 5,
                      east: 5,
                      depth: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.byType(MarkerLayer), findsOneWidget);
  });
}
