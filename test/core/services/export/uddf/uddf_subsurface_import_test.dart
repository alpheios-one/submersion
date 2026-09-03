import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/export/uddf/uddf_full_import_service.dart';
import 'package:submersion/core/services/export/uddf/uddf_import_parsers.dart';

/// A UDDF file shaped the way Subsurface's `xslt/uddf-export.xslt` writes one
/// (issue #239):
///
/// - the datetime is built as `concat(@date, 'T', @time)`, so a dive entered
///   by hand with no time is exported as a bare "2008-09-05T";
/// - trips live as `<trip>` children of a single `<divetrip>` container, and
///   each trip name is the Subsurface location and date joined by U+00A0;
/// - a dive points at its trip with `<tripmembership>`, not a `<link>`.
const _subsurfaceUddf = '''<?xml version="1.0" encoding="utf-8"?>
<uddf xmlns="http://www.streit.cc/uddf/3.2/" version="3.2.0">
  <generator>
    <name>Subsurface Divelog</name>
  </generator>
  <divesite>
    <site id="site1">
      <name>Klein Bonaire</name>
      <geography>
        <location>Klein Bonaire</location>
      </geography>
    </site>
  </divesite>
  <profiledata>
    <repetitiongroup id="rg1">
      <dive id="dive1">
        <informationbeforedive>
          <link ref="site1"/>
          <divenumber>12</divenumber>
          <datetime>2008-09-05T</datetime>
          <tripmembership ref="tripA"/>
        </informationbeforedive>
        <informationafterdive>
          <greatestdepth>18.3</greatestdepth>
          <diveduration>2400</diveduration>
        </informationafterdive>
      </dive>
      <dive id="dive2">
        <informationbeforedive>
          <link ref="site1"/>
          <divenumber>13</divenumber>
          <datetime>2008-09-07T10:15:00</datetime>
          <tripmembership ref="tripA"/>
        </informationbeforedive>
        <informationafterdive>
          <greatestdepth>22.1</greatestdepth>
          <diveduration>2700</diveduration>
        </informationafterdive>
      </dive>
    </repetitiongroup>
  </profiledata>
  <divetrip>
    <trip id="tripA">
      <name>Bonaire&#160;2008-09-05</name>
      <trippart>
        <name>Bonaire&#160;2008-09-05</name>
        <relateddives>
          <link ref="dive1"/>
          <link ref="dive2"/>
        </relateddives>
        <notes>
          <para>Shore diving week</para>
        </notes>
      </trippart>
    </trip>
  </divetrip>
</uddf>''';

/// The shape Submersion's own exporter writes: one `<divetrip>` per trip,
/// carrying an explicit `<dateoftrip>` range.
const _submersionUddf = '''<uddf version="3.2.1">
  <divetrip id="trip_abc">
    <name>Red Sea Liveaboard</name>
    <dateoftrip>
      <startdate>
        <datetime>2024-05-04T00:00:00.000</datetime>
      </startdate>
      <enddate>
        <datetime>2024-05-11T00:00:00.000</datetime>
      </enddate>
    </dateoftrip>
    <geography>
      <location>Egypt</location>
    </geography>
    <notes>Brothers and Daedalus</notes>
  </divetrip>
  <profiledata>
    <repetitiongroup id="rg1">
      <dive id="dive1">
        <informationbeforedive>
          <link ref="trip_abc"/>
          <datetime>2024-05-05T08:00:00</datetime>
        </informationbeforedive>
      </dive>
    </repetitiongroup>
  </profiledata>
</uddf>''';

