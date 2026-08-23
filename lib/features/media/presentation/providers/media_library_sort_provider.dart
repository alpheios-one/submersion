import 'package:submersion/core/constants/sort_options.dart';
import 'package:submersion/core/models/sort_state.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/log_failure.dart';
import 'package:submersion/features/settings/data/repositories/app_settings_repository.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// Newest first, matching the ordering the library shipped with before a
/// sort control existed.
const SortState<MediaSortField> kDefaultMediaSort = SortState(
  field: MediaSortField.dateTaken,
  direction: SortDirection.descending,
);

/// Persisted form: `<field>:<direction>`, both enum names. Names are stable
/// across locales and devices, which is what makes the stored value portable.
String encodeMediaSort(SortState<MediaSortField> sort) =>
    '${sort.field.name}:${sort.direction.name}';

/// Decodes leniently. A value written by a newer build, or a corrupted
/// setting, yields null so the caller can fall back rather than throwing and
/// taking the library view down with it.
SortState<MediaSortField>? decodeMediaSort(String raw) {
  final parts = raw.split(':');
  if (parts.length != 2) return null;
  final field = MediaSortField.values
      .where((f) => f.name == parts[0])
      .firstOrNull;
  final direction = SortDirection.values
      .where((d) => d.name == parts[1])
      .firstOrNull;
  if (field == null || direction == null) return null;
  return SortState(field: field, direction: direction);
}

/// The library's active sort, persisted through the app settings key-value
/// store exactly as MediaLibraryViewModeNotifier persists the view mode.
///
/// Deliberately NOT part of MediaLibraryFilter: sort is a view preference,
/// and folding it into the filter would add a field to every serialized
/// smart album.
final mediaLibrarySortProvider =
    StateNotifierProvider<MediaLibrarySortNotifier, SortState<MediaSortField>>((
      ref,
    ) {
      return MediaLibrarySortNotifier(ref.watch(appSettingsRepositoryProvider));
    });

class MediaLibrarySortNotifier
    extends StateNotifier<SortState<MediaSortField>> {
  MediaLibrarySortNotifier(this._settings) : super(kDefaultMediaSort) {
    logFailure(_prime(), MediaLibrarySortNotifier, 'prime');
  }

  static const String settingKey = 'media_library_sort';

  final AppSettingsRepository _settings;

  Future<void> _prime() async {
    final raw = await _settings.getRawSetting(settingKey);
    if (!mounted || raw == null) return;
    final decoded = decodeMediaSort(raw);
    if (decoded != null) state = decoded;
  }

  Future<void> setSort(MediaSortField field, SortDirection direction) async {
    state = SortState(field: field, direction: direction);
    await _settings.setRawSetting(settingKey, encodeMediaSort(state));
  }
}
