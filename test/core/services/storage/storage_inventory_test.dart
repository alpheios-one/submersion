import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/core/services/storage/storage_category.dart';
import 'package:submersion/core/services/storage/storage_inventory.dart';
import 'package:submersion/features/media_store/data/media_cache_store.dart';

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;
  late Directory temporary;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('storage_inventory_test');
    support = Directory(p.join(root.path, 'support'));
    documents = Directory(p.join(root.path, 'documents'));
    temporary = Directory(p.join(root.path, 'temporary'));
    for (final dir in [support, documents, temporary]) {
      await dir.create(recursive: true);
    }
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<void> writeFile(String absolute, int bytes) async {
    final file = File(absolute);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 0));
  }

  StorageInventory build({
    Future<int> Function(MediaCacheKind)? mediaCacheBytes,
    Future<double?> Function()? mapTileKibibytes,
    Future<int> Function()? networkImageBytes,
    Future<String?> Function()? backupsDirectoryPath,
    Future<String> Function()? databasePath,
  }) {
    return StorageInventory(
      supportDirectory: () async => support,
      documentsDirectory: () async => documents,
      temporaryDirectory: () async => temporary,
      databasePath:
          databasePath ?? () async => p.join(documents.path, 'submersion.db'),
      backupsDirectoryPath: backupsDirectoryPath ?? () async => null,
      mediaCacheBytes: mediaCacheBytes ?? (_) async => 0,
      mapTileKibibytes: mapTileKibibytes ?? () async => null,
      networkImageBytes: networkImageBytes ?? () async => 0,
    );
  }

  StorageCategory categoryFor(StorageInventory inventory, String id) =>
      inventory.categories.firstWhere((c) => c.id == id);

  test('exposes exactly the fourteen documented categories', () {
    final ids = build().categories.map((c) => c.id).toList();

    expect(ids, hasLength(14));
    expect(ids.toSet(), hasLength(14), reason: 'ids must be unique');
    expect(ids, contains(StorageCategoryId.database));
    expect(ids, contains(StorageCategoryId.exports));
  });

  test('the database category counts the file and its sidecars', () async {
    final dbPath = p.join(documents.path, 'submersion.db');
    await writeFile(dbPath, 100);
    await writeFile('$dbPath-wal', 40);
    await writeFile('$dbPath-shm', 10);

    final inventory = build(databasePath: () async => dbPath);

    expect(
      await categoryFor(inventory, StorageCategoryId.database).measure(),
      150,
    );
  });

  test('the local cache category measures submersion_local.db', () async {
    await writeFile(
      p.join(support.path, 'Submersion', 'submersion_local.db'),
      321,
    );

    expect(
      await categoryFor(build(), StorageCategoryId.localCache).measure(),
      321,
    );
  });

  test('each media cache pool reads its own indexed total', () async {
    final inventory = build(
      mediaCacheBytes: (kind) async => switch (kind) {
        MediaCacheKind.original => 1000,
        MediaCacheKind.thumb => 200,
        MediaCacheKind.rendition => 30,
      },
    );

    expect(
      await categoryFor(
        inventory,
        StorageCategoryId.mediaCacheOriginals,
      ).measure(),
      1000,
    );
    expect(
      await categoryFor(
        inventory,
        StorageCategoryId.mediaCacheThumbs,
      ).measure(),
      200,
    );
    expect(
      await categoryFor(
        inventory,
        StorageCategoryId.mediaCacheRenditions,
      ).measure(),
      30,
    );
  });

  test('staging and transcode are walked, not read from the index', () async {
    final cache = p.join(support.path, 'Submersion', 'media_cache');
    await writeFile(p.join(cache, 'staging', 'stage_1'), 70);
    await writeFile(p.join(cache, 'transcode', 'abc_high.mp4'), 900);

    final inventory = build();

    expect(
      await categoryFor(
        inventory,
        StorageCategoryId.mediaCacheStaging,
      ).measure(),
      70,
    );
    expect(
      await categoryFor(
        inventory,
        StorageCategoryId.mediaCacheTranscode,
      ).measure(),
      900,
    );
  });

  test('map tiles convert the FMTC kibibyte reading into bytes', () async {
    final inventory = build(mapTileKibibytes: () async => 4.0);

    expect(
      await categoryFor(inventory, StorageCategoryId.mapTiles).measure(),
      4096,
    );
  });

  test('map tiles report null when the store never initialized', () async {
    final inventory = build(mapTileKibibytes: () async => null);

    expect(
      await categoryFor(inventory, StorageCategoryId.mapTiles).measure(),
      isNull,
    );
  });

  test('the thumbnail categories walk their own directories', () async {
    await writeFile(
      p.join(support.path, 'Submersion', 'video_thumbnails', 'a.img'),
      12,
    );
    await writeFile(
      p.join(support.path, 'Submersion', 'pdf_thumbnails', 'b.jpg'),
      34,
    );

    final inventory = build();

    expect(
      await categoryFor(inventory, StorageCategoryId.videoThumbnails).measure(),
      12,
    );
    expect(
      await categoryFor(inventory, StorageCategoryId.pdfThumbnails).measure(),
      34,
    );
  });

  test('backups measure the resolved directory when there is one', () async {
    final backups = p.join(documents.path, 'Submersion', 'Backups');
    await writeFile(p.join(backups, 'backup.db'), 500);

    final inventory = build(backupsDirectoryPath: () async => backups);

    expect(
      await categoryFor(inventory, StorageCategoryId.backups).measure(),
      500,
    );
  });

  test('backups report null when the location cannot be enumerated', () async {
    final inventory = build(backupsDirectoryPath: () async => null);

    expect(
      await categoryFor(inventory, StorageCategoryId.backups).measure(),
      isNull,
    );
  });

  test('temporary counts picked files and loose share files', () async {
    await writeFile(p.join(temporary.path, 'picked', '0', 'dives.zip'), 800);
    await writeFile(p.join(temporary.path, 'shared_photo.jpg'), 60);

    expect(
      await categoryFor(build(), StorageCategoryId.temporary).measure(),
      860,
    );
  });

  test(
    'exports exclude the database, its sidecars and subdirectories',
    () async {
      final dbPath = p.join(documents.path, 'submersion.db');
      await writeFile(dbPath, 5000);
      await writeFile('$dbPath-wal', 400);
      await writeFile(
        p.join(documents.path, 'Submersion', 'Backups', 'b.db'),
        9,
      );
      await writeFile(p.join(documents.path, 'dives_export.csv'), 77);

      final inventory = build(databasePath: () async => dbPath);

      expect(
        await categoryFor(inventory, StorageCategoryId.exports).measure(),
        77,
      );
    },
  );

  test(
    'a database stored outside Documents leaves exports unaffected',
    () async {
      final elsewhere = Directory(p.join(root.path, 'elsewhere'));
      await elsewhere.create(recursive: true);
      final dbPath = p.join(elsewhere.path, 'submersion.db');
      await writeFile(dbPath, 5000);
      await writeFile(p.join(documents.path, 'dives_export.csv'), 77);

      final inventory = build(databasePath: () async => dbPath);

      expect(
        await categoryFor(inventory, StorageCategoryId.exports).measure(),
        77,
      );
    },
  );
}
