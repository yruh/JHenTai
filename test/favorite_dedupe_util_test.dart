import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/utils/favorite_dedupe_util.dart';

void main() {
  group('resolveFavoriteTorrentBatchOutcome', () {
    test('noneFound only when zero magnets and zero failures', () {
      expect(
        resolveFavoriteTorrentBatchOutcome(magnetCount: 0, failureCount: 0),
        FavoriteTorrentBatchOutcome.noneFound,
      );
    });

    test('unavailable when zero magnets and failures > 0 (never copied)', () {
      expect(
        resolveFavoriteTorrentBatchOutcome(magnetCount: 0, failureCount: 3),
        FavoriteTorrentBatchOutcome.unavailable,
      );
    });

    test('copied whenever magnets exist, regardless of failures', () {
      expect(
        resolveFavoriteTorrentBatchOutcome(magnetCount: 2, failureCount: 0),
        FavoriteTorrentBatchOutcome.copied,
      );
      expect(
        resolveFavoriteTorrentBatchOutcome(magnetCount: 1, failureCount: 5),
        FavoriteTorrentBatchOutcome.copied,
      );
    });
  });

  group('favoriteTorrentsCopiedParams / unavailableParams', () {
    test('copied params always include gallery, torrent, failed counts', () {
      expect(
        favoriteTorrentsCopiedParams(galleryCount: 2, torrentCount: 5, failedCount: 1),
        {
          'galleryCount': '2',
          'torrentCount': '5',
          'failedCount': '1',
        },
      );
    });

    test('unavailable params only carry failedCount', () {
      expect(
        favoriteTorrentsUnavailableParams(failedCount: 4),
        {'failedCount': '4'},
      );
    });
  });

  group('normalizeFavoriteTitle / category', () {
    test('trims, collapses whitespace, and lower-cases title', () {
      expect(normalizeFavoriteTitle('  Foo   BAR\tbaz  '), 'foo bar baz');
    });

    test('does not strip punctuation or brackets from title', () {
      expect(normalizeFavoriteTitle('[Artist] Title!'), '[artist] title!');
    });

    test('normalizeFavoriteCategory trims and lower-cases', () {
      expect(normalizeFavoriteCategory('  Doujinshi '), 'doujinshi');
      expect(normalizeFavoriteCategory('   '), isEmpty);
    });
  });

  group('buildFavoriteDedupeKey', () {
    test('is stable across case and whitespace in title', () {
      final String? a = buildFavoriteDedupeKey(category: 'Doujinshi', title: 'Hello  World');
      final String? b = buildFavoriteDedupeKey(category: 'Doujinshi', title: 'hello world');
      expect(a, isNotNull);
      expect(a, b);
    });

    test('treats different categories as different keys', () {
      final String? a = buildFavoriteDedupeKey(category: 'Doujinshi', title: 'Same');
      final String? b = buildFavoriteDedupeKey(category: 'Manga', title: 'Same');
      expect(a, isNot(b));
    });

    test('category is compared case-insensitively', () {
      final String? a = buildFavoriteDedupeKey(category: 'Doujinshi', title: 'Title');
      final String? b = buildFavoriteDedupeKey(category: 'doujinshi', title: 'Title');
      expect(a, b);
    });

    test('returns null for empty normalized title or category', () {
      expect(buildFavoriteDedupeKey(category: 'Doujinshi', title: '   '), isNull);
      expect(buildFavoriteDedupeKey(category: '  ', title: 'Title'), isNull);
      expect(buildFavoriteDedupeKey(category: '', title: ''), isNull);
    });
  });

  group('findFavoriteDuplicates', () {
    test('keeps first in order and returns later matches', () {
      final List<({int id, String category, String title})> items = [
        (id: 1, category: 'Doujinshi', title: 'Alpha'),
        (id: 2, category: 'Manga', title: 'Beta'),
        (id: 3, category: 'Doujinshi', title: '  alpha '),
        (id: 4, category: 'Doujinshi', title: 'Alpha'),
        (id: 5, category: 'Manga', title: 'Beta'),
      ];

      final List<({int id, String category, String title})> duplicates = findFavoriteDuplicates(
        items: items,
        categoryOf: (item) => item.category,
        titleOf: (item) => item.title,
      );

      expect(duplicates.map((e) => e.id).toList(), [3, 4, 5]);
    });

    test('returns empty when all unique', () {
      final List<({String category, String title})> items = [
        (category: 'A', title: '1'),
        (category: 'A', title: '2'),
        (category: 'B', title: '1'),
      ];

      expect(
        findFavoriteDuplicates(
          items: items,
          categoryOf: (item) => item.category,
          titleOf: (item) => item.title,
        ),
        isEmpty,
      );
    });

    test('skips empty normalized title or category and never marks them duplicates', () {
      final List<({int id, String category, String title})> items = [
        (id: 1, category: 'Doujinshi', title: '   '),
        (id: 2, category: 'Doujinshi', title: '   '),
        (id: 3, category: '  ', title: 'Same'),
        (id: 4, category: '', title: 'Same'),
        (id: 5, category: 'Manga', title: 'Keep'),
        (id: 6, category: 'Manga', title: 'keep'),
      ];

      final List<({int id, String category, String title})> duplicates = findFavoriteDuplicates(
        items: items,
        categoryOf: (item) => item.category,
        titleOf: (item) => item.title,
      );

      // Only id 6 is a real duplicate of id 5; empty title/category items are skipped.
      expect(duplicates.map((e) => e.id).toList(), [6]);
    });
  });

  group('reconcileFavoriteMetadataChunk', () {
    test('matches by requested gid, uses first response row, counts missing', () {
      final List<({int gid, String token})> requested = [
        (gid: 1, token: 'aaaaaaaaaa'),
        (gid: 2, token: 'bbbbbbbbbb'),
        (gid: 3, token: 'cccccccccc'),
        (gid: 4, token: 'dddddddddd'),
      ];

      final ({List<({int gid, String token})> withTorrents, int missingCount}) result =
          reconcileFavoriteMetadataChunk(
        requested: requested,
        gidOf: (item) => item.gid,
        responseItems: [
          (gid: 1, torrentCount: 2),
          (gid: 2, torrentCount: 0),
          // duplicate gid 1 - ignored
          (gid: 1, torrentCount: 99),
          // non-requested gid - ignored
          (gid: 99, torrentCount: 5),
          // gid 3 missing entirely
          (gid: 4, torrentCount: 1),
        ],
      );

      expect(result.missingCount, 1); // gid 3
      expect(result.withTorrents.map((e) => e.gid).toList(), [1, 4]);
      // Original request tokens preserved (not from any response row).
      expect(result.withTorrents.map((e) => e.token).toList(), ['aaaaaaaaaa', 'dddddddddd']);
    });

    test('all missing when response is empty', () {
      final ({List<int> withTorrents, int missingCount}) result = reconcileFavoriteMetadataChunk(
        requested: [10, 20],
        gidOf: (int gid) => gid,
        responseItems: const [],
      );
      expect(result.missingCount, 2);
      expect(result.withTorrents, isEmpty);
    });

    test('zero-torrent rows are accounted without failure or withTorrents', () {
      final ({List<int> withTorrents, int missingCount}) result = reconcileFavoriteMetadataChunk(
        requested: [1, 2],
        gidOf: (int gid) => gid,
        responseItems: [
          (gid: 1, torrentCount: 0),
          (gid: 2, torrentCount: 0),
        ],
      );
      expect(result.missingCount, 0);
      expect(result.withTorrents, isEmpty);
    });
  });

  group('collectUniqueNonOutdatedMagnets', () {
    test('skips outdated and empty, de-dupes magnets', () {
      final List<String> magnets = collectUniqueNonOutdatedMagnets(
        torrents: [
          (magnetUrl: 'magnet:?xt=urn:btih:aaa', outdated: false),
          (magnetUrl: 'magnet:?xt=urn:btih:bbb', outdated: true),
          (magnetUrl: 'magnet:?xt=urn:btih:aaa', outdated: false),
          (magnetUrl: '  ', outdated: false),
          (magnetUrl: 'magnet:?xt=urn:btih:ccc', outdated: false),
        ],
      );

      expect(magnets, [
        'magnet:?xt=urn:btih:aaa',
        'magnet:?xt=urn:btih:ccc',
      ]);
    });
  });

  group('chunkList', () {
    test('partitions into fixed-size chunks', () {
      expect(chunkList([1, 2, 3, 4, 5], 2), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect(chunkList(<int>[], 25), isEmpty);
      expect(chunkList([1, 2], 25), [
        [1, 2],
      ]);
    });
  });

  group('runWithConcurrency', () {
    test('stops starting new tasks after cancel', () async {
      int started = 0;
      bool cancelled = false;

      await runWithConcurrency<int>(
        items: List<int>.generate(20, (int i) => i),
        concurrency: 2,
        isCancelled: () => cancelled,
        action: (int item) async {
          started++;
          if (started == 2) {
            cancelled = true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 15));
        },
      );

      expect(started, lessThan(20));
      expect(started, greaterThanOrEqualTo(2));
      expect(started, lessThanOrEqualTo(6));
    });

    test('runs all items when not cancelled', () async {
      final List<int> seen = <int>[];
      await runWithConcurrency<int>(
        items: [1, 2, 3, 4, 5],
        concurrency: 2,
        isCancelled: () => false,
        action: (int item) async {
          seen.add(item);
        },
      );
      expect(seen.toSet(), {1, 2, 3, 4, 5});
      expect(seen.length, 5);
    });

    test('invokes onProgress for each finished item', () async {
      final List<int> progressSnapshots = <int>[];
      await runWithConcurrency<int>(
        items: [1, 2, 3],
        concurrency: 2,
        isCancelled: () => false,
        onProgress: (int completed, int total) {
          progressSnapshots.add(completed);
          expect(total, 3);
        },
        action: (int item) async {},
      );
      expect(progressSnapshots, [1, 2, 3]);
    });
  });
}
