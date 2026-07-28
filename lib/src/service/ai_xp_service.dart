import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_note.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/network/ai_request.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/ai_setting.dart';
import 'package:jhentai/src/setting/favorite_setting.dart';
import 'package:jhentai/src/utils/ai_xp_engine.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/utils/favorite_dedupe_util.dart';

/// Global AI XP orchestration service.
AiXpService aiXpService = AiXpService();

/// Optional progress sink for long-running public operations.
///
/// [AiXpProgress.phase] uses stable i18n key strings (e.g. `aiLoadingFavorites`).
typedef AiXpProgressCallback = void Function(AiXpProgress progress);

/// UI-ready progress snapshot.
class AiXpProgress {
  /// Stable phase id matching locale keys (`aiLoadingFavorites`, ...).
  final String phase;

  final int current;
  final int total;

  const AiXpProgress({
    required this.phase,
    this.current = 0,
    this.total = 0,
  });
}

/// Result of [AiXpService.analyzeFavorites].
class AiXpAnalysisResult {
  final AiXpProfile profile;
  final int favoriteCount;
  final int metadataFailureCount;
  final int signalCount;

  const AiXpAnalysisResult({
    required this.profile,
    required this.favoriteCount,
    required this.metadataFailureCount,
    required this.signalCount,
  });
}

/// Ranked recommendation with a live [Gallery] for UI cards.
class AiXpRecommendation {
  final Gallery gallery;
  final double score;
  final List<AiXpScoreExplanation> explanations;

  const AiXpRecommendation({
    required this.gallery,
    required this.score,
    this.explanations = const <AiXpScoreExplanation>[],
  });
}

/// Duplicate plan with gallery lookup for titles / keeper display.
class AiXpDuplicatePlanResult {
  final List<AiXpDuplicateGroup> groups;
  final Map<int, Gallery> galleriesByGid;

  const AiXpDuplicatePlanResult({
    required this.groups,
    required this.galleriesByGid,
  });
}

/// Organization plan with gallery lookup and remote-AI status.
class AiXpOrganizationPlanResult {
  final AiXpOrganizationPlan plan;
  final Map<int, Gallery> galleriesByGid;
  final bool usedRemoteAi;
  final bool remoteFallback;

  const AiXpOrganizationPlanResult({
    required this.plan,
    required this.galleriesByGid,
    this.usedRemoteAi = false,
    this.remoteFallback = false,
  });
}

/// Batch mutation outcome (organization apply / duplicate removal).
class AiXpApplyResult {
  final int successCount;
  final int failureCount;

  const AiXpApplyResult({
    required this.successCount,
    required this.failureCount,
  });

  int get totalCount => successCount + failureCount;
}

/// Enhanced-search conversion result.
class AiXpEnhancedSearchResult {
  final SearchConfig searchConfig;
  final AiXpSearchIntent intent;
  final bool usedRemoteAi;
  final bool remoteFallback;
  final bool injectedXpTags;

  const AiXpEnhancedSearchResult({
    required this.searchConfig,
    required this.intent,
    this.usedRemoteAi = false,
    this.remoteFallback = false,
    this.injectedXpTags = false,
  });
}

/// Orchestrates favorites, EH metadata/search, local XP profile, engine, and optional remote AI.
class AiXpService {
  static const int _gdataChunkSize = 25;
  static const int _mutationConcurrency = 3;
  static const int _orgRemoteChunkSize = 50;
  static const int _maxRecommendationSearches = 6;
  static const int _maxRecommendations = 30;
  static const int _maxXpInjectTags = 5;

  /// Stable progress phase strings (match locale keys).
  static const String phaseLoadingFavorites = 'aiLoadingFavorites';
  static const String phaseLoadingMetadata = 'aiLoadingMetadata';
  static const String phaseBuildingProfile = 'aiBuildingProfile';
  static const String phaseFetchingCandidates = 'aiFetchingCandidates';
  static const String phaseScoringCandidates = 'aiScoringCandidates';
  static const String phaseAnalyzingOrganization = 'aiAnalyzingOrganization';
  static const String phaseApplyingOrganization = 'aiApplyingOrganization';
  static const String phaseScanningDuplicates = 'aiScanningDuplicates';
  static const String phaseRemovingDuplicates = 'aiRemovingDuplicates';
  static const String phaseInterpretingSearch = 'aiInterpretingSearch';

  final AiXpEngine _engine;

  AiXpProfile? _profile;
  final List<Gallery> _favoriteGalleries = <Gallery>[];
  final List<AiGallerySignal> _favoriteSignals = <AiGallerySignal>[];
  final Map<int, Gallery> _galleryByGid = <int, Gallery>{};
  final Map<int, AiGallerySignal> _signalByGid = <int, AiGallerySignal>{};

  AiXpService({AiXpEngine engine = const AiXpEngine()}) : _engine = engine;

  AiXpProfile? get cachedProfile => _profile;

  List<Gallery> get cachedFavoriteGalleries => List<Gallery>.unmodifiable(_favoriteGalleries);

  List<AiGallerySignal> get cachedFavoriteSignals => List<AiGallerySignal>.unmodifiable(_favoriteSignals);

  bool get hasLiveFavorites => _favoriteGalleries.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Profile persistence
  // ---------------------------------------------------------------------------

  /// Load versioned [AiXpProfile] from [ConfigEnum.aiXpProfile] JSON.
  Future<AiXpProfile?> loadProfile() async {
    try {
      final String? raw = await localConfigService.read(configKey: ConfigEnum.aiXpProfile);
      if (raw == null || raw.isEmpty) {
        _profile = null;
        return null;
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        log.warning('aiXpProfile config is not a JSON object');
        return null;
      }
      final AiXpProfile profile = AiXpProfile.fromJson(Map<String, dynamic>.from(decoded));
      _profile = profile;
      return profile;
    } catch (e, s) {
      log.error('load AiXpProfile failed', e, s);
      return null;
    }
  }

