import 'dart:collection';
import 'dart:convert';

import 'package:clipboard/clipboard.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_torrent.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/setting/favorite_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';
import 'package:jhentai/src/widget/eh_batch_progress_dialog.dart';
import 'package:jhentai/src/widget/eh_favorite_sort_order_dialog.dart';

import '../../enum/config_enum.dart';
import '../../exception/eh_site_exception.dart';
import '../../model/gallery.dart';
import '../../model/search_config.dart';
import '../../service/local_config_service.dart';
import '../../utils/eh_spider_parser.dart';
import '../../utils/favorite_dedupe_util.dart';
import '../../service/log.dart';
import '../../utils/snack_util.dart';
import '../../utils/toast_util.dart';
import '../../widget/loading_state_indicator.dart';
import '../base/base_page_logic.dart';
import 'favorite_page_state.dart';

class FavoritePageLogic extends BasePageLogic {
  static const int _metadataBatchSize = 25;

  /// Safety cap on favorite list pages walked in one batch operation.
  ///
  /// EH serves ~50 favorites per page, so this covers a ~10k-item library and
  /// bounds the request count if the server keeps handing back fresh cursors.
  static const int _maxFavoritePages = 200;
  static const int _torrentFetchConcurrency = 3;
  static const int _deleteConcurrency = 3;

  /// GetBuilder id for the batch overflow menu / progress indicator.
  final String batchOperationId = 'batchOperationId';

  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final FavoritePageState state = FavoritePageState();

