import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/pages/ai_center/ai_center_dialogs.dart';
import 'package:jhentai/src/pages/ai_center/ai_center_page_state.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/ai_xp_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/ai_setting.dart';
import 'package:jhentai/src/setting/favorite_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/search_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

class AiCenterPageLogic extends GetxController
    with GetSingleTickerProviderStateMixin {
  final AiCenterPageState state = AiCenterPageState();

  static const String pageId = 'aiCenterPageId';
  static const String progressId = 'aiCenterProgressId';
  static const String profileId = 'aiCenterProfileId';
  static const String recommendId = 'aiCenterRecommendId';
  static const String manageId = 'aiCenterManageId';
  static const String searchId = 'aiCenterSearchId';
  static const String modeId = 'aiCenterModeId';

  late final TabController tabController;
  late final TextEditingController organizationController;
  late final TextEditingController searchController;
  late final ScrollController profileScrollController;
  late final ScrollController recommendScrollController;
  late final ScrollController manageScrollController;
  late final ScrollController searchScrollController;

  @override
  void onInit() {
    super.onInit();
    tabController = TabController(length: 4, vsync: this);
    organizationController = TextEditingController();
    searchController = TextEditingController();
    profileScrollController = ScrollController();
    recommendScrollController = ScrollController();
    manageScrollController = ScrollController();
    searchScrollController = ScrollController();
    loadProfile();
  }

  @override
  void onClose() {
    tabController.dispose();
    organizationController.dispose();
    searchController.dispose();
    profileScrollController.dispose();
    recommendScrollController.dispose();
    manageScrollController.dispose();
    searchScrollController.dispose();
    super.onClose();
  }

  // ---------------------------------------------------------------------------
  // Progress / helpers
  // ---------------------------------------------------------------------------

  void _onProgress(AiXpProgress progress) {
    state.progress = progress;
    updateSafely([progressId, pageId]);
  }

  void _clearProgress() {
    state.progress = null;
    updateSafely([progressId, pageId]);
  }

  String formatProgress(AiXpProgress progress) {
    switch (progress.phase) {
      case AiXpService.phaseLoadingFavorites:
        return progress.phase.trParams({'count': progress.current.toString()});
      case AiXpService.phaseLoadingMetadata:
      case AiXpService.phaseFetchingCandidates:
      case AiXpService.phaseApplyingOrganization:
      case AiXpService.phaseRemovingDuplicates:
        return progress.phase.trParams({
          'current': progress.current.toString(),
          'total': progress.total.toString(),
        });
      default:
        return progress.phase.tr;
    }
  }

  void _handleError(String context, Object e, [StackTrace? s]) {
    if (e is DioException) {
      log.error(context, e.errorMsg, e.stackTrace);
      snack('aiOperationFailed'.tr, e.errorMsg ?? e.toString());
    } else {
      log.error(context, e, s);
      snack('aiOperationFailed'.tr, e.toString());
    }
  }

  String favoriteCategoryName(int? index, {String? fallback}) {
    if (index != null &&
        index >= 0 &&
        index < favoriteSetting.favoriteTagNames.length) {
      return favoriteSetting.favoriteTagNames[index];
    }
    if (fallback != null && fallback.isNotEmpty) {
      return fallback;
    }
    return '-';
  }

  List<MapEntry<String, double>> topWeighted(Map<String, double> weights,
      {int limit = 20}) {
    final List<MapEntry<String, double>> entries = weights.entries.toList()
      ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
        final int byWeight = b.value.compareTo(a.value);
        if (byWeight != 0) {
          return byWeight;
        }
        return a.key.compareTo(b.key);
      });
    if (entries.length <= limit) {
      return entries;
    }
    return entries.sublist(0, limit);
  }

  /// Normalize raw weights to relative percentages of the strongest entry (0–100).
  List<MapEntry<String, int>> topWeightedPercents(Map<String, double> weights,
      {int limit = 20}) {
    final List<MapEntry<String, double>> top =
        topWeighted(weights, limit: limit);
    if (top.isEmpty) {
      return const <MapEntry<String, int>>[];
    }
    final double max = top.first.value;
    if (max <= 0) {
      return top
          .map((MapEntry<String, double> e) => MapEntry<String, int>(e.key, 0))
          .toList();
    }
    return top
        .map(
          (MapEntry<String, double> e) => MapEntry<String, int>(
            e.key,
            ((e.value / max) * 100).round().clamp(0, 100),
          ),
        )
        .toList();
  }

  /// Relative percent label for a raw score against [maxValue].
  String relativePercentLabel(double value, double maxValue) {
    if (maxValue <= 0) {
      return '0%';
    }
    return '${((value / maxValue) * 100).round().clamp(0, 100)}%';
  }

  String confidencePercentLabel(double confidence) {
    final double c = confidence.isNaN ? 0 : confidence.clamp(0.0, 1.0);
    return '${(c * 100).round()}%';
  }

  void _hydrateFavoriteCacheInfo() {
    state.favoriteCacheCount = aiXpService.favoriteCacheCount;
    state.favoriteCacheCapturedAtMs = aiXpService.favoriteCacheCapturedAtMs;
    state.hasFavoriteCache = aiXpService.hasFavoriteCache;
  }

  /// Returns false and snacks when remote AI API is not configured.
  bool _requireAiReady({String? title}) {
    if (aiSetting.isReady) {
      return true;
    }
    snack(title ?? 'aiCenter'.tr, 'aiNotConfigured'.tr, isShort: true);
    return false;
  }

  // ---------------------------------------------------------------------------
  // Profile
  // ---------------------------------------------------------------------------

  Future<void> loadProfile() async {
    if (state.profileLoadingState == LoadingState.loading) {
      return;
    }

    state.profileLoadingState = LoadingState.loading;
    updateSafely([profileId, pageId]);

    try {
      final AiXpProfile? profile = await aiXpService.loadProfile();
      state.profile = profile;
      _hydrateFavoriteCacheInfo();
      state.profileLoadingState = profile == null || !state.hasProfile
          ? LoadingState.noData
          : LoadingState.success;
    } catch (e, s) {
      state.profileLoadingState = LoadingState.error;
      _handleError('load AI XP profile failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([profileId, recommendId, manageId, pageId]);
    }
  }

  Future<void> refreshProfile() async {
    if (state.profileLoadingState == LoadingState.loading) {
      return;
    }
    if (!_requireAiReady(title: 'aiXpProfile'.tr)) {
      return;
    }

    state.profileLoadingState = LoadingState.loading;
    updateSafely(
        [profileId, recommendId, manageId, progressId, pageId, modeId]);

    try {
      final AiXpAnalysisResult result = await aiXpService.analyzeFavorites(
        forceRefresh: true,
        onProgress: _onProgress,
      );
      state.profile = result.profile;
      _hydrateFavoriteCacheInfo();
      state.profileLoadingState =
          !state.hasProfile ? LoadingState.noData : LoadingState.success;
      _invalidateRecommendations();
      toast('aiProfileBuilt'.tr);
    } catch (e, s) {
      state.profileLoadingState = LoadingState.error;
      _handleError('refresh AI XP profile failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([profileId, recommendId, manageId, progressId, pageId]);
    }
  }

  void _invalidateRecommendations() {
    state.recommendations = <AiXpRecommendation>[];
    state.recommendLoadingState = LoadingState.idle;
  }

  void _syncProfileAfterMutation() {
    state.profile = aiXpService.cachedProfile ?? state.profile;
    _hydrateFavoriteCacheInfo();
    state.profileLoadingState =
        !state.hasProfile ? LoadingState.noData : LoadingState.success;
    _invalidateRecommendations();
  }

  // ---------------------------------------------------------------------------
  // Recommendations
  // ---------------------------------------------------------------------------

  Future<void> generateRecommendations() async {
    if (state.recommendLoadingState == LoadingState.loading) {
      return;
    }
    if (!_requireAiReady(title: 'aiRecommendations'.tr)) {
      return;
    }
    if (!state.hasProfile) {
      snack('aiRecommendations'.tr, 'aiNeedProfile'.tr, isShort: true);
      return;
    }

    state.recommendLoadingState = LoadingState.loading;
    state.recommendations = <AiXpRecommendation>[];
    updateSafely([recommendId, progressId, pageId, modeId]);

    try {
      final List<AiXpRecommendation> results =
          await aiXpService.generateRecommendations(
        profile: state.profile,
        onProgress: _onProgress,
      );
      state.recommendations = results;
      state.recommendLoadingState =
          results.isEmpty ? LoadingState.noData : LoadingState.success;
    } catch (e, s) {
      state.recommendLoadingState = LoadingState.error;
      _handleError('generate AI recommendations failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([recommendId, progressId, pageId]);
    }
  }

  void openGallery(Gallery gallery) {
    toRoute(
      Routes.details,
      arguments:
          DetailsPageArgument(galleryUrl: gallery.galleryUrl, gallery: gallery),
    );
  }

  // ---------------------------------------------------------------------------
  // Organization
  // ---------------------------------------------------------------------------

  Future<void> previewOrganization() async {
    if (state.organizationLoadingState == LoadingState.loading ||
        state.organizationApplyLoadingState == LoadingState.loading) {
      return;
    }
    if (!_requireAiReady(title: 'aiFavoriteOrganizer'.tr)) {
      return;
    }
    if (!state.hasProfile) {
      snack('aiFavoriteOrganizer'.tr, 'organizationRequirement'.tr,
          isShort: true);
      return;
    }

    final String requirements = organizationController.text.trim();
    state.organizationLoadingState = LoadingState.loading;
    state.organizationPlan = null;
    state.selectedMoveGids.clear();
    updateSafely([manageId, progressId, pageId, modeId]);

    try {
      final AiXpOrganizationPlanResult result =
          await aiXpService.planOrganization(
        requirements,
        onProgress: _onProgress,
      );
      state.organizationPlan = result;
      state.selectedMoveGids
        ..clear()
        ..addAll(result.plan.moves.map((AiXpOrganizationMove m) => m.gid));
      state.organizationLoadingState = LoadingState.success;
      _clearProgress();

      if (result.plan.rules.isEmpty && result.plan.moves.isEmpty) {
        snack('aiFavoriteOrganizer'.tr, 'noOrganizationRules'.tr,
            isShort: true);
        return;
      }
      if (result.plan.moves.isEmpty) {
        snack('aiFavoriteOrganizer'.tr, 'noOrganizationChanges'.tr,
            isShort: true);
        return;
      }

      final List<AiXpOrganizationMove>? selected =
          await Get.dialog<List<AiXpOrganizationMove>>(
        AiOrganizationPreviewDialog(
          planResult: result,
          initiallySelectedGids: Set<int>.from(state.selectedMoveGids),
          categoryNameResolver: favoriteCategoryName,
        ),
      );
      if (selected == null) {
        return;
      }
      if (selected.isEmpty) {
        snack('aiFavoriteOrganizer'.tr, 'aiSelectAtLeastOne'.tr, isShort: true);
        return;
      }

      final bool? confirmed = await Get.dialog<bool>(
        EHDialog(
          title: 'applySelectedMoves'.tr,
          content: 'organizationPreviewTitle'.tr,
        ),
      );
      if (confirmed != true) {
        return;
      }

      await _applyOrganizationMoves(selected);
    } catch (e, s) {
      state.organizationLoadingState = LoadingState.error;
      _handleError('preview organization failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([manageId, progressId, pageId]);
    }
  }

  Future<void> _applyOrganizationMoves(List<AiXpOrganizationMove> moves) async {
    if (state.organizationApplyLoadingState == LoadingState.loading) {
      return;
    }

    state.organizationApplyLoadingState = LoadingState.loading;
    updateSafely([manageId, progressId, pageId]);

    try {
      final AiXpApplyResult result = await aiXpService.applyOrganizationMoves(
        moves,
        onProgress: _onProgress,
      );
      state.organizationApplyLoadingState = LoadingState.success;
      state.organizationPlan = null;
      state.selectedMoveGids.clear();
      snack(
        'aiFavoriteOrganizer'.tr,
        'organizationApplied'.trParams({
          'success': result.successCount.toString(),
          'failed': result.failureCount.toString(),
        }),
      );
      // Profile may have been rebuilt from cache; drop stale recommendations.
      _syncProfileAfterMutation();
    } catch (e, s) {
      state.organizationApplyLoadingState = LoadingState.error;
      _handleError('apply organization failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([manageId, profileId, recommendId, progressId, pageId]);
    }
  }

  // ---------------------------------------------------------------------------
  // Duplicates (local deterministic tooling — available without remote AI)
  // ---------------------------------------------------------------------------

  Future<void> scanDuplicates() async {
    if (state.duplicateLoadingState == LoadingState.loading ||
        state.duplicateApplyLoadingState == LoadingState.loading) {
      return;
    }

    state.duplicateLoadingState = LoadingState.loading;
    state.duplicatePlan = null;
    state.selectedDuplicateKeeperGids.clear();
    updateSafely([manageId, progressId, pageId]);

    try {
      final AiXpDuplicatePlanResult result =
          await aiXpService.planDuplicates(onProgress: _onProgress);
      state.duplicatePlan = result;
      state.selectedDuplicateKeeperGids
        ..clear()
        ..addAll(result.groups.map((AiXpDuplicateGroup g) => g.keeperGid));
      state.duplicateLoadingState =
          result.groups.isEmpty ? LoadingState.noData : LoadingState.success;
      _clearProgress();

      if (result.groups.isEmpty) {
        snack('scanAiDuplicates'.tr, 'noAiDuplicates'.tr, isShort: true);
        return;
      }

      final List<AiXpDuplicateGroup>? selected =
          await Get.dialog<List<AiXpDuplicateGroup>>(
        AiDuplicatePreviewDialog(
          planResult: result,
          initiallySelectedKeeperGids:
              Set<int>.from(state.selectedDuplicateKeeperGids),
        ),
      );
      if (selected == null) {
        return;
      }
      if (selected.isEmpty) {
        snack('scanAiDuplicates'.tr, 'aiSelectAtLeastOne'.tr, isShort: true);
        return;
      }

      final int removeCount = selected.fold<int>(
        0,
        (int sum, AiXpDuplicateGroup g) => sum + g.duplicateGids.length,
      );
      final bool? confirmed = await Get.dialog<bool>(
        EHDialog(
          title: 'duplicateRemove'.tr,
          content: 'duplicateGroupLabel'.trParams({
            'title': selected.length.toString(),
            'count': removeCount.toString(),
          }),
        ),
      );
      if (confirmed != true) {
        return;
      }

      await _applyDuplicateRemoval(selected);
    } catch (e, s) {
      state.duplicateLoadingState = LoadingState.error;
      _handleError('scan AI duplicates failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([manageId, progressId, pageId]);
    }
  }

  Future<void> _applyDuplicateRemoval(List<AiXpDuplicateGroup> groups) async {
    if (state.duplicateApplyLoadingState == LoadingState.loading) {
      return;
    }

    state.duplicateApplyLoadingState = LoadingState.loading;
    updateSafely([manageId, progressId, pageId]);

    try {
      final AiXpApplyResult result = await aiXpService.applyDuplicateRemoval(
        groups,
        onProgress: _onProgress,
      );
      state.duplicateApplyLoadingState = LoadingState.success;
      state.duplicatePlan = null;
      state.selectedDuplicateKeeperGids.clear();
      snack(
        'scanAiDuplicates'.tr,
        'duplicatesRemoved'.trParams({
          'success': result.successCount.toString(),
          'failed': result.failureCount.toString(),
        }),
      );
      // Profile may have been rebuilt from cache; drop stale recommendations.
      _syncProfileAfterMutation();
    } catch (e, s) {
      state.duplicateApplyLoadingState = LoadingState.error;
      _handleError('apply duplicate removal failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([manageId, profileId, recommendId, progressId, pageId]);
    }
  }

  // ---------------------------------------------------------------------------
  // Enhanced search
  // ---------------------------------------------------------------------------

  Future<void> runEnhancedSearch() async {
    if (state.searchLoadingState == LoadingState.loading) {
      return;
    }
    if (!_requireAiReady(title: 'enhancedAiSearch'.tr)) {
      return;
    }

    final String query = searchController.text.trim();
    if (query.isEmpty) {
      return;
    }

    state.searchLoadingState = LoadingState.loading;
    updateSafely([searchId, progressId, pageId, modeId]);

    try {
      final AiXpEnhancedSearchResult result =
          await aiXpService.buildEnhancedSearch(
        query,
        profile: state.profile,
        onProgress: _onProgress,
      );
      state.searchLoadingState = LoadingState.success;
      await newSearch(
          rewriteSearchConfig: result.searchConfig, forceNewRoute: true);
    } catch (e, s) {
      state.searchLoadingState = LoadingState.error;
      _handleError('enhanced AI search failed', e, s);
    } finally {
      _clearProgress();
      updateSafely([searchId, progressId, pageId]);
    }
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<void> openSettingsDialog() async {
    final bool? saved = await Get.dialog<bool>(const AiSettingsDialog());
    if (saved == true) {
      toast('aiSettingsSaved'.tr);
      if (aiSetting.enabled.value && !aiSetting.isReady) {
        snack('aiSettings'.tr, 'aiNotConfigured'.tr, isShort: true);
      }
      updateSafely(
          [modeId, pageId, profileId, recommendId, manageId, searchId]);
    } else {
      updateSafely([modeId, pageId]);
    }
  }

  bool get isAiReady => aiSetting.isReady;
}
