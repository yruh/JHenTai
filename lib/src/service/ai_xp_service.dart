import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/model/ai_favorite_snapshot.dart';
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
import 'package:jhentai/src/setting/eh_setting.dart';
import 'package:jhentai/src/setting/favorite_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
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

/// Orchestrates the shared favorite snapshot, local statistical preprocessing,
/// EH searches, and remote-AI profile/recommendation decisions.
class AiXpService {
  static const int _gdataChunkSize = 25;
  static const int _mutationConcurrency = 3;
  static const int _orgRemoteChunkSize = 50;
  static const int _maxRecommendationSearches = 6;
  static const int _maxRecommendations = 30;
  static const int _maxRemoteRankingCandidates = 80;
  static const int _maxRemotePreferences = 10;
  static const int _maxRemoteEvidenceTags = 12;
  static const int _maxRemoteStrategyTags = 4;
  static const int _maxProfileRepresentativeFavorites = 60;
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

  /// True after a matching owner snapshot (including empty) is loaded into memory.
  bool _favoriteCacheLoaded = false;
  String? _favoriteCacheOwnerKey;
  int? _favoriteCacheCapturedAtMs;
  int _lastMetadataFailureCount = 0;

  /// Single-flight handle for [_ensureLiveFavorites].
  Future<void>? _ensureLiveFavoritesFuture;
  bool _ensureLiveFavoritesInFlightForce = false;

  AiXpService({AiXpEngine engine = const AiXpEngine()}) : _engine = engine;

  AiXpProfile? get cachedProfile => _profile;

  List<Gallery> get cachedFavoriteGalleries =>
      List<Gallery>.unmodifiable(_favoriteGalleries);

  List<AiGallerySignal> get cachedFavoriteSignals =>
      List<AiGallerySignal>.unmodifiable(_favoriteSignals);

  /// Number of galleries currently held in the shared favorite cache for the current owner.
  int get favoriteCacheCount =>
      hasFavoriteCache ? _favoriteGalleries.length : 0;

  /// Epoch ms when the in-memory favorite cache was captured; null if unloaded.
  int? get favoriteCacheCapturedAtMs =>
      hasFavoriteCache ? _favoriteCacheCapturedAtMs : null;

  /// Whether a valid owner-scoped favorite snapshot is loaded (empty is valid).
  bool get hasFavoriteCache =>
      _favoriteCacheLoaded && _favoriteCacheOwnerKey == _currentOwnerKey();

  /// Reflects loaded-cache semantics (including a successful empty snapshot).
  bool get hasLiveFavorites => hasFavoriteCache;

  // ---------------------------------------------------------------------------
  // Profile persistence
  // ---------------------------------------------------------------------------