  /// Persist versioned [AiXpProfile] JSON under [ConfigEnum.aiXpProfile].
  Future<void> saveProfile(AiXpProfile profile) async {
    _profile = profile;
    await localConfigService.write(
      configKey: ConfigEnum.aiXpProfile,
      value: jsonEncode(profile.toJson()),
    );
  }

  // ---------------------------------------------------------------------------
  // Analyze favorites -> profile
  // ---------------------------------------------------------------------------

  /// Enumerate every server favorite, enrich via gdata (<=25), build and save profile.
  Future<AiXpAnalysisResult> analyzeFavorites({
    AiXpProgressCallback? onProgress,
  }) async {
    _report(onProgress, phaseLoadingFavorites, current: 0, total: 0);

    final List<Gallery> favorites = await _enumerateAllServerFavorites(onProgress: onProgress);
    final ({List<Gallery> galleries, List<AiGallerySignal> signals, int failures}) enriched =
        await _enrichFavorites(favorites, onProgress: onProgress);

    _replaceFavoriteCache(enriched.galleries, enriched.signals);

    _report(onProgress, phaseBuildingProfile, current: 0, total: 1);
    final AiXpProfile profile = _engine.buildProfile(enriched.signals);
    await saveProfile(profile);
    _report(onProgress, phaseBuildingProfile, current: 1, total: 1);

    return AiXpAnalysisResult(
      profile: profile,
      favoriteCount: favorites.length,
      metadataFailureCount: enriched.failures,
      signalCount: enriched.signals.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Recommendations
  // ---------------------------------------------------------------------------

  /// Search EH with up to 6 focused queries, rank, return top 30 explainable galleries.
  Future<List<AiXpRecommendation>> generateRecommendations({
    AiXpProfile? profile,
    AiXpProgressCallback? onProgress,
  }) async {
    final AiXpProfile effective = profile ?? _profile ?? await loadProfile() ?? const AiXpProfile(builtAtMs: 0, signalCount: 0);
    if (effective.isEmpty) {
      return const <AiXpRecommendation>[];
    }

    if (!hasLiveFavorites) {
      try {
        await _ensureLiveFavorites(onProgress: onProgress);
      } catch (e, s) {
        log.warning('generateRecommendations: load favorites for exclusion failed', e, s);
      }
    }

    final List<SearchConfig> searches = _buildRecommendationSearches(effective);
    final Map<int, Gallery> candidatesByGid = <int, Gallery>{};
    final Set<int> excluded = <int>{
      ...effective.sourceGids,
      ..._galleryByGid.keys,
    };

    final int totalSearches = searches.isEmpty ? 1 : searches.length;
    int searchIndex = 0;
    for (final SearchConfig config in searches) {
      searchIndex++;
      _report(onProgress, phaseFetchingCandidates, current: searchIndex, total: totalSearches);
      try {
        final GalleryPageInfo page = await ehRequest.requestGalleryPage(
          searchConfig: config,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo,
        );
        for (final Gallery gallery in page.gallerys) {
          if (excluded.contains(gallery.gid) || gallery.isFavorite) {
            continue;
          }
          candidatesByGid.putIfAbsent(gallery.gid, () => gallery);
        }
      } on DioException catch (e) {
        log.error('recommendation search failed', e.errorMsg);
      } on EHSiteException catch (e) {
        log.error('recommendation search failed', e.message);
      } catch (e, s) {
        log.error('recommendation search failed', e, s);
      }
    }

    if (candidatesByGid.isEmpty) {
      return const <AiXpRecommendation>[];
    }

    final List<Gallery> candidateGalleries = candidatesByGid.values.toList();
    final ({List<Gallery> galleries, List<AiGallerySignal> signals, int failures}) enriched =
        await _enrichGalleries(
      candidateGalleries,
      onProgress: onProgress,
      progressPhase: phaseFetchingCandidates,
      preserveFavoriteFields: false,
    );
    if (enriched.failures > 0) {
      log.warning('recommendation metadata failures: ${enriched.failures}');
    }

    _report(onProgress, phaseScoringCandidates, current: 0, total: enriched.signals.length);
    final List<AiXpRankedCandidate> ranked = _engine.rankCandidates(
      profile: effective,
      candidates: enriched.signals,
      limit: _maxRecommendations,
    );

    final Map<int, Gallery> enrichedByGid = <int, Gallery>{
      for (final Gallery g in enriched.galleries) g.gid: g,
    };

    final List<AiXpRecommendation> results = <AiXpRecommendation>[];
    for (final AiXpRankedCandidate item in ranked) {
      final Gallery? gallery = enrichedByGid[item.signal.gid] ?? candidatesByGid[item.signal.gid];
      if (gallery == null) {
        continue;
      }
      results.add(AiXpRecommendation(
        gallery: gallery,
        score: item.score,
        explanations: item.explanations,
      ));
    }
    _report(onProgress, phaseScoringCandidates, current: results.length, total: results.length);
    return results;
  }

  // ---------------------------------------------------------------------------
  // Duplicates
  // ---------------------------------------------------------------------------

  /// Ensure live favorites are loaded, then group conservative duplicates.
  Future<AiXpDuplicatePlanResult> planDuplicates({
    AiXpProgressCallback? onProgress,
  }) async {
    await _ensureLiveFavorites(onProgress: onProgress);
    _report(onProgress, phaseScanningDuplicates, current: 0, total: _favoriteSignals.length);

    final List<AiXpDuplicateGroup> groups = _engine.groupDuplicates(_favoriteSignals);
    _report(onProgress, phaseScanningDuplicates, current: groups.length, total: groups.length);

    return AiXpDuplicatePlanResult(
      groups: groups,
      galleriesByGid: Map<int, Gallery>.from(_galleryByGid),
    );
  }

  /// Remove duplicate gids (non-keepers) at concurrency 3; refresh counts and rebuild profile.
  Future<AiXpApplyResult> applyDuplicateRemoval(
    List<AiXpDuplicateGroup> groups, {
    AiXpProgressCallback? onProgress,
  }) async {
    final List<int> toRemove = <int>[];
    final Set<int> seen = <int>{};
    for (final AiXpDuplicateGroup group in groups) {
      for (final int gid in group.duplicateGids) {
        if (seen.add(gid)) {
          toRemove.add(gid);
        }
      }
    }
    return removeFavoriteGids(toRemove, onProgress: onProgress);
  }

  /// Delete server favorites by gid using cached tokens; concurrency 3.
  Future<AiXpApplyResult> removeFavoriteGids(
    List<int> gids, {
    AiXpProgressCallback? onProgress,
  }) async {
    if (gids.isEmpty) {
      return const AiXpApplyResult(successCount: 0, failureCount: 0);
    }

    await _ensureLiveFavorites(onProgress: onProgress);

    final List<Gallery> targets = <Gallery>[];
    int missing = 0;
    for (final int gid in gids) {
      final Gallery? gallery = _galleryByGid[gid];
      if (gallery == null) {
        missing++;
        log.warning('removeFavoriteGids: missing cached gallery gid=$gid');
        continue;
      }
      targets.add(gallery);
    }

    int success = 0;
    int failure = missing;
    final int total = gids.length;
    _report(onProgress, phaseRemovingDuplicates, current: 0, total: total);

    await runWithConcurrency<Gallery>(
      items: targets,
      concurrency: _mutationConcurrency,
      isCancelled: () => false,
      onProgress: (int completed, int _) {
        _report(onProgress, phaseRemovingDuplicates, current: completed, total: total);
      },
      action: (Gallery gallery) async {
        try {
          await ehRequest.requestRemoveFavorite(gallery.gid, gallery.token);
          success++;
          _removeFromCache(gallery.gid);
        } on DioException catch (e) {
          failure++;
          log.error('ai xp remove favorite fail gid=${gallery.gid}', e.errorMsg);
        } on EHSiteException catch (e) {
          failure++;
          log.error('ai xp remove favorite fail gid=${gallery.gid}', e.message);
        } catch (e, s) {
          failure++;
          log.error('ai xp remove favorite fail gid=${gallery.gid}', e, s);
        }
      },
    );

    try {
      await favoriteSetting.fetchDataFromEH();
    } catch (e, s) {
      log.warning('refresh favoriteSetting after duplicate removal failed', e, s);
    }

    await _rebuildAndSaveProfileFromCache(onProgress: onProgress);
    return AiXpApplyResult(successCount: success, failureCount: failure);
  }

  // ---------------------------------------------------------------------------
  // Organization
  // ---------------------------------------------------------------------------

  /// Ensure live favorites, build local plan, optionally refine via remote AI.
  Future<AiXpOrganizationPlanResult> planOrganization(
    String requirements, {
    AiXpProgressCallback? onProgress,
  }) async {
    await _ensureLiveFavorites(onProgress: onProgress);
    _report(onProgress, phaseAnalyzingOrganization, current: 0, total: 1);

    final List<String> categoryNames = List<String>.from(favoriteSetting.favoriteTagNames);
    final AiXpOrganizationPlan localPlan = _engine.organizeFavorites(
      requirements: requirements,
      favorites: _favoriteSignals,
      categoryNames: categoryNames,
    );

    bool usedRemote = false;
    bool remoteFallback = false;
    AiXpOrganizationPlan plan = localPlan;

    if (aiSetting.isReady && requirements.trim().isNotEmpty && _favoriteSignals.isNotEmpty) {
      try {
        final AiXpOrganizationPlan? remotePlan = await _remoteOrganizeFavorites(
          requirements: requirements,
          categoryNames: categoryNames,
        );
        if (remotePlan != null) {
          plan = remotePlan;
          usedRemote = true;
        } else {
          remoteFallback = true;
        }
      } catch (e, s) {
        remoteFallback = true;
        log.error('remote organization failed, falling back to local plan', e, s);
      }
    }

    _report(onProgress, phaseAnalyzingOrganization, current: 1, total: 1);
    return AiXpOrganizationPlanResult(
      plan: plan,
      galleriesByGid: Map<int, Gallery>.from(_galleryByGid),
      usedRemoteAi: usedRemote,
      remoteFallback: remoteFallback,
    );
  }

  /// Apply favorite reassignments at concurrency 3; refresh counts and rebuild profile.
  Future<AiXpApplyResult> applyOrganizationMoves(
    List<AiXpOrganizationMove> moves, {
    AiXpProgressCallback? onProgress,
  }) async {
    if (moves.isEmpty) {
      return const AiXpApplyResult(successCount: 0, failureCount: 0);
    }

    await _ensureLiveFavorites(onProgress: onProgress);

    final int categoryCount = favoriteSetting.favoriteTagNames.length;
    final List<AiXpOrganizationMove> validMoves = <AiXpOrganizationMove>[];
    int failure = 0;
    for (final AiXpOrganizationMove move in moves) {
      if (move.targetIndex < 0 || move.targetIndex >= categoryCount) {
        failure++;
        log.warning('applyOrganizationMoves: invalid targetIndex=${move.targetIndex} gid=${move.gid}');
        continue;
      }
      if (!_galleryByGid.containsKey(move.gid)) {
        failure++;
        log.warning('applyOrganizationMoves: missing cached gallery gid=${move.gid}');
        continue;
      }
      validMoves.add(move);
    }

    int success = 0;
    final int total = moves.length;
    _report(onProgress, phaseApplyingOrganization, current: 0, total: total);

    await runWithConcurrency<AiXpOrganizationMove>(
      items: validMoves,
      concurrency: _mutationConcurrency,
      isCancelled: () => false,
      onProgress: (int completed, int _) {
        _report(onProgress, phaseApplyingOrganization, current: completed, total: total);
      },
      action: (AiXpOrganizationMove move) async {
        final Gallery gallery = _galleryByGid[move.gid]!;
        try {
          final GalleryNote galleryNote = await ehRequest.requestPopupPage<GalleryNote>(
            gallery.gid,
            gallery.token,
            'addfav',
            EHSpiderParser.favoritePopup2GalleryNote,
          );
          await ehRequest.requestAddFavorite(
            gallery.gid,
            gallery.token,
            move.targetIndex,
            galleryNote.note,
          );
          success++;
          _updateFavoriteCategoryInCache(
            gid: move.gid,
            targetIndex: move.targetIndex,
            targetName: move.targetName,
          );
        } on DioException catch (e) {
          failure++;
          log.error('ai xp organize move fail gid=${move.gid}', e.errorMsg);
        } on EHSiteException catch (e) {
          failure++;
          log.error('ai xp organize move fail gid=${move.gid}', e.message);
        } catch (e, s) {
          failure++;
          log.error('ai xp organize move fail gid=${move.gid}', e, s);
        }
      },
    );

    try {
      await favoriteSetting.fetchDataFromEH();
    } catch (e, s) {
      log.warning('refresh favoriteSetting after organization failed', e, s);
    }

    await _rebuildAndSaveProfileFromCache(onProgress: onProgress);
    return AiXpApplyResult(successCount: success, failureCount: failure);
  }

  // ---------------------------------------------------------------------------
  // Enhanced search
  // ---------------------------------------------------------------------------

  /// Parse NL query into [SearchConfig], optionally refining via remote AI.
  ///
  /// Top profile tags are injected only when the raw query explicitly asks for
  /// `my XP` / `我的XP` / `符合XP`.
  Future<AiXpEnhancedSearchResult> buildEnhancedSearch(
    String query, {
    AiXpProfile? profile,
    AiXpProgressCallback? onProgress,
  }) async {
    _report(onProgress, phaseInterpretingSearch, current: 0, total: 1);

    AiXpSearchIntent intent = _engine.parseSearchIntent(query);
    bool usedRemote = false;
    bool remoteFallback = false;

    if (aiSetting.isReady && query.trim().isNotEmpty) {
      try {
        final AiXpSearchIntent? remoteIntent = await _remoteParseSearchIntent(query, intent);
        if (remoteIntent != null) {
          intent = remoteIntent;
          usedRemote = true;
        } else {
          remoteFallback = true;
        }
      } catch (e, s) {
        remoteFallback = true;
        log.error('remote enhanced search failed, falling back to local intent', e, s);
      }
    }

    final AiXpProfile? effectiveProfile = profile ?? _profile ?? await loadProfile();
    final bool injectXp = _queryRequestsXpInjection(query);
    final SearchConfig config = intentToSearchConfig(
      intent,
      profile: injectXp ? effectiveProfile : null,
      injectXpTags: injectXp,
    );

    _report(onProgress, phaseInterpretingSearch, current: 1, total: 1);
    return AiXpEnhancedSearchResult(
      searchConfig: config,
      intent: intent,
      usedRemoteAi: usedRemote,
      remoteFallback: remoteFallback,
      injectedXpTags: injectXp && (effectiveProfile?.tagWeights.isNotEmpty ?? false),
    );
  }

  /// Convert [AiXpSearchIntent] into [SearchConfig].
  SearchConfig intentToSearchConfig(
    AiXpSearchIntent intent, {
    AiXpProfile? profile,
    bool injectXpTags = false,
  }) {
    final SearchConfig config = SearchConfig(searchType: SearchType.gallery);

    if (intent.categories.isNotEmpty) {
      _applyCategoryFilters(config, intent.categories);
    }

    final List<TagData> tags = <TagData>[];
    for (final String raw in intent.tags) {
      final TagData? tag = _tagDataFromSignal(raw);
      if (tag != null) {
        tags.add(tag);
      }
    }

    if (injectXpTags && profile != null && profile.tagWeights.isNotEmpty) {
      final List<MapEntry<String, double>> sorted = profile.tagWeights.entries.toList()
        ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
          final int byWeight = b.value.compareTo(a.value);
          if (byWeight != 0) {
            return byWeight;
          }
          return a.key.compareTo(b.key);
        });
      final Set<String> existing = tags.map((TagData t) => '${t.namespace}:${t.key}').toSet();
      int added = 0;
      for (final MapEntry<String, double> entry in sorted) {
        if (added >= _maxXpInjectTags) {
          break;
        }
        final TagData? tag = _tagDataFromSignal(entry.key);
        if (tag == null) {
          continue;
        }
        final String key = '${tag.namespace}:${tag.key}';
        if (!existing.add(key)) {
          continue;
        }
        tags.add(tag);
        added++;
      }
    }

    if (tags.isNotEmpty) {
      config.tags = tags;
    }

    // Prefer residual keywords; only fall back to free-form xpPreference when
    // there is no structured tag/category signal left to search with.
    final String residual = intent.residualKeyword.trim();
    final String xp = intent.xpPreference?.trim() ?? '';
    if (residual.isNotEmpty) {
      config.keyword = residual;
    } else if (xp.isNotEmpty && tags.isEmpty && intent.categories.isEmpty) {
      config.keyword = xp;
    }

    if (intent.language != null && intent.language!.isNotEmpty) {
      config.language = intent.language;
    }

    if (intent.requireTorrent == true) {
      config.onlyShowGalleriesWithTorrents = true;
      config.onlyShowGalleriesWithoutTorrents = false;
    } else if (intent.requireTorrent == false) {
      config.onlyShowGalleriesWithoutTorrents = true;
      config.onlyShowGalleriesWithTorrents = false;
    }

    if (intent.minimumRating != null) {
      config.minimumRating = intent.minimumRating!.clamp(1, 5).toInt();
    }
    config.pageAtLeast = intent.pageAtLeast;
    config.pageAtMost = intent.pageAtMost;

    return config;
  }

