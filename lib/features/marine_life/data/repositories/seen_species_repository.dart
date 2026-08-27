import 'package:drift/drift.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/marine_life/domain/entities/seen_species.dart';
import 'package:submersion/features/marine_life/domain/entities/species.dart'
    as domain;

/// Read-only queries behind the Species page: which species the diver has
/// seen, and where each one was seen.
///
/// Kept apart from `SpeciesRepository` (already at the file-size cap) and
/// from `StatisticsRepository`: unlike the statistics queries these never
/// take the Statistics filter, and they let errors propagate so the page can
/// show an error state instead of an empty list that lies.
class SeenSpeciesRepository {
  AppDatabase get _db => DatabaseService.instance.database;

  /// Every species with at least one sighting, with per-species aggregates.
  ///
  /// Scoped to [diverId] when given; every diver's dives otherwise. Inner
  /// joins drop species with no sightings. `COUNT(DISTINCT d.site_id)`
  /// ignores nulls, so dives without a site do not count as a site. No
  /// `ORDER BY`: the Species page sorts in Dart on the localized name.
  Future<List<SeenSpecies>> getSeenSpecies({String? diverId}) async {
    final diverClause = diverId != null ? 'AND d.diver_id = ?' : '';
    final rows = await _db
        .customSelect(
          '''
      SELECT sp.id, sp.common_name, sp.scientific_name, sp.category,
             sp.taxonomy_class, sp.description, sp.photo_path, sp.is_built_in,
             SUM(s.count) AS total_sightings,
             COUNT(DISTINCT d.id) AS dive_count,
             COUNT(DISTINCT d.site_id) AS site_count,
             MIN(d.dive_date_time) AS first_seen,
             MAX(d.dive_date_time) AS last_seen
      FROM species sp
      JOIN sightings s ON s.species_id = sp.id
      JOIN dives d ON d.id = s.dive_id
      WHERE 1=1 $diverClause
      GROUP BY sp.id
    ''',
          variables: [if (diverId != null) Variable.withString(diverId)],
        )
        .get();
    return rows.map(_seenSpeciesFromRow).toList();
  }

  SeenSpecies _seenSpeciesFromRow(QueryRow row) {
    return SeenSpecies(
      species: _speciesFromRow(row),
      totalSightings: row.read<int>('total_sightings'),
      diveCount: row.read<int>('dive_count'),
      siteCount: row.read<int>('site_count'),
      firstSeen: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('first_seen'),
      ),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(row.read<int>('last_seen')),
    );
  }

  domain.Species _speciesFromRow(QueryRow row) {
    final categoryName = row.read<String>('category');
    return domain.Species(
      id: row.read<String>('id'),
      commonName: row.read<String>('common_name'),
      scientificName: row.read<String?>('scientific_name'),
      category: SpeciesCategory.values.firstWhere(
        (c) => c.name == categoryName,
        orElse: () => SpeciesCategory.other,
      ),
      taxonomyClass: row.read<String?>('taxonomy_class'),
      description: row.read<String?>('description'),
      photoPath: row.read<String?>('photo_path'),
      isBuiltIn: row.read<bool>('is_built_in'),
    );
  }
}
