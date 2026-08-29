import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_field_table.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';

/// Columns of `dive_profiles` that identify the series, not the sample.
/// They live on the series row and are never packed.
const identityColumns = {
  'id',
  'dive_id',
  'computer_id',
  'source_id',
  'is_primary',
};

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('codec v1 covers every dive_profiles sample column, and only those', () {
    final tableColumns = {
      for (final column in db.diveProfiles.$columns) column.$name,
    };
    final expected = tableColumns.difference(identityColumns);
    final actual = {
      for (final field in ProfileSeriesCodec.fieldTableV1) field.name,
    };
    expect(
      actual,
      expected,
      reason:
          'A dive_profiles column was added or removed without a codec '
          'version. Append the field under a new version in '
          'ProfileSeriesCodec; never edit fieldTableV1.',
    );
  });

  test('each field kind matches its column type', () {
    final typeByName = {
      for (final column in db.diveProfiles.$columns) column.$name: column.type,
    };
    for (final field in ProfileSeriesCodec.fieldTableV1) {
      final type = typeByName[field.name];
      final expectedKind = switch (type) {
        DriftSqlType.int => ProfileFieldKind.deltaInt,
        DriftSqlType.double => ProfileFieldKind.float64,
        DriftSqlType.string => ProfileFieldKind.runLengthString,
        _ => fail('unexpected column type $type for ${field.name}'),
      };
      expect(field.kind, expectedKind, reason: field.name);
    }
  });

  test('the tank codec covers every tank_pressure_profiles sample column', () {
    const tankIdentity = {'id', 'dive_id', 'tank_id', 'computer_id'};
    final tableColumns = {
      for (final column in db.tankPressureProfiles.$columns) column.$name,
    };
    expect(tableColumns.difference(tankIdentity), {'timestamp', 'pressure'});
  });
}