  /// Load versioned [AiXpProfile] from owner-scoped [ConfigEnum.aiXpProfile] JSON.
  /// Also hydrates a matching [AiFavoriteSnapshot] into the shared gallery/signal maps.
  Future<AiXpProfile?> loadProfile() async {
    final String ownerKey = _currentOwnerKey();
    // Drop in-memory favorites belonging to a different account/site.
    if (_favoriteCacheOwnerKey != null && _favoriteCacheOwnerKey != ownerKey) {
      _clearFavoriteCacheMemory();
    }

    try {
      String? raw = await localConfigService.read(
        configKey: ConfigEnum.aiXpProfile,
        subConfigKey: ownerKey,
      );
      if (raw == null || raw.isEmpty) {
        _profile = null;
      } else {
        final Object? decoded = jsonDecode(raw);
        if (decoded is! Map) {
          log.warning('aiXpProfile config is not a JSON object');
          _profile = null;
        } else {
          _profile = AiXpProfile.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (e, s) {
      log.error('load AiXpProfile failed', e, s);
      _profile = null;
    }

    await _tryHydrateFavoriteCacheFromSnapshot(ownerKey);
    return _profile;
  }

  /// Persist versioned [AiXpProfile] JSON under owner-scoped [ConfigEnum.aiXpProfile].
  Future<void> saveProfile(AiXpProfile profile) async {
    _profile = profile;
    await localConfigService.write(
      configKey: ConfigEnum.aiXpProfile,
      subConfigKey: _currentOwnerKey(),
      value: jsonEncode(profile.toJson()),
    );
  }

  // ---------------------------------------------------------------------------
  // Analyze favorites -> profile
  // ---------------------------------------------------------------------------

  /// Ensure shared favorite cache (reuse unless [forceRefresh]), then build and save profile.
  ///
  /// Counts are reported from the shared cache. A full server scan runs only when the
  /// cache is absent or [forceRefresh] is true (explicit profile refresh).
  Future<AiXpAnalysisResult> analyzeFavorites({
    bool forceRefresh = false,
    AiXpProgressCallback? onProgress,
  }) async {
    _requireRemoteAi();
    _report(onProgress, phaseLoadingFavorites, current: 0, total: 0);
    await _ensureLiveFavorites(
        forceRefresh: forceRefresh, onProgress: onProgress);

    _report(onProgress, phaseBuildingProfile, current: 0, total: 1);
    final AiXpProfile statisticalProfile =
        _engine.buildProfile(_favoriteSignals);
    final AiXpProfile profile = statisticalProfile.isEmpty
        ? statisticalProfile
        : await _remoteBuildProfile(statisticalProfile);
    await saveProfile(profile);
    _report(onProgress, phaseBuildingProfile, current: 1, total: 1);

    return AiXpAnalysisResult(
      profile: profile,
      favoriteCount: favoriteCacheCount,
      metadataFailureCount: _lastMetadataFailureCount,
      signalCount: _favoriteSignals.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Recommendations
  // ---------------------------------------------------------------------------

  /// Search EH with remote-AI strategies, locally prune the payload, then ask
  /// remote AI for the final top-30 ranking and human-readable reasons.
  Future<List<AiXpRecommendation>> generateRecommendations({
    AiXpProfile? profile,
    AiXpProgressCallback? onProgress,
  }) async {
    _requireRemoteAi();

    AiXpProfile? loadedProfile = profile ?? _profile;
    if (loadedProfile == null) {
      await loadProfile();
      loadedProfile = _profile;
    }
    await _ensureLiveFavorites(onProgress: onProgress);

    AiXpProfile effective =
        loadedProfile ?? _engine.buildProfile(_favoriteSignals);
    if (effective.isEmpty) {
      return const <AiXpRecommendation>[];
    }
    if (!effective.generatedByRemoteAi ||
        !effective.searchStrategies.any(_isUsableSearchStrategy)) {
      final AiXpProfile statisticalProfile =
          _engine.buildProfile(_favoriteSignals);
      if (statisticalProfile.isEmpty) {
        return const <AiXpRecommendation>[];
      }
      _report(onProgress, phaseBuildingProfile, current: 0, total: 1);
      effective = await _remoteBuildProfile(statisticalProfile);
      await saveProfile(effective);
      _report(onProgress, phaseBuildingProfile, current: 1, total: 1);
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
      _report(onProgress, phaseFetchingCandidates,
          current: searchIndex, total: totalSearches);
      try {
        final GalleryPageInfo page = await ehRequest.requestGalleryPage(
          searchConfig: config,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo,
        );
        for (final Gallery gallery in page.galleries) {
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
    final ({
      List<Gallery> galleries,
      List<AiGallerySignal> signals,
      int failures
    }) enriched = await _enrichGalleries(
      candidateGalleries,
      onProgress: onProgress,
      progressPhase: phaseFetchingCandidates,
      preserveFavoriteFields: false,
    );
    if (enriched.failures > 0) {
      log.warning('recommendation metadata failures: ${enriched.failures}');
    }

    _report(onProgress, phaseScoringCandidates,
        current: 0, total: enriched.signals.length);

    // Local scoring is only a bounded payload pre-filter. Append high-rated
    // unmatched rows so the deterministic heuristic cannot make the final choice.
    final List<AiXpRankedCandidate> locallyRanked = _engine.rankCandidates(
      profile: effective,
      candidates: enriched.signals,
      limit: _maxRemoteRankingCandidates,
      applyUploaderDiversity: false,
    );
    final List<AiGallerySignal> remoteCandidates =
        locallyRanked.map((AiXpRankedCandidate item) => item.signal).toList();
    final Set<int> selectedGids =
        remoteCandidates.map((AiGallerySignal signal) => signal.gid).toSet();
    final List<AiGallerySignal> remaining = enriched.signals
        .where((AiGallerySignal signal) => !selectedGids.contains(signal.gid))
        .toList()
      ..sort((AiGallerySignal a, AiGallerySignal b) {
        final int byRating = b.rating.compareTo(a.rating);
        return byRating != 0 ? byRating : a.gid.compareTo(b.gid);
      });
    for (final AiGallerySignal signal in remaining) {
      if (remoteCandidates.length >= _maxRemoteRankingCandidates) {
        break;
      }
      remoteCandidates.add(signal);
    }

    final List<AiXpRankedCandidate> ranked = await _remoteRankCandidates(
      profile: effective,
      candidates: remoteCandidates,
    );

    final Map<int, Gallery> enrichedByGid = <int, Gallery>{
      for (final Gallery g in enriched.galleries) g.gid: g,
    };

    final List<AiXpRecommendation> results = <AiXpRecommendation>[];
    for (final AiXpRankedCandidate item in ranked) {
      final Gallery? gallery =
          enrichedByGid[item.signal.gid] ?? candidatesByGid[item.signal.gid];
      if (gallery == null) {
        continue;
      }
      results.add(AiXpRecommendation(
        gallery: gallery,
        score: item.score,
        explanations: item.explanations,
      ));
    }
    _report(onProgress, phaseScoringCandidates,
        current: results.length, total: results.length);
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
    _report(onProgress, phaseScanningDuplicates,
        current: 0, total: _favoriteSignals.length);

    final List<AiXpDuplicateGroup> groups =
        _engine.groupDuplicates(_favoriteSignals);
    _report(onProgress, phaseScanningDuplicates,
        current: groups.length, total: groups.length);

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
        _report(onProgress, phaseRemovingDuplicates,
            current: completed, total: total);
      },
      action: (Gallery gallery) async {
        try {
          await ehRequest.requestRemoveFavorite(gallery.gid, gallery.token);
          success++;
          _removeFromCache(gallery.gid);
        } on DioException catch (e) {
          failure++;
          log.error(
              'ai xp remove favorite fail gid=${gallery.gid}', e.errorMsg);
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
    } catch (e) {
      log.warning(
          'refresh favoriteSetting after duplicate removal failed', e, true);
    }

    if (success > 0) {
      await _persistCurrentFavoriteSnapshot();
    }
    await _rebuildAndSaveProfileFromCache(onProgress: onProgress);
    return AiXpApplyResult(successCount: success, failureCount: failure);
  }

  // ---------------------------------------------------------------------------
  // Organization
  // ---------------------------------------------------------------------------

  /// Ask remote AI to organize the shared favorite snapshot.
  Future<AiXpOrganizationPlanResult> planOrganization(
    String requirements, {
    AiXpProgressCallback? onProgress,
  }) async {
    _requireRemoteAi();
    await _ensureLiveFavorites(onProgress: onProgress);
    _report(onProgress, phaseAnalyzingOrganization, current: 0, total: 1);

    final List<String> categoryNames =
        List<String>.from(favoriteSetting.favoriteTagNames);
    final AiXpOrganizationPlan plan = _favoriteSignals.isEmpty
        ? const AiXpOrganizationPlan()
        : await _remoteOrganizeFavorites(
            requirements: requirements,
            categoryNames: categoryNames,
          );

    _report(onProgress, phaseAnalyzingOrganization, current: 1, total: 1);
    return AiXpOrganizationPlanResult(
      plan: plan,
      galleriesByGid: Map<int, Gallery>.from(_galleryByGid),
      usedRemoteAi: true,
      remoteFallback: false,
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
        log.warning(
            'applyOrganizationMoves: invalid targetIndex=${move.targetIndex} gid=${move.gid}');
        continue;
      }
      if (!_galleryByGid.containsKey(move.gid)) {
        failure++;
        log.warning(
            'applyOrganizationMoves: missing cached gallery gid=${move.gid}');
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
        _report(onProgress, phaseApplyingOrganization,
            current: completed, total: total);
      },
      action: (AiXpOrganizationMove move) async {
        final Gallery gallery = _galleryByGid[move.gid]!;
        try {
          final GalleryNote galleryNote =
              await ehRequest.requestPopupPage<GalleryNote>(
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
    } catch (e) {
      log.warning('refresh favoriteSetting after organization failed', e, true);
    }

    if (success > 0) {
      await _persistCurrentFavoriteSnapshot();
    }
    await _rebuildAndSaveProfileFromCache(onProgress: onProgress);
    return AiXpApplyResult(successCount: success, failureCount: failure);
  }

  // ---------------------------------------------------------------------------
  // Enhanced search
  // ---------------------------------------------------------------------------

  /// Parse a natural-language query with remote AI into [SearchConfig].
  ///
  /// Top profile tags are injected only when the raw query explicitly asks for
  /// `my XP` / `我的XP` / `符合XP`.
  Future<AiXpEnhancedSearchResult> buildEnhancedSearch(
    String query, {
    AiXpProfile? profile,
    AiXpProgressCallback? onProgress,
  }) async {
    _requireRemoteAi();
    _report(onProgress, phaseInterpretingSearch, current: 0, total: 1);

    final String trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      throw ArgumentError.value(query, 'query', 'must not be empty');
    }
    final AiXpSearchIntent localHint = _engine.parseSearchIntent(trimmedQuery);
    final AiXpSearchIntent intent =
        await _remoteParseSearchIntent(trimmedQuery, localHint);

    final AiXpProfile? effectiveProfile =
        profile ?? _profile ?? await loadProfile();
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
      usedRemoteAi: true,
      remoteFallback: false,
      injectedXpTags:
          injectXp && (effectiveProfile?.tagWeights.isNotEmpty ?? false),
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
      final List<MapEntry<String, double>> sorted =
          profile.tagWeights.entries.toList()
            ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
              final int byWeight = b.value.compareTo(a.value);
              if (byWeight != 0) {
                return byWeight;
              }
              return a.key.compareTo(b.key);
            });
      final Set<String> existing =
          tags.map((TagData t) => '${t.namespace}:${t.key}').toSet();
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

  /// Ensure the shared favorite cache is loaded for the current owner.
  ///
  /// With [forceRefresh] false (default): single-flight; reuses in-memory cache,
  /// then a valid persisted [AiFavoriteSnapshot], and only then does a full server
  /// enumerate + enrich. With [forceRefresh] true: bypasses cached data and always
  /// re-scans the server. Concurrent callers await the same [Future]. Failures do
  /// not overwrite an older persisted snapshot. An empty successful snapshot is valid.
  Future<void> _ensureLiveFavorites({
    bool forceRefresh = false,
    AiXpProgressCallback? onProgress,
  }) {
    final Future<void>? inFlight = _ensureLiveFavoritesFuture;
    if (inFlight != null) {
      if (!forceRefresh) {
        return inFlight;
      }
      // Upgrade path: join the current flight, then force-refresh if it was not force.
      if (_ensureLiveFavoritesInFlightForce) {
        return inFlight;
      }
      return inFlight
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          )
          .then((_) =>
              _ensureLiveFavorites(forceRefresh: true, onProgress: onProgress));
    }

    _ensureLiveFavoritesInFlightForce = forceRefresh;
    final Future<void> started = _ensureLiveFavoritesImpl(
      forceRefresh: forceRefresh,
      onProgress: onProgress,
    );
    _ensureLiveFavoritesFuture = started;
    return started.whenComplete(() {
      if (identical(_ensureLiveFavoritesFuture, started)) {
        _ensureLiveFavoritesFuture = null;
        _ensureLiveFavoritesInFlightForce = false;
      }
    });
  }

  Future<void> _ensureLiveFavoritesImpl({
    required bool forceRefresh,
    AiXpProgressCallback? onProgress,
  }) async {
    final String ownerKey = _currentOwnerKey();

    // Never serve another account/site's in-memory rows.
    if (_favoriteCacheOwnerKey != null && _favoriteCacheOwnerKey != ownerKey) {
      _clearFavoriteCacheMemory();
    }

    if (!forceRefresh) {
      if (_hasValidMemoryFavoriteCache(ownerKey)) {
        _lastMetadataFailureCount = 0;
        return;
      }
      final bool hydrated =
          await _tryHydrateFavoriteCacheFromSnapshot(ownerKey);
      if (hydrated) {
        _lastMetadataFailureCount = 0;
        return;
      }
    }

    await _fullRefreshFavoriteCache(ownerKey: ownerKey, onProgress: onProgress);
  }

  /// Full server enumerate + enrich; replaces memory and persists on success only.
  Future<void> _fullRefreshFavoriteCache({
    required String ownerKey,
    AiXpProgressCallback? onProgress,
  }) async {
    final List<Gallery> favorites =
        await _enumerateAllServerFavorites(onProgress: onProgress);
    final ({
      List<Gallery> galleries,
      List<AiGallerySignal> signals,
      int failures
    }) enriched = await _enrichFavorites(favorites, onProgress: onProgress);
    if (enriched.failures > 0) {
      log.warning(
          'ensureLiveFavorites metadata failures: ${enriched.failures}');
    }
    _lastMetadataFailureCount = enriched.failures;

    final int capturedAtMs = DateTime.now().millisecondsSinceEpoch;
    // Empty [favorites] / [enriched] correctly wipes previous gallery and signal maps.
    _replaceFavoriteCache(
      enriched.galleries,
      enriched.signals,
      ownerKey: ownerKey,
      capturedAtMs: capturedAtMs,
    );

    // Persist only after a successful full refresh (including empty). Failures above
    // rethrow before this point and leave any older snapshot intact.
    await _persistFavoriteSnapshot(
      ownerKey: ownerKey,
      capturedAtMs: capturedAtMs,
      galleries: enriched.galleries,
      signals: enriched.signals,
    );
  }

  Future<List<Gallery>> _enumerateAllServerFavorites({
    AiXpProgressCallback? onProgress,
  }) async {
    final SearchConfig searchConfig =
        SearchConfig(searchType: SearchType.favorite);
    final List<Gallery> all = <Gallery>[];
    final Set<int> seenGids = <int>{};
    final Set<String> seenCursors = <String>{};
    String? nextGid;

    while (true) {
      if (nextGid != null && !seenCursors.add(nextGid)) {
        log.warning(
            'ai xp favorite enumerate stopped: repeated cursor $nextGid');
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

      for (final Gallery gallery in page.galleries) {
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

  Future<
      ({
        List<Gallery> galleries,
        List<AiGallerySignal> signals,
        int failures
      })> _enrichFavorites(
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
  Future<
      ({
        List<Gallery> galleries,
        List<AiGallerySignal> signals,
        int failures
      })> _enrichGalleries(
    List<Gallery> source, {
    AiXpProgressCallback? onProgress,
    required String progressPhase,
    required bool preserveFavoriteFields,
  }) async {
    if (source.isEmpty) {
      return (
        galleries: <Gallery>[],
        signals: <AiGallerySignal>[],
        failures: 0
      );
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
        final List<GalleryMetadata> metadatas =
            await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
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

        final Gallery merged = _mergeGallery(original, meta,
            preserveFavoriteFields: preserveFavoriteFields);
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
          : (meta.publishTime.isNotEmpty
              ? meta.publishTime
              : original.publishTime),
      isExpunged: meta.isExpunged,
      tags: meta.tags.isNotEmpty ? meta.tags : original.tags,
      favoriteTagIndex: preserveFavoriteFields
          ? original.favoriteTagIndex
          : original.favoriteTagIndex,
      favoriteTagName: preserveFavoriteFields
          ? original.favoriteTagName
          : original.favoriteTagName,
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
    final int? metaPostedMs =
        meta != null ? _parseTimeMs(meta.publishTime) : null;

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
      favoriteCategoryIndex: preserveFavoriteFields
          ? original.favoriteTagIndex
          : merged.favoriteTagIndex,
      favoriteCategoryName: preserveFavoriteFields
          ? original.favoriteTagName
          : merged.favoriteTagName,
      favoritedAtMs: preserveFavoriteFields ? listTimeMs : null,
      publishedAtMs:
          metaPostedMs ?? (preserveFavoriteFields ? null : listTimeMs),
    );
  }

  List<String> _tagsToSignals(LinkedHashMap<String, List<GalleryTag>> tags) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    tags.forEach((String namespace, List<GalleryTag> list) {
      for (final GalleryTag tag in list) {
        final String ns = tag.tagData.namespace.isNotEmpty
            ? tag.tagData.namespace
            : namespace;
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

    for (final AiXpSearchStrategy strategy in profile.searchStrategies) {
      if (searches.length >= _maxRecommendationSearches) {
        break;
      }
      final List<TagData> tags = _validatedRemoteTags(
        strategy.tags,
        limit: _maxRemoteStrategyTags,
      ).map(_tagDataFromSignal).whereType<TagData>().toList();
      final String keyword = _truncate(strategy.keyword.trim(), 120);
      if (tags.isEmpty && keyword.isEmpty) {
        continue;
      }
      final String key =
          '${tags.map((TagData tag) => '${tag.namespace}:${tag.key}').join('+')}|$keyword';
      if (!usedKeys.add(key)) {
        continue;
      }
      searches.add(SearchConfig(
        searchType: SearchType.gallery,
        tags: tags.isEmpty ? null : tags,
        keyword: keyword.isEmpty ? null : keyword,
        hideFavoritedGalleries: true,
      ));
    }

    return searches;
  }

  // ---------------------------------------------------------------------------
  // Internal: remote AI helpers
  // ---------------------------------------------------------------------------

  Future<AiXpProfile> _remoteBuildProfile(
      AiXpProfile statisticalProfile) async {
    final List<AiGallerySignal> representatives =
        List<AiGallerySignal>.from(_favoriteSignals)
          ..sort((AiGallerySignal a, AiGallerySignal b) {
            final int byTime = (b.recencyMs ?? -1).compareTo(a.recencyMs ?? -1);
            return byTime != 0 ? byTime : a.gid.compareTo(b.gid);
          });

    final Map<String, dynamic> payload = <String, dynamic>{
      'locale': Intl.getCurrentLocale(),
      'favoriteCount': _favoriteSignals.length,
      'categoryCounts': _countSignalValues(
          _favoriteSignals.map((AiGallerySignal s) => s.category)),
      'languageCounts': _countSignalValues(
          _favoriteSignals.map((AiGallerySignal s) => s.language ?? '')),
      'topTags': _weightedPayload(statisticalProfile.tagWeights, 80, 'tag'),
      'topTitleTerms':
          _weightedPayload(statisticalProfile.titleWeights, 40, 'term'),
      'topTagPairs': statisticalProfile.tagPairs.take(30).map((AiXpTagPair p) {
        return <String, dynamic>{
          'left': p.left,
          'right': p.right,
          'weight': p.weight,
          'count': p.count,
        };
      }).toList(),
      'representativeFavorites': representatives
          .take(_maxProfileRepresentativeFavorites)
          .map((AiGallerySignal s) {
        return <String, dynamic>{
          'title': _truncate(s.title, 240),
          'category': s.category,
          'tags': s.tags.take(12).toList(),
          'language': s.language,
          'rating': s.rating,
        };
      }).toList(),
    };

    final Map<String, dynamic> response = await aiRequest.requestJson(
      systemPrompt: _profileSystemPrompt,
      userPrompt: jsonEncode(payload),
    );
    final String summary = _boundedResponseString(response['summary'], 1200);

    final List<AiXpPreference> preferences = <AiXpPreference>[];
    final Object? rawPreferences = response['preferences'];
    if (rawPreferences is List) {
      for (final Object? item in rawPreferences) {
        if (preferences.length >= _maxRemotePreferences || item is! Map) {
          continue;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(item);
        final String name = _boundedResponseString(map['name'], 80);
        final String description =
            _boundedResponseString(map['description'], 500);
        final double? confidence = (map['confidence'] as num?)?.toDouble();
        if (name.isEmpty ||
            description.isEmpty ||
            confidence == null ||
            !confidence.isFinite ||
            confidence < 0 ||
            confidence > 1) {
          continue;
        }
        final List<String> evidenceTags = _validatedRemoteTags(
          map['evidenceTags'],
          limit: _maxRemoteEvidenceTags,
        );
        preferences.add(AiXpPreference(
          name: name,
          description: description,
          confidence: confidence,
          evidenceTags: evidenceTags,
        ));
      }
    }

    final List<AiXpSearchStrategy> strategies = <AiXpSearchStrategy>[];
    final Object? rawStrategies = response['searchStrategies'];
    if (rawStrategies is List) {
      for (final Object? item in rawStrategies) {
        if (strategies.length >= _maxRecommendationSearches || item is! Map) {
          continue;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(item);
        final List<String> tags = _validatedRemoteTags(
          map['tags'],
          limit: _maxRemoteStrategyTags,
        );
        final String keyword = _boundedResponseString(map['keyword'], 120);
        final String reason = _boundedResponseString(map['reason'], 500);
        final AiXpSearchStrategy strategy = AiXpSearchStrategy(
          tags: tags,
          keyword: keyword,
          reason: reason,
        );
        if (_isUsableSearchStrategy(strategy)) {
          strategies.add(strategy);
        }
      }
    }

    if (summary.isEmpty || preferences.isEmpty || strategies.isEmpty) {
      throw const FormatException(
        'AI profile response requires summary, preferences, and searchStrategies',
      );
    }

    return statisticalProfile.copyWith(
      version: AiXpProfile.currentVersion,
      summary: summary,
      preferences: preferences,
      searchStrategies: strategies,
      generatedByRemoteAi: true,
    );
  }

  Future<List<AiXpRankedCandidate>> _remoteRankCandidates({
    required AiXpProfile profile,
    required List<AiGallerySignal> candidates,
  }) async {
    if (candidates.isEmpty) {
      return const <AiXpRankedCandidate>[];
    }

    final Map<int, AiGallerySignal> allowed = <int, AiGallerySignal>{
      for (final AiGallerySignal signal in candidates) signal.gid: signal,
    };
    final Map<String, dynamic> response = await aiRequest.requestJson(
      systemPrompt: _recommendationSystemPrompt,
      userPrompt: jsonEncode(<String, dynamic>{
        'locale': Intl.getCurrentLocale(),
        'profile': <String, dynamic>{
          'summary': profile.summary,
          'preferences': profile.preferences
              .map((AiXpPreference preference) => preference.toJson())
              .toList(),
          'searchStrategies': profile.searchStrategies
              .map((AiXpSearchStrategy strategy) => strategy.toJson())
              .toList(),
        },
        'candidates': candidates.map((AiGallerySignal signal) {
          return <String, dynamic>{
            'gid': signal.gid,
            'title': _truncate(signal.title, 240),
            'category': signal.category,
            'tags': signal.tags.take(20).toList(),
            'rating': signal.rating,
            'pageCount': signal.pageCount,
            'language': signal.language,
            'uploader': _truncate(signal.uploader ?? '', 100),
          };
        }).toList(),
      }),
    );

    final Object? rawRecommendations = response['recommendations'];
    if (rawRecommendations is! List) {
      throw const FormatException(
          'AI recommendation response is missing recommendations[]');
    }

    final List<AiXpRankedCandidate> ranked = <AiXpRankedCandidate>[];
    final Set<int> seen = <int>{};
    for (final Object? item in rawRecommendations) {
      if (ranked.length >= _maxRecommendations || item is! Map) {
        continue;
      }
      final Map<String, dynamic> map = Map<String, dynamic>.from(item);
      final int? gid = (map['gid'] as num?)?.toInt();
      final double? score = (map['score'] as num?)?.toDouble();
      final String reason = _boundedResponseString(map['reason'], 500);
      if (gid == null ||
          score == null ||
          score < 0 ||
          score > 100 ||
          reason.isEmpty ||
          !seen.add(gid)) {
        continue;
      }
      final AiGallerySignal? signal = allowed[gid];
      if (signal == null) {
        continue;
      }
      ranked.add(AiXpRankedCandidate(
        signal: signal,
        score: score,
        explanations: <AiXpScoreExplanation>[
          AiXpScoreExplanation(
            kind: 'remote_ai',
            detail: reason,
            contribution: score,
          ),
        ],
      ));
    }
    if (rawRecommendations.isNotEmpty && ranked.isEmpty) {
      throw const FormatException(
          'AI recommendation response contains no valid candidates');
    }
    return ranked;
  }

  Future<AiXpOrganizationPlan> _remoteOrganizeFavorites({
    required String requirements,
    required List<String> categoryNames,
  }) async {
    final List<AiXpOrganizationMove> allMoves = <AiXpOrganizationMove>[];
    final Set<int> moved = <int>{};
    final List<List<AiGallerySignal>> chunks =
        chunkList(_favoriteSignals, _orgRemoteChunkSize);

    for (final List<AiGallerySignal> chunk in chunks) {
      final Set<int> chunkGids =
          chunk.map((AiGallerySignal signal) => signal.gid).toSet();
      final Map<String, dynamic> userPayload = <String, dynamic>{
        'requirements': requirements,
        'categories': <Map<String, dynamic>>[
          for (int i = 0; i < categoryNames.length; i++)
            <String, dynamic>{'index': i, 'name': categoryNames[i]},
        ],
        'favorites': chunk.map((AiGallerySignal s) {
          return <String, dynamic>{
            'gid': s.gid,
            'title': _truncate(s.title, 240),
            'category': s.category,
            'tags': s.tags.take(12).toList(),
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
        throw const FormatException(
            'AI organization response is missing moves[]');
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
        if (!chunkGids.contains(gid) || moved.contains(gid)) {
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
          matchedRule:
              map['matchedRule'] as String? ?? map['rule'] as String? ?? '',
          matchedTerm:
              map['matchedTerm'] as String? ?? map['term'] as String? ?? '',
        ));
      }
    }

    // Keep local rule parse for UI display even when moves come from remote.
    final List<AiXpOrganizationRule> rules =
        _engine.parseOrganizationRules(requirements, categoryNames);
    return AiXpOrganizationPlan(rules: rules, moves: allMoves);
  }

  Future<AiXpSearchIntent> _remoteParseSearchIntent(
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

    final Object? rawCategories = response['categories'];
    final Object? rawTags = response['tags'];
    final Object? rawResidual = response['residualKeyword'];
    if (rawCategories is! List || rawTags is! List || rawResidual is! String) {
      throw const FormatException(
        'AI search response requires categories[], tags[], and residualKeyword',
      );
    }

    final String responseQuery =
        _boundedResponseString(response['rawQuery'], 500);
    final String rawQuery = responseQuery.isEmpty ? query : responseQuery;
    final String? language = response['language'] is String
        ? _boundedResponseString(response['language'], 40)
        : null;
    final bool? requireTorrent = response['requireTorrent'] as bool?;
    final int? minimumRating = (response['minimumRating'] as num?)?.toInt();
    final int? pageAtLeast = (response['pageAtLeast'] as num?)?.toInt();
    final int? pageAtMost = (response['pageAtMost'] as num?)?.toInt();
    if ((minimumRating != null && (minimumRating < 1 || minimumRating > 5)) ||
        (pageAtLeast != null && pageAtLeast < 1) ||
        (pageAtMost != null && pageAtMost < 1) ||
        (pageAtLeast != null &&
            pageAtMost != null &&
            pageAtMost < pageAtLeast)) {
      throw const FormatException('AI search response contains invalid bounds');
    }

    final List<String> categories = <String>[];
    final Set<String> seenCategories = <String>{};
    for (final Object? c in rawCategories) {
      final String name = c.toString();
      if (_isKnownCategory(name)) {
        final String canonical = _canonicalCategory(name);
        if (seenCategories.add(canonical)) {
          categories.add(canonical);
        }
      }
    }

    final List<String> tags = _validatedRemoteTags(rawTags, limit: 20);

    return AiXpSearchIntent(
      rawQuery: rawQuery,
      language: language?.isEmpty == true ? null : language,
      requireTorrent: requireTorrent,
      minimumRating: minimumRating,
      pageAtLeast: pageAtLeast,
      pageAtMost: pageAtMost,
      categories: categories,
      tags: tags,
      xpPreference: response['xpPreference'] is String
          ? _boundedResponseString(response['xpPreference'], 300)
          : null,
      residualKeyword: _truncate(rawResidual.trim(), 300),
    );
  }

  static const String _profileSystemPrompt =
      'You analyze compact statistics derived from an E-Hentai favorites library. '
      'Write all human-facing text in the requested locale. Reply with one JSON object only. '
      'Schema: {"summary":"<clear overview>","preferences":[{"name":"<theme>",'
      '"description":"<what the evidence suggests>","confidence":<0..1>,'
      '"evidenceTags":["namespace:key"]}],"searchStrategies":[{"tags":'
      '["namespace:key"],"keyword":"<optional keyword>","reason":"<why this search fits>"}]}. '
      'Return at least one preference and one usable search strategy. Do not diagnose the user, '
      'invent private facts, request secrets, or echo raw payloads.';

  static const String _recommendationSystemPrompt =
      'You rank E-Hentai gallery candidates for the supplied preference profile. '
      'Reply with one JSON object only, using only candidate gids. Schema: '
      '{"recommendations":[{"gid":<int>,"score":<number 0..100>,'
      '"reason":"<concise reason in requested locale>"}]}. Return at most 30 unique items '
      'in best-first order. Base the decision on the profile and candidate metadata; do not '
      'request or invent tokens, covers, credentials, or gids.';

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
      'Always include categories, tags, and residualKeyword even when empty. Categories must be EH names. '
      'Tags must be namespace:key. The localHint is only parsing evidence; your JSON is the final result. '
      'Never include tokens, covers, or secrets.';

  // ---------------------------------------------------------------------------
  // Internal: cache / snapshot / profile rebuild
  // ---------------------------------------------------------------------------

  /// Account/site-scoped owner key: `site:memberId`.
  String _currentOwnerKey() {
    final String site = ehSetting.site.value;
    final int memberId = userSetting.ipbMemberId.value ?? 0;
    return '$site:$memberId';
  }

  bool _hasValidMemoryFavoriteCache(String ownerKey) {
    return _favoriteCacheLoaded && _favoriteCacheOwnerKey == ownerKey;
  }

  void _clearFavoriteCacheMemory() {
    _favoriteGalleries.clear();
    _favoriteSignals.clear();
    _galleryByGid.clear();
    _signalByGid.clear();
    _favoriteCacheLoaded = false;
    _favoriteCacheOwnerKey = null;
    _favoriteCacheCapturedAtMs = null;
    _lastMetadataFailureCount = 0;
  }

  void _replaceFavoriteCache(
    List<Gallery> galleries,
    List<AiGallerySignal> signals, {
    required String ownerKey,
    required int capturedAtMs,
  }) {
    _favoriteGalleries
      ..clear()
      ..addAll(galleries);
    _favoriteSignals
      ..clear()
      ..addAll(signals);
    _galleryByGid
      ..clear()
      ..addEntries(
          galleries.map((Gallery g) => MapEntry<int, Gallery>(g.gid, g)));
    _signalByGid
      ..clear()
      ..addEntries(signals.map(
          (AiGallerySignal s) => MapEntry<int, AiGallerySignal>(s.gid, s)));
    _favoriteCacheLoaded = true;
    _favoriteCacheOwnerKey = ownerKey;
    _favoriteCacheCapturedAtMs = capturedAtMs;
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
      final int index =
          _favoriteGalleries.indexWhere((Gallery g) => g.gid == gid);
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
      final int index =
          _favoriteSignals.indexWhere((AiGallerySignal s) => s.gid == gid);
      if (index >= 0) {
        _favoriteSignals[index] = updated;
      }
    }
  }

  /// Try to load a valid owner-scoped snapshot into memory.
  ///
  /// Returns true when a matching valid snapshot (including empty) was applied.
  /// Corrupted, version-mismatched, or owner-mismatched data is ignored with logging.
  Future<bool> _tryHydrateFavoriteCacheFromSnapshot(String ownerKey) async {
    if (_hasValidMemoryFavoriteCache(ownerKey)) {
      return true;
    }

    try {
      final String? raw = await localConfigService.read(
        configKey: ConfigEnum.aiFavoriteSnapshot,
        subConfigKey: ownerKey,
      );
      if (raw == null || raw.isEmpty) {
        return false;
      }

      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        log.warning(
            'aiFavoriteSnapshot config is not a JSON object (owner=$ownerKey)');
        return false;
      }

      final AiFavoriteSnapshot snapshot =
          AiFavoriteSnapshot.fromJson(Map<String, dynamic>.from(decoded));

      if (snapshot.version != AiFavoriteSnapshot.currentVersion) {
        log.warning(
          'aiFavoriteSnapshot version mismatch: got ${snapshot.version}, '
          'want ${AiFavoriteSnapshot.currentVersion} (owner=$ownerKey)',
        );
        return false;
      }
      if (snapshot.ownerKey != ownerKey) {
        log.warning(
          'aiFavoriteSnapshot owner mismatch: got ${snapshot.ownerKey}, want $ownerKey',
        );
        return false;
      }

      final List<Gallery> galleries = <Gallery>[];
      final List<AiGallerySignal> signals = <AiGallerySignal>[];
      for (final AiFavoriteSnapshotEntry entry in snapshot.entries) {
        galleries.add(entry.toGallery());
        signals.add(entry.signal);
      }

      _replaceFavoriteCache(
        galleries,
        signals,
        ownerKey: ownerKey,
        capturedAtMs: snapshot.capturedAtMs,
      );
      return true;
    } catch (e, s) {
      log.error('load aiFavoriteSnapshot failed (owner=$ownerKey)', e, s);
      return false;
    }
  }

  /// Persist the current in-memory favorite cache as an owner-scoped snapshot.
  Future<void> _persistCurrentFavoriteSnapshot() async {
    if (!_favoriteCacheLoaded) {
      return;
    }
    final String ownerKey = _favoriteCacheOwnerKey ?? _currentOwnerKey();
    final int capturedAtMs =
        _favoriteCacheCapturedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await _persistFavoriteSnapshot(
      ownerKey: ownerKey,
      capturedAtMs: capturedAtMs,
      galleries: _favoriteGalleries,
      signals: _favoriteSignals,
    );
    // Keep capturedAtMs stable for in-place mutations; only full refresh bumps it.
  }

  /// Build and write snapshot by joining each [Gallery] identity with its enriched signal.
  ///
  /// Retains torrent/times/tags from [signals]. Does not store cookies/password/API keys.
  Future<void> _persistFavoriteSnapshot({
    required String ownerKey,
    required int capturedAtMs,
    required List<Gallery> galleries,
    required List<AiGallerySignal> signals,
  }) async {
    try {
      final Map<int, AiGallerySignal> signalByGid = <int, AiGallerySignal>{
        for (final AiGallerySignal s in signals) s.gid: s,
      };
      final List<AiFavoriteSnapshotEntry> entries = <AiFavoriteSnapshotEntry>[];
      for (final Gallery gallery in galleries) {
        final AiGallerySignal? signal = signalByGid[gallery.gid];
        if (signal == null) {
          // Fall back to gallery-derived signal so identity is still recoverable.
          entries.add(AiFavoriteSnapshotEntry.fromGallery(gallery));
          continue;
        }
        entries.add(AiFavoriteSnapshotEntry(
          signal: signal,
          token: gallery.token,
          isEH: gallery.galleryUrl.isEH,
        ));
      }

      final AiFavoriteSnapshot snapshot = AiFavoriteSnapshot(
        version: AiFavoriteSnapshot.currentVersion,
        ownerKey: ownerKey,
        capturedAtMs: capturedAtMs,
        entries: entries,
      );

      await localConfigService.write(
        configKey: ConfigEnum.aiFavoriteSnapshot,
        subConfigKey: ownerKey,
        value: jsonEncode(snapshot.toJson()),
      );
    } catch (e, s) {
      // Persistence failure must not wipe an older on-disk snapshot already written.
      log.error('persist aiFavoriteSnapshot failed (owner=$ownerKey)', e, s);
    }
  }

  Future<void> _rebuildAndSaveProfileFromCache(
      {AiXpProgressCallback? onProgress}) async {
    _report(onProgress, phaseBuildingProfile, current: 0, total: 1);
    final AiXpProfile statisticalProfile =
        _engine.buildProfile(_favoriteSignals);
    final AiXpProfile? previous = _profile;
    final AiXpProfile profile =
        previous == null || !previous.generatedByRemoteAi
            ? statisticalProfile
            : statisticalProfile.copyWith(
                summary: previous.summary,
                preferences: previous.preferences,
                searchStrategies: previous.searchStrategies,
                generatedByRemoteAi: true,
              );
    await saveProfile(profile);
    _report(onProgress, phaseBuildingProfile, current: 1, total: 1);
  }

  // ---------------------------------------------------------------------------
  // Internal: helpers
  // ---------------------------------------------------------------------------

  void _requireRemoteAi() {
    if (!aiSetting.isReady) {
      throw StateError('AI API is not configured');
    }
  }

  static Map<String, int> _countSignalValues(Iterable<String> values) {
    final Map<String, int> counts = <String, int>{};
    for (final String raw in values) {
      final String value = raw.trim();
      if (value.isNotEmpty) {
        counts[value] = (counts[value] ?? 0) + 1;
      }
    }
    final List<MapEntry<String, int>> ordered = counts.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
        final int byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return <String, int>{
      for (final MapEntry<String, int> e in ordered) e.key: e.value
    };
  }

  static List<Map<String, dynamic>> _weightedPayload(
    Map<String, double> weights,
    int limit,
    String nameKey,
  ) {
    final List<MapEntry<String, double>> entries = weights.entries
        .where((MapEntry<String, double> entry) => entry.value.isFinite)
        .toList()
      ..sort((MapEntry<String, double> a, MapEntry<String, double> b) {
        final int byWeight = b.value.compareTo(a.value);
        return byWeight != 0 ? byWeight : a.key.compareTo(b.key);
      });
    return entries.take(limit).map((MapEntry<String, double> entry) {
      return <String, dynamic>{nameKey: entry.key, 'weight': entry.value};
    }).toList();
  }

  static List<String> _validatedRemoteTags(Object? raw, {required int limit}) {
    if (raw is! List) {
      return const <String>[];
    }
    final List<String> tags = <String>[];
    final Set<String> seen = <String>{};
    for (final Object? item in raw) {
      final String normalized = AiXpEngine.normalizeTag(item.toString());
      final int separator = normalized.indexOf(':');
      if (separator <= 0 ||
          separator >= normalized.length - 1 ||
          !seen.add(normalized)) {
        continue;
      }
      tags.add(normalized);
      if (tags.length >= limit) {
        break;
      }
    }
    return tags;
  }

  static bool _isUsableSearchStrategy(AiXpSearchStrategy strategy) {
    return strategy.keyword.trim().isNotEmpty ||
        _validatedRemoteTags(strategy.tags, limit: _maxRemoteStrategyTags)
            .isNotEmpty;
  }

  static String _boundedResponseString(Object? value, int maxLength) {
    if (value is! String) {
      return '';
    }
    return _truncate(value.trim(), maxLength);
  }

  static String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength);
  }

  void _report(AiXpProgressCallback? onProgress, String phase,
      {int current = 0, int total = 0}) {
    onProgress
        ?.call(AiXpProgress(phase: phase, current: current, total: total));
  }

  static bool _queryRequestsXpInjection(String query) {
    final String lower = query.toLowerCase();
    return lower.contains('my xp') ||
        lower.contains('我的xp') ||
        lower.contains('符合xp');
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
      return DateFormat('yyyy-MM-dd HH:mm:ss')
          .parse(text)
          .millisecondsSinceEpoch;
    } catch (_) {}
    return null;
  }

  static void _applyCategoryFilters(
      SearchConfig config, List<String> categories) {
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