void main() {
  group('UddfImportParsers.parseDiveDateTime', () {
    test('parses a full datetime as a wall clock stamped UTC', () {
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
    });

    test('reads a date with an empty time as midnight', () {
      // Subsurface writes concat(@date, 'T', @time); a dive with no recorded
      // time exports as a dangling "T" that DateTime.parse rejects outright.
      expect(
        UddfImportParsers.parseDiveDateTime('2008-09-05T'),
        DateTime.utc(2008, 9, 5),
      );
      expect(
        UddfImportParsers.parseDiveDateTime('2008-09-05T '),
        DateTime.utc(2008, 9, 5),
      );
    });

    test('reads a date-only value as midnight', () {
      expect(
        UddfImportParsers.parseDiveDateTime('2008-09-05'),
        DateTime.utc(2008, 9, 5),
      );
    });

    test('ignores a timezone suffix', () {
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30+02:00'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30Z'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
    });

    test('ignores a compact timezone offset', () {
      // "+0200" and "+02" are valid ISO 8601. Left in place, DateTime.parse
      // applies the offset and the wall clock is stored shifted by it.
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30+0200'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30-0500'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30+02'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
      expect(
        UddfImportParsers.parseDiveDateTime('2024-06-15T08:42:30.500+02:00'),
        DateTime.utc(2024, 6, 15, 8, 42, 30),
      );
    });

    test('does not mistake a date for a timezone offset', () {
      // The "-05" ending a bare date must not be stripped as an offset.
      expect(
        UddfImportParsers.parseDiveDateTime('2008-09-05'),
        DateTime.utc(2008, 9, 5),
      );
      expect(
        UddfImportParsers.parseDiveDateTime('2008-09-05T'),
        DateTime.utc(2008, 9, 5),
      );
    });

    test('returns null for empty and unparseable input', () {
      expect(UddfImportParsers.parseDiveDateTime(null), isNull);
      expect(UddfImportParsers.parseDiveDateTime(''), isNull);
      expect(UddfImportParsers.parseDiveDateTime('   '), isNull);
      expect(UddfImportParsers.parseDiveDateTime('T'), isNull);
      expect(UddfImportParsers.parseDiveDateTime('not a date'), isNull);
      expect(UddfImportParsers.parseDiveDateTime('2008-09'), isNull);
    });
  });

  group('Subsurface UDDF import (#239)', () {
    late UddfFullImportService service;

    setUp(() {
      service = UddfFullImportService();
    });

    test('keeps the file date of a dive exported without a time', () async {
      final result = await service.importAllDataFromUddf(_subsurfaceUddf);

      expect(result.dives, hasLength(2));
      expect(result.dives.first['dateTime'], DateTime.utc(2008, 9, 5));
      expect(result.dives.last['dateTime'], DateTime.utc(2008, 9, 7, 10, 15));
    });

    test('imports trips nested inside a divetrip container', () async {
      final result = await service.importAllDataFromUddf(_subsurfaceUddf);

      expect(result.trips, hasLength(1));
      final trip = result.trips.single;
      expect(trip['uddfId'], 'tripA');
      expect(trip['name'], 'Bonaire');
      expect(trip['location'], 'Bonaire');
      expect(trip['notes'], 'Shore diving week');
    });

    test('dates a trip from the dives that belong to it', () async {
      final result = await service.importAllDataFromUddf(_subsurfaceUddf);

      final trip = result.trips.single;
      expect(trip['startDate'], DateTime(2008, 9, 5));
      expect(trip['endDate'], DateTime(2008, 9, 7));
    });

    test('links dives to their trip through tripmembership', () async {
      final result = await service.importAllDataFromUddf(_subsurfaceUddf);

      expect(result.dives.first['tripRef'], 'tripA');
      expect(result.dives.last['tripRef'], 'tripA');
    });

    test(
      'offers no trip for the empty divetrip Subsurface always writes',
      () async {
        // A Subsurface logbook with no trips still exports <divetrip/>.
        const noTrips = '''<uddf version="3.2.0">
  <profiledata>
    <repetitiongroup id="rg1">
      <dive id="dive1">
        <informationbeforedive>
          <datetime>2024-05-05T08:00:00</datetime>
        </informationbeforedive>
      </dive>
    </repetitiongroup>
  </profiledata>
  <divetrip/>
</uddf>''';

        final result = await service.importAllDataFromUddf(noTrips);

        expect(result.dives, hasLength(1));
        expect(result.trips, isEmpty);
      },
    );

    test('does not leak the date recovered from a trip name', () async {
      // The trip maps travel across layers, and the payload merger copies
      // every key it finds when folding a duplicate trip from a second file,
      // so the scratch key has to be gone by the time parsing returns.
      final result = await service.importAllDataFromUddf(_subsurfaceUddf);

      expect(result.trips.single.containsKey('_nameDate'), isFalse);
    });

    test('dates a trip with no location from the date in its name', () async {
      // Subsurface names a trip "<location><NBSP><date>", so a trip with no
      // location is just the separator and the date. Dart counts U+00A0 as
      // whitespace, so the name arrives as the bare date once trimmed.
      const noLocation = '''<uddf version="3.2.0">
  <divetrip>
    <trip id="tripB">
      <name>&#160;2019-11-02</name>
    </trip>
  </divetrip>
</uddf>''';

      final result = await service.importAllDataFromUddf(noLocation);

      final trip = result.trips.single;
      expect(trip['name'], '2019-11-02');
      expect(trip['location'], isNull);
      expect(trip['startDate'], DateTime(2019, 11, 2));
      expect(trip['endDate'], DateTime(2019, 11, 2));
      expect(trip.containsKey('_nameDate'), isFalse);
    });

    test('still reads a divetrip that is itself the trip', () async {
      final result = await service.importAllDataFromUddf(_submersionUddf);

      expect(result.trips, hasLength(1));
      final trip = result.trips.single;
      expect(trip['uddfId'], 'trip_abc');
      expect(trip['name'], 'Red Sea Liveaboard');
      expect(trip['location'], 'Egypt');
      expect(trip['notes'], 'Brothers and Daedalus');
      // The explicit range wins over anything derived from the dives.
      expect(trip['startDate'], DateTime(2024, 5, 4));
      expect(trip['endDate'], DateTime(2024, 5, 11));
      expect(result.dives.single['tripRef'], 'trip_abc');
    });
  });
}