  // ---------------------------------------------------------------------------
  // Internal: favorites load / enrich
  // ---------------------------------------------------------------------------

  Future<void> _ensureLiveFavorites({AiXpProgressCallback? onProgress}) async {
    if (hasLiveFavorites) {
      return;
    }
    final List<Gallery> favorites = await _enumerateAllServerFavorites(onProgress: onProgress);
    final ({List<Gallery> galleries, List<AiGallerySignal> signals, int failures}) enriched =
        await _enrichFavorites(favorites, onProgress: onProgress);
    if (enriched.failures > 0) {
      log.warning('ensureLiveFavorites metadata failures: ${enriched.failures}');
    }
    _replaceFavoriteCache(enriched.galleries, enriched.signals);
  }

  Future<List<Gallery>> _enumerateAllServerFavorites({
    AiXpProgressCallback? onProgress,
  }) async {
    final SearchConfig searchConfig = SearchConfig(searchType: SearchType.favorite);
    final List<Gallery> all = <Gallery>[];
    final Set<int> seenGids = <int>{};
    final Set<String> seenCursors = <String>{};
    String? nextGid;

    while (true) {
      if (nextGid != null && !seenCursors.add(nextGid)) {
        log.warning('ai xp favorite enumerate stopped: repeated cursor $nextGid');
        break;
      }

      final GalleryPageInfo page;
      try {
        page = await ehRequest.requestGalleryPage(
          nextGid: nextGid,
          searchConfig: searchConfig,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo,
        );
      } on DioException catch (e) {
        log.error('ai xp enumerate favorites fail', e.errorMsg);
        rethrow;
      } on EHSiteException catch (e) {
        log.error('ai xp enumerate favorites fail', e.message);
        rethrow;
      }

      for (final Gallery gallery in page.gallerys) {
        if (seenGids.add(gallery.gid)) {
          all.add(gallery);
        }
      }

      _report(onProgress, phaseLoadingFavorites, current: all.length, total: 0);

      if (page.nextGid == null) {
        break;
      }
      nextGid = page.nextGid;
    }

    return all;
  }

