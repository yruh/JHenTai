import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/setting/preference_setting.dart';
import 'package:jhentai/src/widget/eh_search_config_dialog.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../exception/eh_site_exception.dart';
import '../../mixin/scroll_to_top_logic_mixin.dart';
import '../../mixin/scroll_to_top_state_mixin.dart';
import '../../model/gallery.dart';
import '../../model/gallery_count.dart';
import '../../model/gallery_metadata.dart';
import '../../network/eh_request.dart';
import '../../routes/routes.dart';
import '../../service/local_block_rule_service.dart';
import '../../service/tag_translation_service.dart';
import '../../setting/user_setting.dart';
import '../../utils/eh_spider_parser.dart';
import '../../service/log.dart';
import '../../utils/route_util.dart';
import '../../utils/snack_util.dart';
import '../../utils/toast_util.dart';
import '../../utils/uuid_util.dart';
import '../../widget/loading_state_indicator.dart';
import '../details/details_page_logic.dart';
import 'base_page_state.dart';

abstract class BasePageLogic extends GetxController with Scroll2TopLogicMixin {
  BasePageState get state;

  @override
  Scroll2TopStateMixin get scroll2TopState => state;

  final String appBarId = 'appBarId';
  final String bodyId = 'bodyId';
  final String refreshStateId = 'refreshStateId';
  final String loadingStateId = 'loadingStateId';

  bool get useSearchConfig;

  String get searchConfigKey => runtimeType.toString();

  bool get autoLoadForFirstTime => true;

  bool get autoLoadNeedLogin => false;

  @override
  Future<void> onInit() async {
    super.onInit();

    if (useSearchConfig) {
      localConfigService.read(configKey: ConfigEnum.searchConfig, subConfigKey: searchConfigKey).then((searchConfigString) {
        if (searchConfigString != null) {
          Map<String, dynamic> map = jsonDecode(searchConfigString);
          state.searchConfig = SearchConfig.fromJson(map);
        }
      }).whenComplete(() {
        state.searchConfigInitCompleter.complete();
      });
    } else {
      state.searchConfigInitCompleter.complete();
    }

    if (autoLoadForFirstTime) {
      if (autoLoadNeedLogin && !userSetting.hasLoggedIn()) {
        state.loadingState = LoadingState.noData;
        updateSafely([bodyId]);
        Get.engine.addPostFrameCallback((_) => toast('needLoginToOperate'.tr));
        return;
      }

      loadMore();
    }
  }

  /// pull-down
  Future<void> handlePullDown() async {
    if (state.prevGid == null) {
      return handleRefresh();
    }

    return loadBefore();
  }

  /// Upper bound on consecutive pages fetched in one user action when every page
  /// is fully removed by client-side filters (block rules / hide-favorited /
  /// torrent filter).
  ///
  /// Without a cap, a strict filter set turns a single pull-to-refresh into an
  /// unbounded chain of requests (each page may additionally trigger gdata calls
  /// for torrent filtering), which trips EH rate limiting. On hitting the cap we
  /// keep [GalleryPageInfo.nextGid] so the user can continue manually.
  static const int _maxFilteredPageFetches = 5;