  Future<void> handleChangeSortOrder() async {
    if (state.refreshState == LoadingState.loading) {
      return;
    }

    FavoriteSortOrder? result = await Get.dialog(EHFavoriteSortOrderDialog(init: state.favoriteSortOrder));
    if (result == null) {
      return;
    }

    if (state.refreshState == LoadingState.loading) {
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

    try {
      await ehRequest.requestChangeFavoriteSortOrder(result, parser: EHSpiderParser.galleryPage2GalleryPageInfo);
    } on DioException catch (e) {
      /// handle with domain fronting, manually load more
      if (e.response?.statusCode == 403 && e.response!.redirects.isNotEmpty) {
        return loadMore(checkLoadingState: false);
      }

      log.error('change favorite sort order fail', e.message);
      snack('failed'.tr, e.message ?? '');
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    } on EHSiteException catch (e) {
      log.error('change favorite sort order fail', e.message);
      snack('failed'.tr, e.message);
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    } catch (e) {
      log.error('change favorite sort order fail', e.toString);
      snack('failed'.tr, e.toString());
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    }

    return loadMore(checkLoadingState: false);
  }

  /// Batch-collect unique non-outdated magnet links from all server favorites.
  Future<void> handleBatchFetchFavoriteTorrents() async {
    if (state.batchOperationRunning) {
      return;
    }
    if (!userSetting.hasLoggedIn()) {
      toast('needLoginToOperate'.tr);
      return;
    }

    final EHBatchProgressController progress = EHBatchProgressController();
    _beginBatchOperation();

    try {
      Get.dialog(
        EHBatchProgressDialog(
          title: 'batchFetchFavoriteTorrents'.tr,
          controller: progress,
        ),
        barrierDismissible: false,
      );

      progress.setPhase('loadingAllFavorites'.tr);
      final List<Gallery> favorites = await _enumerateAllServerFavorites(progress);
      if (progress.isCancelled) {
        _snackCancelled();
        return;
      }

      progress.setPhase('checkingFavoriteTorrents'.tr);
      progress.setProgress(current: 0, total: favorites.isEmpty ? 1 : favorites.length);

      // Galleries known to have torrents; always keep original Gallery gid/token.
      final List<Gallery> withTorrents = <Gallery>[];
      // failureCount = missing metadata rows + whole-chunk request errors + torrent page errors.
      int failureCount = 0;
      int checkedCount = 0;

      final List<List<Gallery>> chunks = chunkList(favorites, _metadataBatchSize);
      for (final List<Gallery> chunk in chunks) {
        if (progress.isCancelled) {
          break;
        }

        try {
          final List<GalleryMetadata> metadatas = await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
            list: chunk.map((Gallery g) => (gid: g.gid, token: g.token)).toList(),
            parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
          );
          // Per-gid reconcile: missing requested gids -> failure; extras/dupes ignored;
          // withTorrents rows are the original Gallery objects from [chunk].
          final ({List<Gallery> withTorrents, int missingCount}) reconciled = reconcileFavoriteMetadataChunk<Gallery>(
            requested: chunk,
            gidOf: (Gallery g) => g.gid,
            responseItems: metadatas.map(
              (GalleryMetadata m) => (gid: m.galleryUrl.gid, torrentCount: m.torrentCount),
            ),
          );
          failureCount += reconciled.missingCount;
          withTorrents.addAll(reconciled.withTorrents);
        } on DioException catch (e) {
          failureCount += chunk.length;
          log.error('batch check favorite torrents metadata fail', e.errorMsg);
        } on EHSiteException catch (e) {
          failureCount += chunk.length;
          log.error('batch check favorite torrents metadata fail', e.message);
        } catch (e) {
          failureCount += chunk.length;
          log.error('batch check favorite torrents metadata fail', e.toString());
        }

        checkedCount += chunk.length;
        progress.setProgress(current: checkedCount, total: favorites.length);
      }

      if (progress.isCancelled) {
        _snackCancelled();
        return;
      }

      progress.setPhase('fetchingFavoriteTorrents'.tr);
      progress.setProgress(current: 0, total: withTorrents.isEmpty ? 1 : withTorrents.length);

      final LinkedHashSet<String> magnets = LinkedHashSet<String>();
      // Galleries that contributed at least one non-outdated magnet (copied set size basis).
      int galleryWithMagnetCount = 0;

      await runWithConcurrency<Gallery>(
        items: withTorrents,
        concurrency: _torrentFetchConcurrency,
        isCancelled: () => progress.isCancelled,
        onProgress: (int completed, int total) {
          progress.setProgress(current: completed, total: total);
        },
        action: (Gallery gallery) async {
          try {
            final List<GalleryTorrent> torrents = await ehRequest.requestTorrentPage<List<GalleryTorrent>>(
              gallery.gid,
              gallery.token,
              EHSpiderParser.torrentPage2GalleryTorrent,
            );
            final List<String> pageMagnets = collectUniqueNonOutdatedMagnets(
              torrents: torrents.map((GalleryTorrent t) => (magnetUrl: t.magnetUrl, outdated: t.outdated)),
            );
            if (pageMagnets.isNotEmpty) {
              galleryWithMagnetCount++;
              magnets.addAll(pageMagnets);
            }
          } on DioException catch (e) {
            failureCount++;
            log.error('batch fetch favorite torrent page fail gid=${gallery.gid}', e.errorMsg);
          } on EHSiteException catch (e) {
            failureCount++;
            log.error('batch fetch favorite torrent page fail gid=${gallery.gid}', e.message);
          } catch (e) {
            failureCount++;
            log.error('batch fetch favorite torrent page fail gid=${gallery.gid}', e.toString());
          }
        },
      );

      if (progress.isCancelled) {
        _snackCancelled();
        return;
      }

      // Result stats:
      // - noneFound: 0 magnets, 0 failures -> noFavoriteTorrentsFound (no copy)
      // - unavailable: 0 magnets, failures > 0 -> favoriteTorrentsUnavailable (no copy)
      // - copied: magnets > 0 -> clipboard + favoriteTorrentsCopied
      final FavoriteTorrentBatchOutcome outcome = resolveFavoriteTorrentBatchOutcome(
        magnetCount: magnets.length,
        failureCount: failureCount,
      );

      switch (outcome) {
        case FavoriteTorrentBatchOutcome.noneFound:
          snack(
            'batchFetchFavoriteTorrents'.tr,
            'noFavoriteTorrentsFound'.tr,
            isShort: false,
          );
          break;
        case FavoriteTorrentBatchOutcome.unavailable:
          snack(
            'batchFetchFavoriteTorrents'.tr,
            'favoriteTorrentsUnavailable'.trParams(
              favoriteTorrentsUnavailableParams(failedCount: failureCount),
            ),
            isShort: false,
          );
          break;
        case FavoriteTorrentBatchOutcome.copied:
          await FlutterClipboard.copy(magnets.join('\n'));
          snack(
            'batchFetchFavoriteTorrents'.tr,
            'favoriteTorrentsCopied'.trParams(
              favoriteTorrentsCopiedParams(
                galleryCount: galleryWithMagnetCount,
                torrentCount: magnets.length,
                failedCount: failureCount,
              ),
            ),
            isShort: false,
          );
          break;
      }
    } on DioException catch (e) {
      log.error('batch fetch favorite torrents fail', e.errorMsg);
      snack('favoriteBatchOperationFailed'.tr, e.errorMsg ?? e.toString(), isShort: false);
    } on EHSiteException catch (e) {
      log.error('batch fetch favorite torrents fail', e.message);
      snack('favoriteBatchOperationFailed'.tr, e.message, isShort: false);
    } catch (e) {
      log.error('batch fetch favorite torrents fail', e.toString());
      snack('favoriteBatchOperationFailed'.tr, e.toString(), isShort: false);
    } finally {
      await _endBatchOperation(progress);
    }
  }