  Future<({List<Gallery> galleries, List<AiGallerySignal> signals, int failures})> _enrichFavorites(
    List<Gallery> favorites, {
    AiXpProgressCallback? onProgress,
  }) {
    return _enrichGalleries(
      favorites,
      onProgress: onProgress,
      progressPhase: phaseLoadingMetadata,
      preserveFavoriteFields: true,
    );
  }

  /// Enrich galleries via gdata chunks of at most 25.
  ///
  /// When [preserveFavoriteFields] is true, original gid/token/favorite category
  /// and list-page times are kept; metadata fills tags/title/rating/pages.
  Future<({List<Gallery> galleries, List<AiGallerySignal> signals, int failures})> _enrichGalleries(
    List<Gallery> source, {
    AiXpProgressCallback? onProgress,
    required String progressPhase,
    required bool preserveFavoriteFields,
  }) async {
    if (source.isEmpty) {
      return (galleries: <Gallery>[], signals: <AiGallerySignal>[], failures: 0);
    }

    final List<Gallery> outGalleries = <Gallery>[];
    final List<AiGallerySignal> outSignals = <AiGallerySignal>[];
    int failures = 0;
    int processed = 0;
    final int total = source.length;

    _report(onProgress, progressPhase, current: 0, total: total);

    final List<List<Gallery>> chunks = chunkList(source, _gdataChunkSize);
    for (final List<Gallery> chunk in chunks) {
      Map<int, GalleryMetadata> byGid = <int, GalleryMetadata>{};
      try {
        final List<GalleryMetadata> metadatas = await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: chunk.map((Gallery g) => (gid: g.gid, token: g.token)).toList(),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        );
        for (final GalleryMetadata meta in metadatas) {
          byGid.putIfAbsent(meta.galleryUrl.gid, () => meta);
        }
      } on DioException catch (e) {
        failures += chunk.length;
        log.error('ai xp gdata chunk failed', e.errorMsg);
        byGid = <int, GalleryMetadata>{};
      } on EHSiteException catch (e) {
        failures += chunk.length;
        log.error('ai xp gdata chunk failed', e.message);
        byGid = <int, GalleryMetadata>{};
      } catch (e, s) {
        failures += chunk.length;
        log.error('ai xp gdata chunk failed', e, s);
        byGid = <int, GalleryMetadata>{};
      }

      final bool chunkFullyFailed = byGid.isEmpty;
      for (final Gallery original in chunk) {
        final GalleryMetadata? meta = byGid[original.gid];
        if (meta == null && !chunkFullyFailed) {
          failures++;
        }

        final Gallery merged = _mergeGallery(original, meta, preserveFavoriteFields: preserveFavoriteFields);
        final AiGallerySignal signal = _galleryToSignal(
          original: original,
          merged: merged,
          meta: meta,
          preserveFavoriteFields: preserveFavoriteFields,
        );
        outGalleries.add(merged);
        outSignals.add(signal);
      }

      processed += chunk.length;
      _report(onProgress, progressPhase, current: processed, total: total);
    }