  /// not clear current data before refresh
  /// [updateId] is for subclass to override
  /// Continues through following cursors when a page is fully filtered out,
  /// for at most [_maxFilteredPageFetches] pages.
  Future<void> handleRefresh({String? updateId}) async {
    if (state.refreshState == LoadingState.loading) {
      return;
    }

    state.refreshState = LoadingState.loading;
    updateSafely([refreshStateId]);

    final Set<String> visitedCursors = {};
    String? cursor;
    List<Gallery> galleries = [];
    String? prevGid;
    String? nextGid;
    GalleryCount? totalCount;
    FavoriteSortOrder? favoriteSortOrder;
    int fetchedPages = 0;

    while (true) {
      final String cursorKey = cursor ?? '';
      if (!visitedCursors.add(cursorKey)) {
        log.warning('handleRefresh detected pagination cursor loop at "$cursor", stop loading');
        /// Terminate pagination so the same cursor is not left retryable forever.
        nextGid = null;
        break;
      }
      fetchedPages++;

      GalleryPageInfo galleryPage;
      try {
        galleryPage = await getGalleryPage(nextGid: cursor);
      } on DioException catch (e) {
        log.error('refreshGalleryFailed'.tr, e.errorMsg);
        snack('refreshGalleryFailed'.tr, e.errorMsg ?? '', isShort: true);
        state.refreshState = LoadingState.error;
        updateSafely([refreshStateId]);
        return;
      } on EHSiteException catch (e) {
        log.error('refreshGalleryFailed'.tr, e.message);
        snack(
          'refreshGalleryFailed'.tr,
          e.message,
          isShort: true,
          onPressed: e.referLink == null ? null : () => launchUrlString(e.referLink!, mode: LaunchMode.externalApplication),
        );
        state.refreshState = LoadingState.error;
        updateSafely([refreshStateId]);
        return;
      } catch (e) {
        log.error('refreshGalleryFailed'.tr, e.toString());
        snack('refreshGalleryFailed'.tr, e.toString(), isShort: true);
        state.refreshState = LoadingState.error;
        updateSafely([refreshStateId]);
        return;
      }

      /// Only the first page establishes prevGid (start of the refreshed window).
      if (cursor == null) {
        prevGid = galleryPage.prevGid;
      }
      nextGid = galleryPage.nextGid;
      totalCount = galleryPage.totalCount;
      favoriteSortOrder = galleryPage.favoriteSortOrder;

      galleries = await postHandleNewGalleries(galleryPage.galleries, cleanDuplicate: false);

      if (galleries.isNotEmpty || galleryPage.nextGid == null) {
        break;
      }

      /// Cap consecutive fully-filtered pages; keep nextGid so the user can continue.
      if (fetchedPages >= _maxFilteredPageFetches) {
        log.warning('handleRefresh stopped after $fetchedPages fully-filtered pages, keeping nextGid "${galleryPage.nextGid}"');
        break;
      }

      /// Next cursor already seen -> terminate rather than re-fetching forever.
      if (visitedCursors.contains(galleryPage.nextGid)) {
        log.warning('handleRefresh detected pagination cursor loop at "${galleryPage.nextGid}", stop loading');
        nextGid = null;
        break;
      }

      cursor = galleryPage.nextGid;
    }

    state.galleries = galleries;
    state.totalCount = totalCount;
    state.prevGid = prevGid;
    state.nextGid = nextGid;
    state.favoriteSortOrder = favoriteSortOrder;
    state.galleryCollectionKey = Key(newUUID());

    state.refreshState = LoadingState.idle;

    if (state.nextGid == null && state.prevGid == null && state.galleries.isEmpty) {
      state.loadingState = LoadingState.noData;
    } else if (state.nextGid == null) {
      state.loadingState = LoadingState.noMore;
    } else {
      state.loadingState = LoadingState.idle;
    }

    if (updateId != null) {
      updateSafely([updateId]);
    } else {
      updateSafely();
    }
  }

  /// clear current data first, then refresh
  Future<void> handleClearAndRefresh() async {
    if (state.loadingState == LoadingState.loading) {
      return;
    }

    state.loadingState = LoadingState.loading;

    state.galleries.clear();
    state.prevGid = null;
    state.nextGid = null;
    state.seek = DateTime.now();
    state.totalCount = null;
    state.favoriteSortOrder = null;

    jump2Top();

    updateSafely();

    return loadMore(checkLoadingState: false);
  }

  /// pull-down to load page before(after jumping to a certain page), after load, we must restore [state.downloadState]
  /// to [prevState] in case of [prevState] is [noMore]
  Future<void> loadBefore() async {
    if (state.loadingState == LoadingState.loading) {
      return;
    }

    LoadingState prevState = state.loadingState;
    state.loadingState = LoadingState.loading;

    GalleryPageInfo galleryPage;
    try {
      galleryPage = await getGalleryPage(prevGid: state.prevGid);
    } on DioException catch (e) {
      log.error('getGalleriesFailed'.tr, e.errorMsg);
      snack('getGalleriesFailed'.tr, e.errorMsg ?? '', isShort: true);
      state.loadingState = prevState;
      updateSafely([loadingStateId]);
      return;
    } on EHSiteException catch (e) {
      log.error('getGalleriesFailed'.tr, e.message);
      snack(
        'getGalleriesFailed'.tr,
        e.message,
        isShort: true,
        onPressed: e.referLink == null ? null : () => launchUrlString(e.referLink!, mode: LaunchMode.externalApplication),
      );
      state.loadingState = prevState;
      updateSafely([loadingStateId]);
      return;
    } catch (e) {
      log.error('getGalleriesFailed'.tr, e.toString());
      snack('getGalleriesFailed'.tr, e.toString(), isShort: true);
      state.loadingState = prevState;
      updateSafely([loadingStateId]);
      return;
    }

    List<Gallery> galleries = await postHandleNewGalleries(galleryPage.galleries);

    state.galleries.insertAll(0, galleries);
    state.totalCount = galleryPage.totalCount;
    state.prevGid = galleryPage.prevGid;
    state.favoriteSortOrder = galleryPage.favoriteSortOrder;

    state.loadingState = prevState;

    updateSafely();
  }

