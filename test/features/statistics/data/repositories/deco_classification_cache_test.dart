import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/local_cache_database_service.dart';
import 'package:submersion/features/statistics/data/repositories/deco_classification_cache.dart';

void main() {
  late LocalCacheDatabase db;
  late DecoClassificationCacheRepository repo;

  setUp(() {
    db = LocalCacheDatabase(NativeDatabase.memory());
    LocalCacheDatabaseService.instance.setTestDatabase(db);
    repo = DecoClassificationCacheRepository();
  });

  tearDown(() async {
    await db.close();
    LocalCacheDatabaseService.instance.resetForTesting();
  });

  test('returns nothing before anything is cached', () async {
    expect(await repo.getValid({'a', 'b'}, 'hash-1'), isEmpty);
  });

  test('round-trips a classification', () async {
    await repo.put('a', hadDeco: true, inputsHash: 'hash-1');
    await repo.put('b', hadDeco: false, inputsHash: 'hash-1');

    expect(await repo.getValid({'a', 'b'}, 'hash-1'), {'a': true, 'b': false});
  });

  test('a stale inputs hash invalidates the entry', () async {
    await repo.put('a', hadDeco: true, inputsHash: 'hash-1');

    expect(await repo.getValid({'a'}, 'hash-2'), isEmpty);
  });

  test('re-putting the same dive replaces the entry', () async {
    await repo.put('a', hadDeco: true, inputsHash: 'hash-1');
    await repo.put('a', hadDeco: false, inputsHash: 'hash-2');

    expect(await repo.getValid({'a'}, 'hash-1'), isEmpty);
    expect(await repo.getValid({'a'}, 'hash-2'), {'a': false});
  });

  test('only the requested dives come back', () async {
    await repo.put('a', hadDeco: true, inputsHash: 'hash-1');
    await repo.put('b', hadDeco: true, inputsHash: 'hash-1');

    expect(await repo.getValid({'a'}, 'hash-1'), {'a': true});
  });

  test('an empty request does not query', () async {
    expect(await repo.getValid(const {}, 'hash-1'), isEmpty);
  });

  test('clear removes every entry', () async {
    await repo.put('a', hadDeco: true, inputsHash: 'hash-1');
    await repo.clear();

    expect(await repo.getValid({'a'}, 'hash-1'), isEmpty);
  });
}
