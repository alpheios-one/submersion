import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/gas_calculators/domain/blending/flush_fee.dart';

void main() {
  group('FlushFeeMode', () {
    test('round-trips its name', () {
      expect(FlushFeeMode.fromName('perFill'), FlushFeeMode.perFill);
      expect(FlushFeeMode.fromName('perInvoice'), FlushFeeMode.perInvoice);
    });

    test('falls back to perInvoice for anything unrecognised', () {
      expect(FlushFeeMode.fromName(null), FlushFeeMode.perInvoice);
      expect(FlushFeeMode.fromName('nonsense'), FlushFeeMode.perInvoice);
    });
  });

  group('flushFeeCost', () {
    test('is null when the gas is unpriced', () {
      expect(flushFeeCost(20, null), isNull);
    });

    test('scales with the configured volume, per 100 litres', () {
      expect(flushFeeCost(20, 7.5), closeTo(1.5, 1e-9));
      expect(flushFeeCost(100, 7.5), closeTo(7.5, 1e-9));
    });
  });

  group('FlushFeeGasSetting', () {
    test('round-trips through JSON', () {
      const setting = FlushFeeGasSetting(volumeLiters: 20, pricePer100: 7.5);
      final decoded = FlushFeeGasSetting.fromJson(
        jsonDecode(jsonEncode(setting.toJson())),
        defaultVolumeLiters: 12,
      );
      expect(decoded.volumeLiters, 20);
      expect(decoded.pricePer100, 7.5);
    });

    test('falls back to the default volume when malformed', () {
      final decoded = FlushFeeGasSetting.fromJson(
        'not a map',
        defaultVolumeLiters: 15,
      );
      expect(decoded.volumeLiters, 15);
      expect(decoded.pricePer100, isNull);
    });

    test('copyWith can clear the price', () {
      const setting = FlushFeeGasSetting(volumeLiters: 20, pricePer100: 7.5);
      expect(setting.copyWith(clearPrice: true).pricePer100, isNull);
      expect(setting.copyWith(volumeLiters: 30).volumeLiters, 30);
    });
  });
}