  /// has scrolled to bottom, so need to load more data.
  /// Continues through following cursors when a page is fully filtered out,
  /// for at most [_maxFilteredPageFetches] pages.
  Future<void> loadMore({bool checkLoadingState = true}) async {
    if (checkLoadingState && state.loadingState == LoadingState.loading) {
      return;
    }

    state.loadingState = LoadingState.loading;
    updateSafely([loadingStateId]);

    final Set<String> visitedCursors = {};
    String? cursor = state.nextGid;
    List<Gallery> galleries = [];
    int fetchedPages = 0;

    while (true) {
      final String cursorKey = cursor ?? '';
      if (!visitedCursors.add(cursorKey)) {
        log.warning('loadMore detected pagination cursor loop at "$cursor", stop loading');
        /// Terminate pagination so the same cursor is not left retryable forever.
        state.nextGid = null;
        break;
      }
      fetchedPages++;

      GalleryPageInfo galleryPage;
      try {
        galleryPage = await getGalleryPage(nextGid: cursor);
      } on DioException catch (e) {
        log.error('getGalleriesFailed'.tr, e.errorMsg);
        snack('getGalleriesFailed'.tr, e.errorMsg ?? '', isShort: true);
        state.loadingState = LoadingState.error;
        updateSafely([loadingStateId]);
        return;
      } on EHSiteException catch (e) {
        log.error('getGalleriesFailed'.tr, e.message);
        snack(
          'getGalleriesFailed'.tr,
          e.message,
          isShort: true,
          onPressed: e.referLink == null ? null : () => launchUrlString(e.referLink!, mode: LaunchMode.externalApplication),
        );
        state.loadingState = LoadingState.error;
        updateSafely([loadingStateId]);
        return;
      } catch (e) {
        log.error('getGalleriesFailed'.tr, e.toString());
        snack('getGalleriesFailed'.tr, e.toString(), isShort: true);
        state.loadingState = LoadingState.error;
        updateSafely([loadingStateId]);
        return;
      }

      galleries = await postHandleNewGalleries(galleryPage.galleries);

      state.totalCount = galleryPage.totalCount;
      state.nextGid = galleryPage.nextGid;
      state.favoriteSortOrder = galleryPage.favoriteSortOrder;

      if (galleries.isNotEmpty || galleryPage.nextGid == null) {
        break;
      }

      /// Cap consecutive fully-filtered pages; state.nextGid stays set so the
      /// next scroll-to-bottom resumes from here.
      if (fetchedPages >= _maxFilteredPageFetches) {
        log.warning('loadMore stopped after $fetchedPages fully-filtered pages, keeping nextGid "${galleryPage.nextGid}"');
        break;
      }

      /// Next cursor already seen -> terminate rather than re-fetching forever.
      if (visitedCursors.contains(galleryPage.nextGid)) {
        log.warning('loadMore detected pagination cursor loop at "${galleryPage.nextGid}", stop loading');
        state.nextGid = null;
        break;
      }

      /// Page fully filtered out - advance to the next cursor.
      cursor = galleryPage.nextGid;
    }

    state.galleries.addAll(galleries);

    if (state.nextGid == null && state.prevGid == null && state.galleries.isEmpty) {
      state.loadingState = LoadingState.noData;
    } else if (state.nextGid == null) {
      state.loadingState = LoadingState.noMore;
    } else {
      state.loadingState = LoadingState.idle;
    }

    updateSafely();
  }

