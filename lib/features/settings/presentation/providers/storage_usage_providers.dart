import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/local_cache_database_service.dart';
import 'package:submersion/core/services/storage/storage_category.dart';
import 'package:submersion/core/services/storage/storage_inventory.dart';
import 'package:submersion/features/backup/data/repositories/backup_preferences.dart';
import 'package:submersion/features/backup/data/services/backup_service.dart';
import 'package:submersion/features/maps/data/services/tile_cache_service.dart';
import 'package:submersion/features/media/data/services/cached_network_image_diagnostics.dart';
import 'package:submersion/features/media_store/data/media_cache_store.dart';
import 'package:submersion/features/settings/presentation/providers/storage_providers.dart';

/// The real inventory, wired to path_provider and the live services.
final storageInventoryProvider = Provider<StorageInventory>((ref) {
  // Memoized because the three media cache pools plus the two thumbnail
  // categories each resolve it, and it is a platform channel round trip that
  // returns the same immutable path every time for the life of the process.
  // The MediaCacheStore itself is rebuilt per call on purpose: it captures the
  // LocalCacheDatabase at construction, and caching one across the session
  // would hold a stale handle after a database location migration.
  Future<Directory>? supportDirectory;
  Future<Directory> resolveSupport() =>
      supportDirectory ??= getApplicationSupportDirectory();

  return StorageInventory(
    supportDirectory: resolveSupport,
    documentsDirectory: getApplicationDocumentsDirectory,
    temporaryDirectory: getTemporaryDirectory,
    databasePath: () =>
        ref.read(databaseLocationServiceProvider).getDatabasePath(),
    backupsDirectoryPath: _resolveBackupsDirectoryPath,
    mediaCacheBytes: (kind) async {
      final support = await resolveSupport();
      final store = MediaCacheStore(
        database: LocalCacheDatabaseService.instance.database,
        root: Directory(p.join(support.path, 'Submersion', 'media_cache')),
      );
      return store.totalBytes(kind);
    },
    mapTileKibibytes: _resolveMapTileKibibytes,
    networkImageBytes: () => CachedNetworkImageDiagnostics().cacheSize(),
  );
});

/// The descriptor list. Pure construction, so a plain Provider.
final storageCategoriesProvider = Provider<List<StorageCategory>>(
  (ref) => ref.watch(storageInventoryProvider).categories,
);

/// One future per category, keyed by [StorageCategory.id].
///
/// Keyed rather than a single future over the whole list so every row loads
/// independently: the media cache pools resolve instantly off an index while
/// the network image walk can take seconds, and a category that throws shows an
/// error on its own row instead of blanking the page.
final storageCategorySizeProvider = FutureProvider.family<int?, String>((
  ref,
  id,
) {
  final category = ref
      .watch(storageCategoriesProvider)
      .firstWhere((c) => c.id == id);
  return category.measure();
});

/// Returns null when the backup location cannot be enumerated as a directory.
///
/// An Android SAF location is a content:// tree URI with no Directory behind
/// it. Reporting it as zero bytes would tell the user their backups had
/// vanished, so it reports unavailable instead.
Future<String?> _resolveBackupsDirectoryPath() async {
  final prefs = await SharedPreferences.getInstance();
  final location = BackupPreferences(prefs).getSettings().backupLocation;
  if (location != null && location.startsWith('content://')) return null;
  if (location != null && location.isNotEmpty) return location;
  return BackupService.resolveDefaultBackupsDirectory();
}

/// Returns null when the tile store never initialized.
///
/// Startup swallows a tile cache initialization failure (see the tileCache step
/// in startup_page.dart), so an uninitialized store is a normal state rather
/// than a bug, and getTotalCacheSize would throw a StateError on it.
Future<double?> _resolveMapTileKibibytes() async {
  try {
    return await TileCacheService.instance.getTotalCacheSize();
  } on StateError {
    return null;
  }
}
