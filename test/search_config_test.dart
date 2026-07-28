import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/search_config.dart';

Map<String, dynamic> _baseJson({
  SearchType searchType = SearchType.gallery,
  bool onlyShowGalleriesWithTorrents = false,
  bool? onlyShowGalleriesWithoutTorrents,
  bool? hideFavoritedGalleries,
  int? searchFavoriteCategoryIndex,
}) {
  return {
    'searchType': searchType.index,
    'includeDoujinshi': true,
    'includeManga': true,
    'includeArtistCG': true,
    'includeGameCg': true,
    'includeWestern': true,
    'includeNonH': true,
    'includeImageSet': true,
    'includeCosplay': true,
    'includeAsianPorn': true,
    'includeMisc': true,
    'keyword': null,
    'tags': null,
    'language': null,
    'searchExpungedGalleries': false,
    'onlyShowGalleriesWithTorrents': onlyShowGalleriesWithTorrents,
    if (onlyShowGalleriesWithoutTorrents != null) 'onlyShowGalleriesWithoutTorrents': onlyShowGalleriesWithoutTorrents,
    if (hideFavoritedGalleries != null) 'hideFavoritedGalleries': hideFavoritedGalleries,
    'pageAtLeast': null,
    'pageAtMost': null,
    'minimumRating': 1,
    'disableFilterForLanguage': false,
    'disableFilterForUploader': false,
    'disableFilterForTags': false,
    'searchFavoriteCategoryIndex': searchFavoriteCategoryIndex,
  };
}