  /// Jump to [dateTime], then continue forward through nextGid when the landed
  /// page is fully removed by client filters (same cursor-loop guard and
  /// [_maxFilteredPageFetches] cap as loadMore).
  Future<void> jumpPage(DateTime dateTime) async {
    if (state.loadingState == LoadingState.loading) {
      return;
    }

    log.info('Jump page to $dateTime');

    state.galleries.clear();
    state.loadingState = LoadingState.loading;
    updateSafely();

    state.scrollController.jumpTo(0);

    final Set<String> visitedCursors = {};
    /// First request keeps original jump semantics (current window + seek).
    String? cursor = state.nextGid;
    String? jumpPrevGid = state.prevGid;
    DateTime? seek = dateTime;
    List<Gallery> galleries = [];
    String? prevGid;
    String? nextGid;
    GalleryCount? totalCount;
    FavoriteSortOrder? favoriteSortOrder;
    int fetchedPages = 0;

    while (true) {
      final String cursorKey = cursor ?? '';
      if (!visitedCursors.add(cursorKey)) {
        log.warning('jumpPage detected pagination cursor loop at "$cursor", stop loading');
        /// Terminate pagination so the same cursor is not left retryable forever.
        nextGid = null;
        break;
      }
      fetchedPages++;

      GalleryPageInfo galleryPage;
      try {
        galleryPage = await getGalleryPage(nextGid: cursor, prevGid: jumpPrevGid, seek: seek);
      } on DioException catch (e) {
        log.error('getGalleriesFailed'.tr, e.errorMsg);
        snack('getGalleriesFailed'.tr, e.errorMsg ?? '', isShort: true);
        state.loadingState = LoadingState.error;
        updateSafely([loadingStateId]);
        return;
      } on EHSiteException catch (e) {
        log.error('getGalleriesFailed'.tr, e.message);
        snack(
          'getGalleriesFailed'.tr,
          e.message,
          isShort: true,
          onPressed: e.referLink == null ? null : () => launchUrlString(e.referLink!, mode: LaunchMode.externalApplication),
        );
        state.loadingState = LoadingState.error;
        updateSafely([loadingStateId]);
        return;
      } catch (e) {
        log.error('getGalleriesFailed'.tr, e.toString());
        snack('getGalleriesFailed'.tr, e.toString(), isShort: true);
        state.loadingState = LoadingState.error;
        updateSafely([loadingStateId]);
        return;
      }

      /// Only the first (seek) page establishes prevGid for the jumped window.
      if (seek != null) {
        prevGid = galleryPage.prevGid;
      }
      nextGid = galleryPage.nextGid;
      totalCount = galleryPage.totalCount;
      favoriteSortOrder = galleryPage.favoriteSortOrder;

      /// Subsequent pages paginate forward by nextGid only (no re-seek).
      jumpPrevGid = null;
      seek = null;

      galleries = await postHandleNewGalleries(galleryPage.galleries, cleanDuplicate: false);

      if (galleries.isNotEmpty || galleryPage.nextGid == null) {
        break;
      }

      /// Cap consecutive fully-filtered pages; keep nextGid so the user can continue.
      if (fetchedPages >= _maxFilteredPageFetches) {
        log.warning('jumpPage stopped after $fetchedPages fully-filtered pages, keeping nextGid "${galleryPage.nextGid}"');
        break;
      }

      /// Next cursor already seen -> terminate rather than re-fetching forever.
      if (visitedCursors.contains(galleryPage.nextGid)) {
        log.warning('jumpPage detected pagination cursor loop at "${galleryPage.nextGid}", stop loading');
        nextGid = null;
        break;
      }

      cursor = galleryPage.nextGid;
    }

    state.galleries = galleries;
    state.totalCount = totalCount;
    state.prevGid = prevGid;
    state.nextGid = nextGid;
    state.favoriteSortOrder = favoriteSortOrder;
    state.galleryCollectionKey = Key(newUUID());

    state.seek = dateTime;

    if (state.nextGid == null && state.prevGid == null && state.galleries.isEmpty) {
      state.loadingState = LoadingState.noData;
    } else if (state.nextGid == null) {
      state.loadingState = LoadingState.noMore;
    } else {
      state.loadingState = LoadingState.idle;
    }

    updateSafely();
  }

  Future<void> handleTapJumpButton() async {
    DateTime? dateTime = await showDatePicker(
      context: Get.context!,
      initialDate: state.seek,
      currentDate: DateTime.now(),
      firstDate: DateTime(2007),
      lastDate: DateTime.now(),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );

    if (dateTime != null) {
      jumpPage(dateTime);
    }
  }

  Future<void> handleTapFilterButton([EHSearchConfigDialogType searchConfigDialogType = EHSearchConfigDialogType.filter]) async {
    await state.searchConfigInitCompleter.future;

    Map<String, dynamic>? result = await Get.dialog(
      EHSearchConfigDialog(searchConfig: state.searchConfig, type: searchConfigDialogType),
    );

    if (result == null) {
      return;
    }

    SearchConfig searchConfig = result['searchConfig'];
    state.searchConfig = searchConfig;

    /// No need to save at search page
    if (useSearchConfig) {
      await saveSearchConfig(searchConfig);
    }

    handleClearAndRefresh();
  }

  void handleTapGalleryCard(Gallery gallery) async {
    toRoute(
      Routes.details,
      arguments: DetailsPageArgument(galleryUrl: gallery.galleryUrl, gallery: gallery),
    );
  }

  void handleLongPressCard(BuildContext context, Gallery gallery, {Offset? position}) async {}

