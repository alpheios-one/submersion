import 'package:equatable/equatable.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_summary.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:uuid/uuid.dart';

/// Namespace for [profileSeriesMigratedId]. Fixed forever: changing it would
/// make two devices that migrate the same rows disagree on the series id.
const String kProfileSeriesNamespace = '7c2d9b1e-4f3a-4e8b-9c5d-2a1f6e8b3d47';

/// Namespace for [tankPressureSeriesMigratedId].
const String kTankPressureSeriesNamespace =
    'b8e1f2c3-5d6a-4b7c-8e9f-1a2b3c4d5e6f';

/// The series id the v182 migration assigns to a packed
/// (dive, computer, source, is_primary) group.
///
/// Every device runs the migration independently. A random id per device
/// would let sync union two primary series per dive, the duplicate
/// dive-types shape of issue #1360. Deriving the id from the identity tuple
/// makes devices that hold the same synced sample rows converge on upsert.
/// Only the migration uses this; repository writes mint uuid v4, because a
/// fresh download or edit genuinely is a new series.
///
/// Absent members are spelled `null` in the key (spec section 8). A member
/// that is literally the string "null" would collide with absence, and
/// cannot occur: every member is a uuid.
String profileSeriesMigratedId({
  required String diveId,
  required String? computerId,
  required String? sourceId,
  required bool isPrimary,
}) => const Uuid().v5(
  kProfileSeriesNamespace,
  '$diveId|${computerId ?? 'null'}|${sourceId ?? 'null'}|${isPrimary ? 1 : 0}',
);

/// The series id the v182 migration assigns to a packed
/// (dive, tank, computer) pressure group. See [profileSeriesMigratedId].
String tankPressureSeriesMigratedId({
  required String diveId,
  required String tankId,
  required String? computerId,
}) => const Uuid().v5(
  kTankPressureSeriesNamespace,
  '$diveId|$tankId|${computerId ?? 'null'}',
);

/// One packed profile series: the identity columns of a
/// `dive_profile_series` row, its summary scalars, and its decoded samples.
class ProfileSeries extends Equatable {
  const ProfileSeries({
    required this.id,
    required this.diveId,
    this.computerId,
    this.sourceId,
    required this.isPrimary,
    required this.summary,
    required this.samples,
    required this.codecVersion,
    required this.createdAt,
    required this.updatedAt,
    this.hlc,
  });

  final String id;
  final String diveId;
  final String? computerId;
  final String? sourceId;
  final bool isPrimary;
  final ProfileSeriesSummary summary;
  final List<ProfileSample> samples;
  final int codecVersion;
  final int createdAt;
  final int updatedAt;
  final String? hlc;

  /// The samples as the chart and analysis pipeline consume them.
  List<DiveProfilePoint> get points => [
    for (final sample in samples) sample.toPoint(),
  ];

  ProfileSeries copyWith({
    String? id,
    String? diveId,
    String? computerId,
    bool clearComputerId = false,
    String? sourceId,
    bool clearSourceId = false,
    bool? isPrimary,
    ProfileSeriesSummary? summary,
    List<ProfileSample>? samples,
    int? codecVersion,
    int? createdAt,
    int? updatedAt,
    String? hlc,
    bool clearHlc = false,
  }) {
    return ProfileSeries(
      id: id ?? this.id,
      diveId: diveId ?? this.diveId,
      computerId: clearComputerId ? null : (computerId ?? this.computerId),
      sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
      isPrimary: isPrimary ?? this.isPrimary,
      summary: summary ?? this.summary,
      samples: samples ?? this.samples,
      codecVersion: codecVersion ?? this.codecVersion,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      hlc: clearHlc ? null : (hlc ?? this.hlc),
    );
  }

  @override
  List<Object?> get props => [
    id,
    diveId,
    computerId,
    sourceId,
    isPrimary,
    summary,
    samples,
    codecVersion,
    createdAt,
    updatedAt,
    hlc,
  ];
}

/// One packed tank pressure series: a `tank_pressure_series` row decoded.
class TankPressureSeries extends Equatable {
  const TankPressureSeries({
    required this.id,
    required this.diveId,
    required this.tankId,
    this.computerId,
    required this.summary,
    required this.samples,
    required this.codecVersion,
    required this.createdAt,
    required this.updatedAt,
    this.hlc,
  });

  final String id;
  final String diveId;
  final String tankId;
  final String? computerId;
  final TankPressureSeriesSummary summary;
  final List<TankPressureSample> samples;
  final int codecVersion;
  final int createdAt;
  final int updatedAt;
  final String? hlc;

  TankPressureSeries copyWith({
    String? id,
    String? diveId,
    String? tankId,
    String? computerId,
    bool clearComputerId = false,
    TankPressureSeriesSummary? summary,
    List<TankPressureSample>? samples,
    int? codecVersion,
    int? createdAt,
    int? updatedAt,
    String? hlc,
    bool clearHlc = false,
  }) {
    return TankPressureSeries(
      id: id ?? this.id,
      diveId: diveId ?? this.diveId,
      tankId: tankId ?? this.tankId,
      computerId: clearComputerId ? null : (computerId ?? this.computerId),
      summary: summary ?? this.summary,
      samples: samples ?? this.samples,
      codecVersion: codecVersion ?? this.codecVersion,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      hlc: clearHlc ? null : (hlc ?? this.hlc),
    );
  }

  @override
  List<Object?> get props => [
    id,
    diveId,
    tankId,
    computerId,
    summary,
    samples,
    codecVersion,
    createdAt,
    updatedAt,
    hlc,
  ];
}
