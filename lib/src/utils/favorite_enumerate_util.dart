import 'package:dio/dio.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';

/// Default safety cap on favorite list pages walked in one scan.
///
/// EH serves ~50 favorites per page, so this covers a ~10k-item library. The
/// cap bounds the request count if the server keeps handing back fresh cursors,
/// which matters because callers usually follow up with per-gallery gdata calls.
const int kMaxFavoriteEnumeratePages = 200;

/// Enumerate every favorite on the server, ignoring any page's active filters.
///
/// Shared by the AI XP profile scan and the favorites-page batch operations so
/// both use the same termination guards:
/// - repeated pagination cursors stop the walk (server returned a cycle),
/// - [maxPages] bounds the total request count,
/// - duplicate gids across pages are collapsed.
///
/// [isCancelled] is polled before each page; [onPageLoaded] receives the running
/// total after each page so callers can drive an indeterminate progress display.
/// Request failures are logged and rethrown — a partial list is never returned
/// as if it were complete.
Future<List<Gallery>> enumerateAllServerFavorites({
  int maxPages = kMaxFavoriteEnumeratePages,
  bool Function()? isCancelled,
  void Function(int loadedCount)? onPageLoaded,
}) async {
  final SearchConfig searchConfig = SearchConfig(searchType: SearchType.favorite);
  final List<Gallery> all = <Gallery>[];
  final Set<int> seenGids = <int>{};
  final Set<String> seenCursors = <String>{};
  String? nextGid;
  int pages = 0;

  while (isCancelled == null || !isCancelled()) {
    if (nextGid != null && !seenCursors.add(nextGid)) {
      log.warning('favorite enumerate stopped: repeated cursor $nextGid');
      break;
    }
    if (pages >= maxPages) {
      log.warning('favorite enumerate stopped at the $maxPages page cap (${all.length} galleries)');
      break;
    }
    pages++;

    final GalleryPageInfo page;
    try {
      page = await ehRequest.requestGalleryPage(
        nextGid: nextGid,
        searchConfig: searchConfig,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );
    } on DioException catch (e) {
      log.error('enumerate all favorites fail', e.errorMsg);
      rethrow;
    } on EHSiteException catch (e) {
      log.error('enumerate all favorites fail', e.message);
      rethrow;
    }

    for (final Gallery gallery in page.galleries) {
      if (seenGids.add(gallery.gid)) {
        all.add(gallery);
      }
    }
    onPageLoaded?.call(all.length);

    if (page.nextGid == null) {
      break;
    }
    nextGid = page.nextGid;
  }

  return all;
}
