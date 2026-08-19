import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/equipment/presentation/utils/service_type_label.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

void main() {
  test('every ServiceType has a non-empty English label', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    for (final type in ServiceType.values) {
      expect(type.label(l10n), isNotEmpty, reason: 'missing label for $type');
    }
  });

  test('German labels differ from the hardcoded English displayName', () async {
    final de = await AppLocalizations.delegate.load(const Locale('de'));
    expect(ServiceType.cleaning.label(de), 'Reinigung');
    expect(
      ServiceType.cleaning.label(de),
      isNot(ServiceType.cleaning.displayName),
    );
  });
}