void main() {
  group('SearchConfig torrent / favorite filter fields', () {
    test('defaults are false for new filter flags', () {
      final SearchConfig config = SearchConfig();
      expect(config.onlyShowGalleriesWithTorrents, isFalse);
      expect(config.onlyShowGalleriesWithoutTorrents, isFalse);
      expect(config.hideFavoritedGalleries, isFalse);
    });

    test('fromJson is backward-compatible when new keys are absent', () {
      final SearchConfig config = SearchConfig.fromJson(_baseJson(
        onlyShowGalleriesWithTorrents: true,
      ));

      expect(config.onlyShowGalleriesWithTorrents, isTrue);
      expect(config.onlyShowGalleriesWithoutTorrents, isFalse);
      expect(config.hideFavoritedGalleries, isFalse);
    });

    test('toJson / fromJson round-trip preserves new flags', () {
      final SearchConfig original = SearchConfig(
        onlyShowGalleriesWithTorrents: false,
        onlyShowGalleriesWithoutTorrents: true,
        hideFavoritedGalleries: true,
      );

      final SearchConfig restored = SearchConfig.fromJson(original.toJson());

      expect(restored.onlyShowGalleriesWithTorrents, isFalse);
      expect(restored.onlyShowGalleriesWithoutTorrents, isTrue);
      expect(restored.hideFavoritedGalleries, isTrue);
    });

    test('copyWith updates and preserves new flags', () {
      final SearchConfig base = SearchConfig(hideFavoritedGalleries: true);
      final SearchConfig updated = base.copyWith(
        onlyShowGalleriesWithoutTorrents: true,
        onlyShowGalleriesWithTorrents: false,
      );

      expect(updated.hideFavoritedGalleries, isTrue);
      expect(updated.onlyShowGalleriesWithoutTorrents, isTrue);
      expect(updated.onlyShowGalleriesWithTorrents, isFalse);
      expect(base.onlyShowGalleriesWithoutTorrents, isFalse);
    });

    test('copyWith preserves searchFavoriteCategoryIndex', () {
      final SearchConfig base = SearchConfig(
        searchType: SearchType.favorite,
        searchFavoriteCategoryIndex: 3,
      );
      final SearchConfig updated = base.copyWith(keyword: 'tag:"foo\$"');

      expect(updated.searchFavoriteCategoryIndex, 3);
      expect(updated.searchType, SearchType.favorite);
      expect(updated.keyword, 'tag:"foo\$"');
      expect(base.searchFavoriteCategoryIndex, 3);
    });

    test('f_sto is emitted only for gallery/watched effective with-torrents', () {
      final SearchConfig galleryWith = SearchConfig(
        searchType: SearchType.gallery,
        onlyShowGalleriesWithTorrents: true,
      );
      expect(galleryWith.toQueryParameters()['f_sto'], 'on');
      expect(galleryWith.usesServerTorrentFilter, isTrue);
      expect(galleryWith.needsClientTorrentFilter, isFalse);

      final SearchConfig watchedWith = SearchConfig(
        searchType: SearchType.watched,
        onlyShowGalleriesWithTorrents: true,
      );
      expect(watchedWith.toQueryParameters()['f_sto'], 'on');
      expect(watchedWith.usesServerTorrentFilter, isTrue);
      expect(watchedWith.needsClientTorrentFilter, isFalse);

      final SearchConfig favoriteWith = SearchConfig(
        searchType: SearchType.favorite,
        onlyShowGalleriesWithTorrents: true,
      );
      expect(favoriteWith.toQueryParameters().containsKey('f_sto'), isFalse);
      expect(favoriteWith.usesServerTorrentFilter, isFalse);
      expect(favoriteWith.needsClientTorrentFilter, isTrue);

      final SearchConfig galleryWithout = SearchConfig(
        searchType: SearchType.gallery,
        onlyShowGalleriesWithoutTorrents: true,
      );
      expect(galleryWithout.toQueryParameters().containsKey('f_sto'), isFalse);
      expect(galleryWithout.needsClientTorrentFilter, isTrue);
    });

    test('conflict: both torrent flags true - without wins; no f_sto', () {
      final SearchConfig live = SearchConfig(
        searchType: SearchType.gallery,
        onlyShowGalleriesWithTorrents: true,
        onlyShowGalleriesWithoutTorrents: true,
      );

      expect(live.appliesOnlyShowGalleriesWithoutTorrents, isTrue);
      expect(live.appliesOnlyShowGalleriesWithTorrents, isFalse);
      expect(live.toQueryParameters().containsKey('f_sto'), isFalse);
      expect(live.usesServerTorrentFilter, isFalse);
      expect(live.needsClientTorrentFilter, isTrue);

      final SearchConfig restored = SearchConfig.fromJson(_baseJson(
        onlyShowGalleriesWithTorrents: true,
        onlyShowGalleriesWithoutTorrents: true,
      ));

      expect(restored.onlyShowGalleriesWithTorrents, isFalse);
      expect(restored.onlyShowGalleriesWithoutTorrents, isTrue);
      expect(restored.toQueryParameters().containsKey('f_sto'), isFalse);
      expect(restored.needsClientTorrentFilter, isTrue);
    });

    test('onlyWith on popular/history uses client gdata filter, not f_sto', () {
      final SearchConfig popularWith = SearchConfig(
        searchType: SearchType.popular,
        onlyShowGalleriesWithTorrents: true,
      );
      expect(popularWith.toQueryParameters().containsKey('f_sto'), isFalse);
      expect(popularWith.usesServerTorrentFilter, isFalse);
      expect(popularWith.needsClientTorrentFilter, isTrue);

      final SearchConfig historyWith = SearchConfig(
        searchType: SearchType.history,
        onlyShowGalleriesWithTorrents: true,
      );
      expect(historyWith.toQueryParameters().containsKey('f_sto'), isFalse);
      expect(historyWith.usesServerTorrentFilter, isFalse);
      expect(historyWith.needsClientTorrentFilter, isTrue);
    });

    test('without-torrents always needs client filter regardless of searchType', () {
      for (final SearchType type in SearchType.values) {
        final SearchConfig config = SearchConfig(
          searchType: type,
          onlyShowGalleriesWithoutTorrents: true,
        );
        expect(config.needsClientTorrentFilter, isTrue, reason: '$type');
        expect(config.toQueryParameters().containsKey('f_sto'), isFalse, reason: '$type');
      }
    });

    test('toString includes new filter flags', () {
      final String text = SearchConfig(
        onlyShowGalleriesWithoutTorrents: true,
        hideFavoritedGalleries: true,
      ).toString();

      expect(text, contains('onlyShowGalleriesWithoutTorrents: true'));
      expect(text, contains('hideFavoritedGalleries: true'));
    });
  });
}