  /// Deduplicate server favorites by category + case/whitespace-normalized title.
  /// Keeps the first item in server order; skips empty category/title (never deletes them).
  Future<void> handleDeduplicateFavorites() async {
    if (state.batchOperationRunning) {
      return;
    }
    if (!userSetting.hasLoggedIn()) {
      toast('needLoginToOperate'.tr);
      return;
    }

    final EHBatchProgressController progress = EHBatchProgressController();
    _beginBatchOperation();

    try {
      Get.dialog(
        EHBatchProgressDialog(
          title: 'deduplicateFavorites'.tr,
          controller: progress,
        ),
        barrierDismissible: false,
      );

      progress.setPhase('loadingAllFavorites'.tr);
      final List<Gallery> favorites = await _enumerateAllServerFavorites(progress);
      if (progress.isCancelled) {
        _snackCancelled();
        return;
      }

      final List<Gallery> duplicates = findFavoriteDuplicates<Gallery>(
        items: favorites,
        categoryOf: (Gallery g) => g.category,
        titleOf: (Gallery g) => g.title,
      );

      // Close progress before confirmation so the user can interact freely.
      _closeProgressDialogIfOpen();

      if (duplicates.isEmpty) {
        snack('deduplicateFavorites'.tr, 'noDuplicateFavoritesFound'.tr);
        return;
      }

      final bool? confirmed = await Get.dialog<bool>(
        EHDialog(
          title: 'confirmDeduplicateFavorites'.tr,
          content: 'confirmDeduplicateFavoritesContent'.trParams({
            'duplicateCount': duplicates.length.toString(),
          }),
        ),
      );
      if (confirmed != true) {
        return;
      }

      // Re-open progress for deletion phase.
      progress.clearProgress();
      progress.setPhase('deduplicateFavorites'.tr);
      progress.setProgress(current: 0, total: duplicates.length);
      Get.dialog(
        EHBatchProgressDialog(
          title: 'deduplicateFavorites'.tr,
          controller: progress,
        ),
        barrierDismissible: false,
      );

      int deletedCount = 0;
      int failureCount = 0;

      await runWithConcurrency<Gallery>(
        items: duplicates,
        concurrency: _deleteConcurrency,
        isCancelled: () => progress.isCancelled,
        onProgress: (int completed, int total) {
          progress.setProgress(current: completed, total: total);
        },
        action: (Gallery gallery) async {
          try {
            await ehRequest.requestRemoveFavorite(gallery.gid, gallery.token);
            deletedCount++;
          } on DioException catch (e) {
            failureCount++;
            log.error('dedupe remove favorite fail gid=${gallery.gid}', e.errorMsg);
          } on EHSiteException catch (e) {
            failureCount++;
            log.error('dedupe remove favorite fail gid=${gallery.gid}', e.message);
          } catch (e) {
            failureCount++;
            log.error('dedupe remove favorite fail gid=${gallery.gid}', e.toString());
          }
        },
      );

      if (progress.isCancelled) {
        _snackCancelled();
        // Still refresh counts/list if anything was deleted.
        if (deletedCount > 0) {
          await _refreshAfterDedupe();
        }
        return;
      }

      await _refreshAfterDedupe();

      snack(
        'deduplicateFavorites'.tr,
        'deduplicateFavoritesCompleted'.trParams({
          'successCount': deletedCount.toString(),
          'failedCount': failureCount.toString(),
        }),
        isShort: false,
      );
    } on DioException catch (e) {
      log.error('deduplicate favorites fail', e.errorMsg);
      snack('favoriteBatchOperationFailed'.tr, e.errorMsg ?? e.toString(), isShort: false);
    } on EHSiteException catch (e) {
      log.error('deduplicate favorites fail', e.message);
      snack('favoriteBatchOperationFailed'.tr, e.message, isShort: false);
    } catch (e) {
      log.error('deduplicate favorites fail', e.toString());
      snack('favoriteBatchOperationFailed'.tr, e.toString(), isShort: false);
    } finally {
      await _endBatchOperation(progress);
    }
  }

