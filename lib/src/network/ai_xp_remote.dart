import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/network/ai_request.dart';
import 'package:jhentai/src/utils/ai_xp_engine.dart';
import 'package:jhentai/src/utils/favorite_dedupe_util.dart';

/// Remote-AI prompt construction and response validation for the AI XP feature.
///
/// Split out of `AiXpService` so the service owns orchestration (favorite cache,
/// EH requests, persistence) while this layer owns the model contract: the four
/// system prompts, the JSON schemas they promise, and the validation that keeps
/// a hallucinated response from reaching the UI or the EH API.
///
/// Every method throws [FormatException] when the model returns something the
/// schema does not allow, rather than silently degrading — callers surface that
/// as an operation failure. Payloads deliberately exclude cover URLs, gallery
/// tokens, cookies, and API keys.
class AiXpRemote {
  const AiXpRemote();

  /// Max search strategies requested from the profile call, and the cap on how
  /// many recommendation searches the service will run from them.
  static const int maxSearchStrategies = 6;

  /// Max ranked recommendations accepted from one ranking response.
  static const int maxRecommendations = 30;

  static const int _maxRemotePreferences = 10;
  static const int _maxRemoteEvidenceTags = 12;
  static const int _maxRemoteStrategyTags = 4;
  static const int _maxProfileRepresentativeFavorites = 60;
  static const int _orgRemoteChunkSize = 50;

  Future<AiXpProfile> buildProfile({
    required AiXpProfile statisticalProfile,
    required List<AiGallerySignal> signals,
  }) async {
    final List<AiGallerySignal> representatives =
        List<AiGallerySignal>.from(signals)
          ..sort((AiGallerySignal a, AiGallerySignal b) {
            final int byTime = (b.recencyMs ?? -1).compareTo(a.recencyMs ?? -1);
            return byTime != 0 ? byTime : a.gid.compareTo(b.gid);
          });

    final Map<String, dynamic> payload = <String, dynamic>{
      'locale': Intl.getCurrentLocale(),
      'favoriteCount': signals.length,
      'categoryCounts': _countSignalValues(
          signals.map((AiGallerySignal s) => s.category)),
      'languageCounts': _countSignalValues(
          signals.map((AiGallerySignal s) => s.language ?? '')),
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
          'title': truncate(s.title, 240),
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
    final String summary = boundedString(response['summary'], 1200);

    final List<AiXpPreference> preferences = <AiXpPreference>[];
    final Object? rawPreferences = response['preferences'];
    if (rawPreferences is List) {
      for (final Object? item in rawPreferences) {
        if (preferences.length >= _maxRemotePreferences || item is! Map) {
          continue;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(item);
        final String name = boundedString(map['name'], 80);
        final String description =
            boundedString(map['description'], 500);
        final double? confidence = (map['confidence'] as num?)?.toDouble();
        if (name.isEmpty ||
            description.isEmpty ||
            confidence == null ||
            !confidence.isFinite ||
            confidence < 0 ||
            confidence > 1) {
          continue;
        }
        final List<String> evidenceTags = validatedTags(
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
        if (strategies.length >= maxSearchStrategies || item is! Map) {
          continue;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(item);
        final List<String> tags = validatedTags(
          map['tags'],
          limit: _maxRemoteStrategyTags,
        );
        final String keyword = boundedString(map['keyword'], 120);
        final String reason = boundedString(map['reason'], 500);
        final AiXpSearchStrategy strategy = AiXpSearchStrategy(
          tags: tags,
          keyword: keyword,
          reason: reason,
        );
        if (isUsableSearchStrategy(strategy)) {
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

  Future<List<AiXpRankedCandidate>> rankCandidates({
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
            'title': truncate(signal.title, 240),
            'category': signal.category,
            'tags': signal.tags.take(20).toList(),
            'rating': signal.rating,
            'pageCount': signal.pageCount,
            'language': signal.language,
            'uploader': truncate(signal.uploader ?? '', 100),
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
      if (ranked.length >= maxRecommendations || item is! Map) {
        continue;
      }
      final Map<String, dynamic> map = Map<String, dynamic>.from(item);
      final int? gid = (map['gid'] as num?)?.toInt();
      final double? score = (map['score'] as num?)?.toDouble();
      final String reason = boundedString(map['reason'], 500);
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

  Future<List<AiXpOrganizationMove>> organizeFavorites({
    required String requirements,
    required List<String> categoryNames,
    required List<AiGallerySignal> signals,
    required Map<int, AiGallerySignal> signalByGid,
  }) async {
    final List<AiXpOrganizationMove> allMoves = <AiXpOrganizationMove>[];
    final Set<int> moved = <int>{};
    final List<List<AiGallerySignal>> chunks =
        chunkList(signals, _orgRemoteChunkSize);

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
            'title': truncate(s.title, 240),
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
        final AiGallerySignal? signal = signalByGid[gid];
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

    return allMoves;
  }

  Future<AiXpSearchIntent> parseSearchIntent({
    required String query,
    required AiXpSearchIntent localHint,
  }) async {
    final Map<String, dynamic> response = await aiRequest.requestJson(
      systemPrompt: _searchSystemPrompt,
      userPrompt: jsonEncode(<String, dynamic>{
        'query': query,
        'localHint': localHint.toJson(),
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
        boundedString(response['rawQuery'], 500);
    final String rawQuery = responseQuery.isEmpty ? query : responseQuery;
    final String? language = response['language'] is String
        ? boundedString(response['language'], 40)
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
      final String? canonical = AiXpEngine.canonicalCategory(name);
      if (canonical != null && seenCategories.add(canonical)) {
        categories.add(canonical);
      }
    }

    final List<String> tags = validatedTags(rawTags, limit: 20);

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
          ? boundedString(response['xpPreference'], 300)
          : null,
      residualKeyword: truncate(rawResidual.trim(), 300),
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

  /// Normalize `namespace:key` tags from a model response, dropping bare keys,
  /// duplicates, and anything past [limit].
  static List<String> validatedTags(Object? raw, {required int limit}) {
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

  /// True when a strategy carries something searchable (keyword or valid tag).
  static bool isUsableSearchStrategy(AiXpSearchStrategy strategy) {
    return strategy.keyword.trim().isNotEmpty ||
        validatedTags(strategy.tags, limit: _maxRemoteStrategyTags)
            .isNotEmpty;
  }

  static String boundedString(Object? value, int maxLength) {
    if (value is! String) {
      return '';
    }
    return truncate(value.trim(), maxLength);
  }

  /// Hard-cap a string so one oversized field cannot blow up a request payload.
  static String truncate(String value, int maxLength) {
    if (value.length <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength);
  }
}
