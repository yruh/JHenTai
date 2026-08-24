import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
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
import 'package:jhentai/src/network/ai_xp_remote.dart';
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
import 'package:jhentai/src/utils/favorite_enumerate_util.dart';

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

  /// Candidates handed to the remote ranker after local pre-filtering.
  static const int _maxRemoteRankingCandidates = 80;
  static const int _maxRemoteStrategyTags = 4;
  static const int _maxXpInjectTags = 5;

  /// Safety cap on favorite list pages walked in one scan.
  ///
  /// EH serves ~50 favorites per page, so this covers a ~10k-item library.
  /// Each page also drives gdata enrichment, so an uncapped walk on a corrupt
  /// or endlessly-paginating response would issue thousands of requests.
  static const int _maxFavoritePages = 200;

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
  final AiXpRemote _remote;

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

  AiXpService({
    AiXpEngine engine = const AiXpEngine(),
    AiXpRemote remote = const AiXpRemote(),
  })  : _engine = engine,
        _remote = remote;

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
        : await _remote.buildProfile(
            statisticalProfile: statisticalProfile,
            signals: _favoriteSignals,
          );
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
        !effective.searchStrategies.any(AiXpRemote.isUsableSearchStrategy)) {
      final AiXpProfile statisticalProfile =
          _engine.buildProfile(_favoriteSignals);
      if (statisticalProfile.isEmpty) {
        return const <AiXpRecommendation>[];
      }
      _report(onProgress, phaseBuildingProfile, current: 0, total: 1);
      effective = await _remote.buildProfile(
        statisticalProfile: statisticalProfile,
        signals: _favoriteSignals,
      );
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

    final List<AiXpRankedCandidate> ranked = await _remote.rankCandidates(
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
    final Set<int> removedGids = <int>{};
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
          removedGids.add(gallery.gid);
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

    _removeFromCache(removedGids);

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
    // No favorites means no remote call was made, so do not claim one.
    final bool calledRemoteAi = _favoriteSignals.isNotEmpty;
    final List<AiXpOrganizationMove> moves = calledRemoteAi
        ? await _remote.organizeFavorites(
            requirements: requirements,
            categoryNames: categoryNames,
            signals: _favoriteSignals,
            signalByGid: _signalByGid,
          )
        : const <AiXpOrganizationMove>[];

    // Rules are parsed locally purely so the preview dialog can show what the
    // user's free-form requirements were understood to mean; the moves
    // themselves come from the model.
    final List<AiXpOrganizationRule> rules = calledRemoteAi
        ? _engine.parseOrganizationRules(requirements, categoryNames)
        : const <AiXpOrganizationRule>[];

    _report(onProgress, phaseAnalyzingOrganization, current: 1, total: 1);
    return AiXpOrganizationPlanResult(
      plan: AiXpOrganizationPlan(rules: rules, moves: moves),
      galleriesByGid: Map<int, Gallery>.from(_galleryByGid),
      usedRemoteAi: calledRemoteAi,
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
    final Map<int, ({int index, String name})> applied =
        <int, ({int index, String name})>{};
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
          applied[move.gid] =
              (index: move.targetIndex, name: move.targetName);
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

    _applyFavoriteCategoryUpdates(applied);

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
        await _remote.parseSearchIntent(query: trimmedQuery, localHint: localHint);

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
  }) {
    return enumerateAllServerFavorites(
      maxPages: _maxFavoritePages,
      onPageLoaded: (int loadedCount) {
        _report(onProgress, phaseLoadingFavorites, current: loadedCount, total: 0);
      },
    );
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
      // Tracked explicitly rather than inferred from an empty [byGid]: a request
      // that succeeds but returns no rows is still one failure per item, and
      // must not be silently counted as zero failures.
      bool chunkRequestFailed = false;
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
        chunkRequestFailed = true;
        failures += chunk.length;
        log.error('ai xp gdata chunk failed', e.errorMsg);
        byGid = <int, GalleryMetadata>{};
      } on EHSiteException catch (e) {
        chunkRequestFailed = true;
        failures += chunk.length;
        log.error('ai xp gdata chunk failed', e.message);
        byGid = <int, GalleryMetadata>{};
      } catch (e, s) {
        chunkRequestFailed = true;
        failures += chunk.length;
        log.error('ai xp gdata chunk failed', e, s);
        byGid = <int, GalleryMetadata>{};
      }

      for (final Gallery original in chunk) {
        final GalleryMetadata? meta = byGid[original.gid];
        // Whole-chunk errors are already counted above; count per-item misses
        // only for chunks whose request actually returned.
        if (meta == null && !chunkRequestFailed) {
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
      // Keep original galleryUrl (gid/token) and favorite category always:
      // gdata does not report which favorite slot a gallery sits in.
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
      if (searches.length >= AiXpRemote.maxSearchStrategies) {
        break;
      }
      final List<TagData> tags = AiXpRemote.validatedTags(
        strategy.tags,
        limit: _maxRemoteStrategyTags,
      ).map(_tagDataFromSignal).whereType<TagData>().toList();
      final String keyword = AiXpRemote.truncate(strategy.keyword.trim(), 120);
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

  /// Remove [gids] from the shared cache in a single pass.
  ///
  /// Batched rather than per-gid: `removeWhere`/`indexWhere` scan the whole
  /// list, so removing k of n favorites one at a time is O(k*n).
  void _removeFromCache(Set<int> gids) {
    if (gids.isEmpty) {
      return;
    }
    _favoriteGalleries.removeWhere((Gallery g) => gids.contains(g.gid));
    _favoriteSignals.removeWhere((AiGallerySignal s) => gids.contains(s.gid));
    for (final int gid in gids) {
      _galleryByGid.remove(gid);
      _signalByGid.remove(gid);
    }
  }

  /// Apply favorite-category reassignments to the shared cache in a single pass.
  void _applyFavoriteCategoryUpdates(
    Map<int, ({int index, String name})> updates,
  ) {
    if (updates.isEmpty) {
      return;
    }

    for (final MapEntry<int, ({int index, String name})> entry
        in updates.entries) {
      final Gallery? gallery = _galleryByGid[entry.key];
      if (gallery != null) {
        _galleryByGid[entry.key] = gallery.copyWith(
          favoriteTagIndex: entry.value.index,
          favoriteTagName: entry.value.name,
        );
      }
      final AiGallerySignal? signal = _signalByGid[entry.key];
      if (signal != null) {
        _signalByGid[entry.key] = signal.copyWithFavoriteCategory(
          index: entry.value.index,
          name: entry.value.name,
        );
      }
    }

    // Mirror the map updates into the ordered lists with one scan each.
    for (int i = 0; i < _favoriteGalleries.length; i++) {
      final Gallery? updated = _galleryByGid[_favoriteGalleries[i].gid];
      if (updated != null) {
        _favoriteGalleries[i] = updated;
      }
    }
    for (int i = 0; i < _favoriteSignals.length; i++) {
      final AiGallerySignal? updated = _signalByGid[_favoriteSignals[i].gid];
      if (updated != null) {
        _favoriteSignals[i] = updated;
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
      switch (AiXpEngine.canonicalCategory(raw)) {
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
}