  void handleSecondaryTapCard(BuildContext context, Gallery gallery, {Offset? position}) async {}

  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) async {
    log.info('$runtimeType get data, prevGid:$prevGid, nextGid:$nextGid');

    await state.searchConfigInitCompleter.future;

    return ehRequest.requestGalleryPage(
      prevGid: prevGid,
      nextGid: nextGid,
      seek: seek,
      searchConfig: state.searchConfig,
      parser: EHSpiderParser.galleryPage2GalleryPageInfo,
    );
  }

  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig),
    );
  }

  Future<List<Gallery>> postHandleNewGalleries(List<Gallery> galleries, {bool cleanDuplicate = true}) async {
    if (cleanDuplicate) {
      _cleanDuplicateGallery(galleries);
    }

    /// Hide favorited galleries before local block rules.
    if (state.searchConfig.hideFavoritedGalleries && state.searchConfig.searchType != SearchType.favorite) {
      galleries = galleries.where((gallery) => !gallery.isFavorite).toList();
    }

    galleries = await _filterByTorrentsIfNeeded(galleries);

    await _translateGalleryTagsIfNeeded(galleries);

    List<Gallery> filteredGalleries = await _filterByBlockingRules(galleries);

    if (preferenceSetting.preloadGalleryCover.isTrue) {
      for (Gallery gallery in filteredGalleries) {
        getNetworkImageData(gallery.cover.url, useCache: true);
      }
    }

    return filteredGalleries;
  }

  /// deal with the first and last page
  void _cleanDuplicateGallery(List<Gallery> newGalleries) {
    newGalleries.removeWhere((newGallery) => state.galleries.firstWhereOrNull((e) => e.galleryUrl == newGallery.galleryUrl) != null);
  }

  /// Client-side torrent filtering via gdata (chunks of at most 25).
  ///
  /// Policy is owned by [SearchConfig.needsClientTorrentFilter]:
  /// - gallery/watched + effective with-torrents: server `f_sto` only
  /// - with-torrents on favorite/popular/history/...: client gdata
  /// - without-torrents (any type): client gdata; without wins if both flags set
  ///
  /// Metadata failures fail open (keep galleries, log + snack).
  Future<List<Gallery>> _filterByTorrentsIfNeeded(List<Gallery> galleries) async {
    if (galleries.isEmpty) {
      return galleries;
    }

    final SearchConfig config = state.searchConfig;
    if (!config.needsClientTorrentFilter) {
      return galleries;
    }

    final bool onlyWithout = config.appliesOnlyShowGalleriesWithoutTorrents;
    final bool onlyWith = config.appliesOnlyShowGalleriesWithTorrents;

    const int chunkSize = 25;
    final Map<int, int> torrentCountByGid = {};

    try {
      for (int i = 0; i < galleries.length; i += chunkSize) {
        final List<Gallery> chunk = galleries.sublist(i, i + chunkSize > galleries.length ? galleries.length : i + chunkSize);
        final List<GalleryMetadata> metadatas = await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: chunk.map((g) => (gid: g.gid, token: g.token)).toList(),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        );
        for (final GalleryMetadata metadata in metadatas) {
          torrentCountByGid[metadata.galleryUrl.gid] = metadata.torrentCount;
        }
      }
    } catch (e, s) {
      log.error('filterGalleriesByTorrentsFailed'.tr, e, s);
      snack('filterGalleriesByTorrentsFailed'.tr, e.toString(), isShort: true);
      /// Fail open: keep original list rather than stranding the loading state.
      return galleries;
    }

    return galleries.where((gallery) {
      final int? count = torrentCountByGid[gallery.gid];
      /// Missing metadata: fail open for that item.
      if (count == null) {
        return true;
      }
      if (onlyWithout) {
        return count == 0;
      }
      if (onlyWith) {
        return count > 0;
      }
      return true;
    }).toList();
  }

  Future<List<Gallery>> _filterByBlockingRules(List<Gallery> newGalleries) async {
    if (newGalleries.isEmpty) {
      return newGalleries;
    }

    // if all galleries are filtered, we keep the first one to indicate it
    List<Gallery> filteredGalleries = await localBlockRuleService.executeRules(newGalleries);
    if (filteredGalleries.isNotEmpty) {
      return filteredGalleries;
    } else {
      return newGalleries.sublist(0, 1).map((g) => g..blockedByLocalRules = true).toList();
    }
  }

  Future<void> _translateGalleryTagsIfNeeded(List<Gallery> galleries) async {
    await Future.wait(galleries.map((gallery) {
      return tagTranslationService.translateTagsIfNeeded(gallery.tags);
    }).toList());
  }
}
