import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';

/// Issue #1427: a dive with no water type of its own reports its site's.
void main() {
  DiveSite site({WaterType? waterType}) =>
      DiveSite(id: 'site', name: 'Site', waterType: waterType);

  Dive dive({WaterType? waterType, DiveSite? site}) => Dive(
    id: 'dive',
    dateTime: DateTime(2026),
    waterType: waterType,
    site: site,
  );

  test('falls back to the site when the dive has no water type', () {
    expect(
      dive(site: site(waterType: WaterType.salt)).effectiveWaterType,
      WaterType.salt,
    );
  });

  test("the dive's own value wins over the site's", () {
    expect(
      dive(
        waterType: WaterType.fresh,
        site: site(waterType: WaterType.salt),
      ).effectiveWaterType,
      WaterType.fresh,
    );
  });

  test('is null when neither the dive nor its site knows', () {
    expect(dive(site: site()).effectiveWaterType, isNull);
    expect(dive().effectiveWaterType, isNull);
  });
}