    return (galleries: outGalleries, signals: outSignals, failures: failures);
  }

  Gallery _mergeGallery(
    Gallery original,
    GalleryMetadata? meta, {
    required bool preserveFavoriteFields,
  }) {
    if (meta == null) {
      return original;
    }

    return original.copyWith(
      // Keep original galleryUrl (gid/token) always.
      title: meta.title.isNotEmpty ? meta.title : original.title,
      category: meta.category.isNotEmpty ? meta.category : original.category,
      pageCount: meta.pageCount,
      rating: meta.rating,
      language: meta.language.isNotEmpty ? meta.language : original.language,
      uploader: meta.uploader ?? original.uploader,
      publishTime: preserveFavoriteFields
          ? original.publishTime
          : (meta.publishTime.isNotEmpty ? meta.publishTime : original.publishTime),
      isExpunged: meta.isExpunged,
      tags: meta.tags.isNotEmpty ? meta.tags : original.tags,
      favoriteTagIndex: preserveFavoriteFields ? original.favoriteTagIndex : original.favoriteTagIndex,
      favoriteTagName: preserveFavoriteFields ? original.favoriteTagName : original.favoriteTagName,
    );
  }

  AiGallerySignal _galleryToSignal({
    required Gallery original,
    required Gallery merged,
    required GalleryMetadata? meta,
    required bool preserveFavoriteFields,
  }) {
    final List<String> tags = _tagsToSignals(merged.tags);
    final int? listTimeMs = _parseTimeMs(original.publishTime);
    final int? metaPostedMs = meta != null ? _parseTimeMs(meta.publishTime) : null;

    return AiGallerySignal(
      gid: original.gid,
      title: merged.title,
      category: merged.category,
      tags: tags,
      uploader: merged.uploader,
      rating: merged.rating,
      pageCount: merged.pageCount ?? meta?.pageCount,
      language: merged.language,
      torrentCount: meta?.torrentCount,
      favoriteCategoryIndex: preserveFavoriteFields ? original.favoriteTagIndex : merged.favoriteTagIndex,
      favoriteCategoryName: preserveFavoriteFields ? original.favoriteTagName : merged.favoriteTagName,
      favoritedAtMs: preserveFavoriteFields ? listTimeMs : null,
      publishedAtMs: metaPostedMs ?? (preserveFavoriteFields ? null : listTimeMs),
    );
  }

  List<String> _tagsToSignals(LinkedHashMap<String, List<GalleryTag>> tags) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    tags.forEach((String namespace, List<GalleryTag> list) {
      for (final GalleryTag tag in list) {
        final String ns = tag.tagData.namespace.isNotEmpty ? tag.tagData.namespace : namespace;
        final String key = tag.tagData.key;
        if (key.isEmpty) {
          continue;
        }
        final String signal = ns.isEmpty ? key : '$ns:$key';
        if (seen.add(signal)) {
          out.add(signal);
        }
      }
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Internal: recommendation search construction
  // ---------------------------------------------------------------------------

  List<SearchConfig> _buildRecommendationSearches(AiXpProfile profile) {
    final List<SearchConfig> searches = <SearchConfig>[];
    final Set<String> usedKeys = <String>{};

    // Prefer high-weight tag pairs (focused dual-tag searches).
    for (final AiXpTagPair pair in profile.tagPairs) {
      if (searches.length >= _maxRecommendationSearches) {
        break;
      }
      final String key = 'pair:${pair.left}+${pair.right}';
      if (!usedKeys.add(key)) {
        continue;
      }
      final TagData? left = _tagDataFromSignal(pair.left);
      final TagData? right = _tagDataFromSignal(pair.right);
      if (left == null || right == null) {
        continue;
      }
      searches.add(SearchConfig(
        searchType: SearchType.gallery,
        tags: <TagData>[left, right],
        hideFavoritedGalleries: true,
      ));
    }

    // Fill remaining slots with highest single-tag weights.
    final List<MapEntry<String, double>> tagEntries = profile.tagWeights.entries.toList()
      ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
        final int byWeight = b.value.compareTo(a.value);
        if (byWeight != 0) {
          return byWeight;
        }
        return a.key.compareTo(b.key);
      });

    for (final MapEntry<String, double> entry in tagEntries) {
      if (searches.length >= _maxRecommendationSearches) {
        break;
      }
      final String key = 'tag:${entry.key}';
      if (!usedKeys.add(key)) {
        continue;
      }
      final TagData? tag = _tagDataFromSignal(entry.key);
      if (tag == null) {
        continue;
      }
      searches.add(SearchConfig(
        searchType: SearchType.gallery,
        tags: <TagData>[tag],
        hideFavoritedGalleries: true,
      ));
    }

    // Fall back to title keywords when tags/pairs are insufficient.
    if (searches.isEmpty) {
      final List<MapEntry<String, double>> titleEntries = profile.titleWeights.entries.toList()
        ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
          final int byWeight = b.value.compareTo(a.value);
          if (byWeight != 0) {
            return byWeight;
          }
          return a.key.compareTo(b.key);
        });

      for (final MapEntry<String, double> entry in titleEntries) {
        if (searches.length >= _maxRecommendationSearches) {
          break;
        }
        final String token = entry.key.trim();
        if (token.isEmpty) {
          continue;
        }
        final String key = 'title:$token';
        if (!usedKeys.add(key)) {
          continue;
        }
        searches.add(SearchConfig(
          searchType: SearchType.gallery,
          keyword: token,
          hideFavoritedGalleries: true,
        ));
      }
    }

    return searches;
  }

  // ---------------------------------------------------------------------------
  // Internal: remote AI helpers
  // ---------------------------------------------------------------------------

  Future<AiXpOrganizationPlan?> _remoteOrganizeFavorites({
    required String requirements,
    required List<String> categoryNames,
  }) async {
    final List<AiXpOrganizationMove> allMoves = <AiXpOrganizationMove>[];
    final Set<int> moved = <int>{};
    final List<List<AiGallerySignal>> chunks = chunkList(_favoriteSignals, _orgRemoteChunkSize);

    for (final List<AiGallerySignal> chunk in chunks) {
      final Map<String, dynamic> userPayload = <String, dynamic>{
        'requirements': requirements,
        'categories': <Map<String, dynamic>>[
          for (int i = 0; i < categoryNames.length; i++)
            <String, dynamic>{'index': i, 'name': categoryNames[i]},
        ],
        'favorites': chunk.map((AiGallerySignal s) {
          return <String, dynamic>{
            'gid': s.gid,
            'title': s.title,
            'category': s.category,
            'tags': s.tags,
            'favoriteCategoryIndex': s.favoriteCategoryIndex,
            'favoriteCategoryName': s.favoriteCategoryName,
            // Never include cover URLs, tokens, or API keys.
          };
        }).toList(),
      };

      final Map<String, dynamic> response = await aiRequest.requestJson(
        systemPrompt: _organizationSystemPrompt,
        userPrompt: jsonEncode(userPayload),
      );

      final Object? rawMoves = response['moves'];
      if (rawMoves is! List) {
        log.warning('remote organization response missing moves[]');
        return null;
      }

      for (final Object? item in rawMoves) {
        if (item is! Map) {
          continue;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(item);
        final int? gid = (map['gid'] as num?)?.toInt();
        final int? targetIndex = (map['targetIndex'] as num?)?.toInt();
        if (gid == null || targetIndex == null) {
          continue;
        }
        if (!_signalByGid.containsKey(gid) || moved.contains(gid)) {
          continue;
        }
        if (targetIndex < 0 || targetIndex >= categoryNames.length) {
          continue;
        }
        final AiGallerySignal? signal = _signalByGid[gid];
        if (signal?.favoriteCategoryIndex == targetIndex) {
          continue;
        }
        moved.add(gid);
        allMoves.add(AiXpOrganizationMove(
          gid: gid,
          fromIndex: signal?.favoriteCategoryIndex,
          targetIndex: targetIndex,
          targetName: categoryNames[targetIndex],
          matchedRule: map['matchedRule'] as String? ?? map['rule'] as String? ?? '',
          matchedTerm: map['matchedTerm'] as String? ?? map['term'] as String? ?? '',
        ));
      }
    }

    // Keep local rule parse for UI display even when moves come from remote.
    final List<AiXpOrganizationRule> rules = _engine.parseOrganizationRules(requirements, categoryNames);
    return AiXpOrganizationPlan(rules: rules, moves: allMoves);
  }

  Future<AiXpSearchIntent?> _remoteParseSearchIntent(
    String query,
    AiXpSearchIntent localFallback,
  ) async {
    final Map<String, dynamic> response = await aiRequest.requestJson(
      systemPrompt: _searchSystemPrompt,
      userPrompt: jsonEncode(<String, dynamic>{
        'query': query,
        'localHint': localFallback.toJson(),
      }),
    );

    final String rawQuery = response['rawQuery'] as String? ?? query;
    final String? language = response['language'] as String?;
    final bool? requireTorrent = response['requireTorrent'] as bool?;
    final int? minimumRating = (response['minimumRating'] as num?)?.toInt();
    final int? pageAtLeast = (response['pageAtLeast'] as num?)?.toInt();
    final int? pageAtMost = (response['pageAtMost'] as num?)?.toInt();

    final List<String> categories = <String>[];
    final Object? rawCategories = response['categories'];
    if (rawCategories is List) {
      for (final Object? c in rawCategories) {
        final String name = c.toString();
        if (_isKnownCategory(name)) {
          categories.add(_canonicalCategory(name));
        }
      }
    }

    final List<String> tags = <String>[];
    final Object? rawTags = response['tags'];
    if (rawTags is List) {
      for (final Object? t in rawTags) {
        final String tag = t.toString().trim();
        if (tag.contains(':')) {
          tags.add(AiXpEngine.normalizeTag(tag));
        }
      }
    }

    return AiXpSearchIntent(
      rawQuery: rawQuery,
      language: language ?? localFallback.language,
      requireTorrent: requireTorrent ?? localFallback.requireTorrent,
      minimumRating: minimumRating ?? localFallback.minimumRating,
      pageAtLeast: pageAtLeast ?? localFallback.pageAtLeast,
      pageAtMost: pageAtMost ?? localFallback.pageAtMost,
      categories: categories.isNotEmpty ? categories : localFallback.categories,
      tags: tags.isNotEmpty ? tags : localFallback.tags,
      xpPreference: response['xpPreference'] as String? ?? localFallback.xpPreference,
      residualKeyword: response['residualKeyword'] as String? ?? localFallback.residualKeyword,
    );
  }

  static const String _organizationSystemPrompt =
      'You reorganize E-Hentai favorite galleries into existing favorite categories. '
      'Reply with a single JSON object only, no markdown. Schema: '
      '{"moves":[{"gid":<int>,"targetIndex":<int>,"matchedRule":"<string>","matchedTerm":"<string>"}]}. '
      'Only use gids from the provided favorites list. targetIndex must be a valid category index. '
      'Do not invent categories. Prefer fewer, high-confidence moves. Never request or echo tokens, covers, or secrets.';

  static const String _searchSystemPrompt =
      'You convert a natural-language E-Hentai search request into structured JSON. '
      'Reply with a single JSON object only, no markdown. Schema: '
      '{"rawQuery":"<string>","language":"<string|null>","requireTorrent":<bool|null>,'
      '"minimumRating":<int|null>,"pageAtLeast":<int|null>,"pageAtMost":<int|null>,'
      '"categories":["Doujinshi"],"tags":["namespace:key"],"xpPreference":"<string|null>",'
      '"residualKeyword":"<string>"}. '
      'Categories must be EH names. Tags must be namespace:key. Never include tokens, covers, or secrets.';

  // ---------------------------------------------------------------------------
  // Internal: cache / profile rebuild
  // ---------------------------------------------------------------------------

  void _replaceFavoriteCache(List<Gallery> galleries, List<AiGallerySignal> signals) {
    _favoriteGalleries
      ..clear()
      ..addAll(galleries);
    _favoriteSignals
      ..clear()
      ..addAll(signals);
    _galleryByGid
      ..clear()
      ..addEntries(galleries.map((Gallery g) => MapEntry<int, Gallery>(g.gid, g)));
    _signalByGid
      ..clear()
      ..addEntries(signals.map((AiGallerySignal s) => MapEntry<int, AiGallerySignal>(s.gid, s)));
  }

  void _removeFromCache(int gid) {
    _favoriteGalleries.removeWhere((Gallery g) => g.gid == gid);
    _favoriteSignals.removeWhere((AiGallerySignal s) => s.gid == gid);
    _galleryByGid.remove(gid);
    _signalByGid.remove(gid);
  }

  void _updateFavoriteCategoryInCache({
    required int gid,
    required int targetIndex,
    required String targetName,
  }) {
    final Gallery? gallery = _galleryByGid[gid];
    if (gallery != null) {
      final Gallery updated = gallery.copyWith(
        favoriteTagIndex: targetIndex,
        favoriteTagName: targetName,
      );
      _galleryByGid[gid] = updated;
      final int index = _favoriteGalleries.indexWhere((Gallery g) => g.gid == gid);
      if (index >= 0) {
        _favoriteGalleries[index] = updated;
      }
    }

    final AiGallerySignal? signal = _signalByGid[gid];
    if (signal != null) {
      final AiGallerySignal updated = AiGallerySignal(
        gid: signal.gid,
        title: signal.title,
        category: signal.category,
        tags: signal.tags,
        uploader: signal.uploader,
        rating: signal.rating,
        pageCount: signal.pageCount,
        language: signal.language,
        torrentCount: signal.torrentCount,
        favoriteCategoryIndex: targetIndex,
        favoriteCategoryName: targetName,
        favoritedAtMs: signal.favoritedAtMs,
        publishedAtMs: signal.publishedAtMs,
      );
      _signalByGid[gid] = updated;
      final int index = _favoriteSignals.indexWhere((AiGallerySignal s) => s.gid == gid);
      if (index >= 0) {
        _favoriteSignals[index] = updated;
      }
    }
  }

  Future<void> _rebuildAndSaveProfileFromCache({AiXpProgressCallback? onProgress}) async {
    _report(onProgress, phaseBuildingProfile, current: 0, total: 1);
    final AiXpProfile profile = _engine.buildProfile(_favoriteSignals);
    await saveProfile(profile);
    _report(onProgress, phaseBuildingProfile, current: 1, total: 1);
  }

  // ---------------------------------------------------------------------------
  // Internal: helpers
  // ---------------------------------------------------------------------------

  void _report(AiXpProgressCallback? onProgress, String phase, {int current = 0, int total = 0}) {
    onProgress?.call(AiXpProgress(phase: phase, current: current, total: total));
  }

  static bool _queryRequestsXpInjection(String query) {
    final String lower = query.toLowerCase();
    return lower.contains('my xp') || lower.contains('我的xp') || lower.contains('符合xp');
  }

  static TagData? _tagDataFromSignal(String raw) {
    final String normalized = AiXpEngine.normalizeTag(raw);
    if (normalized.isEmpty) {
      return null;
    }
    final int sep = normalized.indexOf(':');
    if (sep <= 0 || sep >= normalized.length - 1) {
      // Bare key: still searchable as free-form TagData with empty namespace.
      return TagData(namespace: '', key: normalized);
    }
    return TagData(
      namespace: normalized.substring(0, sep),
      key: normalized.substring(sep + 1),
    );
  }

  static int? _parseTimeMs(String? raw) {
    if (raw == null) {
      return null;
    }
    final String text = raw.trim();
    if (text.isEmpty) {
      return null;
    }
    try {
      return DateTime.parse(text).millisecondsSinceEpoch;
    } catch (_) {}
    try {
      return DateFormat('yyyy-MM-dd HH:mm').parse(text).millisecondsSinceEpoch;
    } catch (_) {}
    try {
      return DateFormat('yyyy-MM-dd HH:mm:ss').parse(text).millisecondsSinceEpoch;
    } catch (_) {}
    return null;
  }

  static void _applyCategoryFilters(SearchConfig config, List<String> categories) {
    config.disableAllCategories();
    for (final String raw in categories) {
      switch (_canonicalCategory(raw)) {
        case 'Doujinshi':
          config.includeDoujinshi = true;
          break;
        case 'Manga':
          config.includeManga = true;
          break;
        case 'Artist CG':
          config.includeArtistCG = true;
          break;
        case 'Game CG':
          config.includeGameCg = true;
          break;
        case 'Western':
          config.includeWestern = true;
          break;
        case 'Non-H':
          config.includeNonH = true;
          break;
        case 'Image Set':
          config.includeImageSet = true;
          break;
        case 'Cosplay':
          config.includeCosplay = true;
          break;
        case 'Asian Porn':
          config.includeAsianPorn = true;
          break;
        case 'Misc':
          config.includeMisc = true;
          break;
      }
    }
  }

  static const Map<String, String> _categoryCanonical = <String, String>{
    'doujinshi': 'Doujinshi',
    'manga': 'Manga',
    'artist cg': 'Artist CG',
    'artistcg': 'Artist CG',
    'artist_cg': 'Artist CG',
    'game cg': 'Game CG',
    'gamecg': 'Game CG',
    'game_cg': 'Game CG',
    'western': 'Western',
    'non-h': 'Non-H',
    'nonh': 'Non-H',
    'non_h': 'Non-H',
    'image set': 'Image Set',
    'imageset': 'Image Set',
    'image_set': 'Image Set',
    'cosplay': 'Cosplay',
    'asian porn': 'Asian Porn',
    'asianporn': 'Asian Porn',
    'asian_porn': 'Asian Porn',
    'misc': 'Misc',
  };

  static bool _isKnownCategory(String raw) {
    final String lower = raw.trim().toLowerCase();
    if (_categoryCanonical.containsKey(lower)) {
      return true;
    }
    for (final String name in _categoryCanonical.values) {
      if (name.toLowerCase() == lower) {
        return true;
      }
    }
    return false;
  }

  static String _canonicalCategory(String raw) {
    final String lower = raw.trim().toLowerCase();
    final String? mapped = _categoryCanonical[lower];
    if (mapped != null) {
      return mapped;
    }
    for (final String name in _categoryCanonical.values) {
      if (name.toLowerCase() == lower) {
        return name;
      }
    }
    return raw.trim();
  }
}
