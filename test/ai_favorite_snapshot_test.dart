import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/ai_favorite_snapshot.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';

Gallery _minimalGallery({
  required int gid,
  required String token,
  bool isEH = true,
  String title = 'Sample Title',
  String category = 'Doujinshi',
  int? favoriteTagIndex = 2,
  String? favoriteTagName = 'Favorites',
  String publishTime = '2024-06-15 10:30',
  double rating = 4.5,
  int? pageCount = 24,
  String? language = 'chinese',
  String? uploader = 'uploader_a',
  String coverUrl = 'https://example.com/cover.jpg',
}) {
  return Gallery(
    galleryUrl: GalleryUrl(isEH: isEH, gid: gid, token: token),
    title: title,
    category: category,
    cover: GalleryImage(url: coverUrl),
    pageCount: pageCount,
    rating: rating,
    hasRated: false,
    favoriteTagIndex: favoriteTagIndex,
    favoriteTagName: favoriteTagName,
    language: language,
    uploader: uploader,
    publishTime: publishTime,
    isExpunged: false,
    tags: LinkedHashMap<String, List<GalleryTag>>(),
  );
}

void main() {
  group('AiFavoriteSnapshotEntry', () {
    test('fromGallery / toGallery preserves identity and favorite fields', () {
      final Gallery gallery = _minimalGallery(
        gid: 123456,
        token: 'abcdefghij',
        isEH: false,
        title: 'EX Gallery',
        category: 'Manga',
        favoriteTagIndex: 5,
        favoriteTagName: 'Later',
        publishTime: '2024-01-02 08:15',
      );

      final AiFavoriteSnapshotEntry entry =
          AiFavoriteSnapshotEntry.fromGallery(gallery);
      expect(entry.signal.gid, 123456);
      expect(entry.token, 'abcdefghij');
      expect(entry.isEH, isFalse);
      expect(entry.signal.title, 'EX Gallery');
      expect(entry.signal.category, 'Manga');
      expect(entry.signal.favoriteCategoryIndex, 5);
      expect(entry.signal.favoriteCategoryName, 'Later');
      expect(entry.signal.uploader, 'uploader_a');
      expect(entry.signal.rating, 4.5);
      expect(entry.signal.pageCount, 24);
      expect(entry.signal.language, 'chinese');
      expect(entry.signal.favoritedAtMs, isNotNull);
      expect(entry.signal.tags, isEmpty);

      final Gallery reconstructed = entry.toGallery();
      expect(reconstructed.gid, 123456);
      expect(reconstructed.token, 'abcdefghij');
      expect(reconstructed.galleryUrl.isEH, isFalse);
      expect(reconstructed.title, 'EX Gallery');
      expect(reconstructed.category, 'Manga');
      expect(reconstructed.favoriteTagIndex, 5);
      expect(reconstructed.favoriteTagName, 'Later');
      expect(reconstructed.cover.url, '');
      expect(reconstructed.tags, isEmpty);
      expect(reconstructed.uploader, 'uploader_a');
      expect(reconstructed.pageCount, 24);
      expect(reconstructed.language, 'chinese');
      expect(reconstructed.publishTime, isNotEmpty);
    });

    test('entry JSON round-trip preserves signal, token, isEH', () {
      const AiFavoriteSnapshotEntry original = AiFavoriteSnapshotEntry(
        signal: AiGallerySignal(
          gid: 99,
          title: 'Round Trip',
          category: 'Doujinshi',
          tags: <String>['female:loli'],
          uploader: 'u1',
          rating: 3.5,
          pageCount: 12,
          language: 'english',
          torrentCount: 1,
          favoriteCategoryIndex: 0,
          favoriteCategoryName: 'Misc',
          favoritedAtMs: 1700000000000,
          publishedAtMs: 1600000000000,
        ),
        token: '0123456789',
        isEH: true,
      );

      final AiFavoriteSnapshotEntry restored =
          AiFavoriteSnapshotEntry.fromJson(original.toJson());
      expect(restored.token, original.token);
      expect(restored.isEH, original.isEH);
      expect(restored.signal.gid, original.signal.gid);
      expect(restored.signal.title, original.signal.title);
      expect(restored.signal.category, original.signal.category);
      expect(restored.signal.tags, original.signal.tags);
      expect(restored.signal.uploader, original.signal.uploader);
      expect(restored.signal.rating, original.signal.rating);
      expect(restored.signal.pageCount, original.signal.pageCount);
      expect(restored.signal.language, original.signal.language);
      expect(restored.signal.torrentCount, original.signal.torrentCount);
      expect(restored.signal.favoriteCategoryIndex,
          original.signal.favoriteCategoryIndex);
      expect(restored.signal.favoriteCategoryName,
          original.signal.favoriteCategoryName);
      expect(restored.signal.favoritedAtMs, original.signal.favoritedAtMs);
      expect(restored.signal.publishedAtMs, original.signal.publishedAtMs);
      expect(restored.toJson(), original.toJson());
    });
  });

  group('AiFavoriteSnapshot', () {
    test('envelope JSON round-trip is deterministic by gid order', () {
      const AiFavoriteSnapshotEntry high = AiFavoriteSnapshotEntry(
        signal: AiGallerySignal(
          gid: 200,
          title: 'High',
          category: 'Manga',
          favoriteCategoryIndex: 1,
          favoriteCategoryName: 'A',
        ),
        token: 'tokentoken',
        isEH: true,
      );
      const AiFavoriteSnapshotEntry low = AiFavoriteSnapshotEntry(
        signal: AiGallerySignal(
          gid: 100,
          title: 'Low',
          category: 'Doujinshi',
          favoriteCategoryIndex: 2,
          favoriteCategoryName: 'B',
        ),
        token: 'abcdefghij',
        isEH: false,
      );

      const AiFavoriteSnapshot original = AiFavoriteSnapshot(
        ownerKey: 'user:ipb_member_id=1',
        capturedAtMs: 1704067200000,
        // Intentionally reverse gid order; toJson sorts by gid.
        entries: <AiFavoriteSnapshotEntry>[high, low],
      );

      final Map<String, dynamic> json = original.toJson();
      expect(json['version'], AiFavoriteSnapshot.currentVersion);
      expect(json['ownerKey'], 'user:ipb_member_id=1');
      expect(json['capturedAtMs'], 1704067200000);
      final List<dynamic> entriesJson = json['entries'] as List<dynamic>;
      expect(entriesJson, hasLength(2));
      expect((entriesJson[0] as Map)['signal']['gid'], 100);
      expect((entriesJson[1] as Map)['signal']['gid'], 200);

      final AiFavoriteSnapshot restored = AiFavoriteSnapshot.fromJson(json);
      expect(restored.version, original.version);
      expect(restored.ownerKey, original.ownerKey);
      expect(restored.capturedAtMs, original.capturedAtMs);
      expect(restored.entries, hasLength(2));
      expect(restored.entries[0].signal.gid, 100);
      expect(restored.entries[0].token, 'abcdefghij');
      expect(restored.entries[0].isEH, isFalse);
      expect(restored.entries[1].signal.gid, 200);
      expect(restored.entries[1].token, 'tokentoken');
      expect(restored.entries[1].isEH, isTrue);

      // Deterministic: re-serializing the same logical data yields identical JSON.
      final AiFavoriteSnapshot reordered = AiFavoriteSnapshot(
        ownerKey: original.ownerKey,
        capturedAtMs: original.capturedAtMs,
        entries: <AiFavoriteSnapshotEntry>[low, high],
      );
      expect(reordered.toJson(), original.toJson());
      expect(AiFavoriteSnapshot.fromJson(reordered.toJson()).toJson(),
          original.toJson());
    });

    test('fromGallery snapshot envelope reconstructs gallery identity fields',
        () {
      final Gallery g1 = _minimalGallery(
        gid: 10,
        token: 'aaaaaaaaaa',
        title: 'One',
        favoriteTagIndex: 0,
        favoriteTagName: 'Misc',
      );
      final Gallery g2 = _minimalGallery(
        gid: 20,
        token: 'bbbbbbbbbb',
        isEH: false,
        title: 'Two',
        category: 'Artist CG',
        favoriteTagIndex: 3,
        favoriteTagName: 'Keep',
      );

      final AiFavoriteSnapshot snapshot = AiFavoriteSnapshot(
        ownerKey: 'owner-key',
        capturedAtMs: 1710000000000,
        entries: <AiFavoriteSnapshotEntry>[
          AiFavoriteSnapshotEntry.fromGallery(g1),
          AiFavoriteSnapshotEntry.fromGallery(g2),
        ],
      );

      final AiFavoriteSnapshot restored =
          AiFavoriteSnapshot.fromJson(snapshot.toJson());
      expect(restored.entries, hasLength(2));

      final Gallery r1 = restored.entries[0].toGallery();
      final Gallery r2 = restored.entries[1].toGallery();
      expect(r1.gid, 10);
      expect(r1.token, 'aaaaaaaaaa');
      expect(r1.title, 'One');
      expect(r1.category, 'Doujinshi');
      expect(r1.favoriteTagIndex, 0);
      expect(r1.favoriteTagName, 'Misc');
      expect(r1.cover.url, isEmpty);

      expect(r2.gid, 20);
      expect(r2.token, 'bbbbbbbbbb');
      expect(r2.galleryUrl.isEH, isFalse);
      expect(r2.title, 'Two');
      expect(r2.category, 'Artist CG');
      expect(r2.favoriteTagIndex, 3);
      expect(r2.favoriteTagName, 'Keep');
    });
  });
}