  /// Enumerate every server favorite, ignoring the page's active filters.
  ///
  /// Guards against repeated pagination cursors and duplicate gids.
  Future<List<Gallery>> _enumerateAllServerFavorites(EHBatchProgressController progress) async {
    final SearchConfig searchConfig = SearchConfig(searchType: SearchType.favorite);
    final List<Gallery> all = <Gallery>[];
    final Set<int> seenGids = <int>{};
    final Set<String> seenCursors = <String>{};
    String? nextGid;
    int pages = 0;

    progress.clearProgress();

    while (!progress.isCancelled) {
      if (nextGid != null && !seenCursors.add(nextGid)) {
        log.warning('favorite enumerate stopped: repeated cursor $nextGid');
        break;
      }
      if (pages >= _maxFavoritePages) {
        log.warning('favorite enumerate stopped at the $_maxFavoritePages page cap (${all.length} galleries)');
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

      // Total is unknown while paging; keep the bar indeterminate and show count in phase.
      progress.clearProgress();
      progress.setPhase('${'loadingAllFavorites'.tr} (${all.length})');

      if (page.nextGid == null) {
        break;
      }
      nextGid = page.nextGid;
    }

    return all;
  }

  Future<void> _refreshAfterDedupe() async {
    try {
      await favoriteSetting.fetchDataFromEH();
    } catch (e) {
      log.warning('refresh favoriteSetting after dedupe fail', e.toString());
    }

    // Refresh the visible favorite list regardless of active filters.
    if (state.loadingState != LoadingState.loading) {
      await handleClearAndRefresh();
    }
  }

  void _beginBatchOperation() {
    state.batchOperationRunning = true;
    updateSafely([batchOperationId]);
  }

  /// Close any open progress dialog, clear the running flag, then dispose [progress].
  Future<void> _endBatchOperation(EHBatchProgressController progress) async {
    _closeProgressDialogIfOpen();
    state.batchOperationRunning = false;
    updateSafely([batchOperationId]);
    // Let the dialog unmount and drop its AnimatedBuilder listeners first.
    await Future<void>.delayed(Duration.zero);
    progress.dispose();
  }

  void _closeProgressDialogIfOpen() {
    if (Get.isDialogOpen ?? false) {
      Get.back();
    }
  }

  void _snackCancelled() {
    snack('favoriteBatchOperations'.tr, 'operationCancelled'.tr);
  }

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }
}
