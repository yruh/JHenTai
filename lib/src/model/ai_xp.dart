/// AI XP domain models and locally computed statistical signals.
///
/// No Flutter / GetX / UI imports. Gallery rows are adapted into
/// [AiGallerySignal] by a later service; this file only defines the
/// versioned, JSON-roundtrippable value types used by [AiXpEngine].

/// Input signal for profile building and ranking.
class AiGallerySignal {
  final int gid;
  final String title;

  /// EH gallery category, e.g. `Doujinshi`, `Manga`.
  final String category;

  /// Tags as `namespace:key` (preferred) or bare keys.
  final List<String> tags;

  final String? uploader;
  final double rating;
  final int? pageCount;
  final String? language;
  final int? torrentCount;
  final int? favoriteCategoryIndex;
  final String? favoriteCategoryName;

  /// Favorited / bookmarked time in epoch ms (preferred for recency).
  final int? favoritedAtMs;

  /// Publish time in epoch ms (fallback for recency).
  final int? publishedAtMs;

  const AiGallerySignal({
    required this.gid,
    required this.title,
    required this.category,
    this.tags = const <String>[],
    this.uploader,
    this.rating = 0,
    this.pageCount,
    this.language,
    this.torrentCount,
    this.favoriteCategoryIndex,
    this.favoriteCategoryName,
    this.favoritedAtMs,
    this.publishedAtMs,
  });

  /// Effective timestamp for recency decay.
  int? get recencyMs => favoritedAtMs ?? publishedAtMs;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'gid': gid,
      'title': title,
      'category': category,
      'tags': List<String>.from(tags),
      'uploader': uploader,
      'rating': rating,
      'pageCount': pageCount,
      'language': language,
      'torrentCount': torrentCount,
      'favoriteCategoryIndex': favoriteCategoryIndex,
      'favoriteCategoryName': favoriteCategoryName,
      'favoritedAtMs': favoritedAtMs,
      'publishedAtMs': publishedAtMs,
    };
  }

  factory AiGallerySignal.fromJson(Map<String, dynamic> json) {
    return AiGallerySignal(
      gid: (json['gid'] as num).toInt(),
      title: json['title'] as String? ?? '',
      category: json['category'] as String? ?? '',
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              const <String>[],
      uploader: json['uploader'] as String?,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      pageCount: (json['pageCount'] as num?)?.toInt(),
      language: json['language'] as String?,
      torrentCount: (json['torrentCount'] as num?)?.toInt(),
      favoriteCategoryIndex: (json['favoriteCategoryIndex'] as num?)?.toInt(),
      favoriteCategoryName: json['favoriteCategoryName'] as String?,
      favoritedAtMs: (json['favoritedAtMs'] as num?)?.toInt(),
      publishedAtMs: (json['publishedAtMs'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'AiGallerySignal(gid: $gid, title: $title, category: $category, tags: $tags)';
}

/// Co-occurrence pair retained in an [AiXpProfile].
class AiXpTagPair {
  final String left;
  final String right;
  final double pmi;
  final double weight;
  final int count;

  const AiXpTagPair({
    required this.left,
    required this.right,
    required this.pmi,
    required this.weight,
    required this.count,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'left': left,
      'right': right,
      'pmi': pmi,
      'weight': weight,
      'count': count,
    };
  }

  factory AiXpTagPair.fromJson(Map<String, dynamic> json) {
    return AiXpTagPair(
      left: json['left'] as String,
      right: json['right'] as String,
      pmi: (json['pmi'] as num).toDouble(),
      weight: (json['weight'] as num).toDouble(),
      count: (json['count'] as num).toInt(),
    );
  }
}

/// Human-readable remote-AI preference for UI display.
class AiXpPreference {
  final String name;
  final String description;

  /// Confidence in [0, 1]. Values outside the range are clamped.
  final double confidence;

  /// Supporting tags as `namespace:key` (preferred) or bare keys.
  final List<String> evidenceTags;

  AiXpPreference({
    required this.name,
    required this.description,
    required double confidence,
    this.evidenceTags = const <String>[],
  }) : confidence = _clampConfidence(confidence);

  static double _clampConfidence(double value) {
    if (value.isNaN) {
      return 0;
    }
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'description': description,
      'confidence': confidence,
      'evidenceTags': List<String>.from(evidenceTags),
    };
  }

  factory AiXpPreference.fromJson(Map<String, dynamic> json) {
    return AiXpPreference(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      evidenceTags: (json['evidenceTags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
    );
  }
}

/// Suggested search strategy derived from remote AI summary.
class AiXpSearchStrategy {
  final List<String> tags;
  final String keyword;
  final String reason;

  const AiXpSearchStrategy({
    this.tags = const <String>[],
    this.keyword = '',
    this.reason = '',
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'tags': List<String>.from(tags),
      'keyword': keyword,
      'reason': reason,
    };
  }

  factory AiXpSearchStrategy.fromJson(Map<String, dynamic> json) {
    return AiXpSearchStrategy(
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              const <String>[],
      keyword: json['keyword'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
    );
  }
}

/// Versioned user XP profile built from [AiGallerySignal]s.
class AiXpProfile {
  static const int currentVersion = 2;

  final int version;
  final int builtAtMs;
  final int signalCount;

  /// Source gallery ids used to build this profile (excluded from ranking).
  final List<int> sourceGids;

  /// Recency-decayed TF-IDF tag weights (`namespace:key` or bare).
  final Map<String, double> tagWeights;

  /// Recency-decayed TF-IDF title-token weights.
  final Map<String, double> titleWeights;

  /// Positive-PMI tag pairs, highest weight first.
  final List<AiXpTagPair> tagPairs;

  /// Tags removed by saturation filtering.
  final List<String> saturatedTags;

  /// Optional human-readable remote AI summary text.
  final String? summary;

  /// Structured remote-AI preferences for UI.
  final List<AiXpPreference> preferences;

  /// Suggested search strategies from remote AI.
  final List<AiXpSearchStrategy> searchStrategies;

  /// Whether [summary]/[preferences]/[searchStrategies] came from remote AI.
  final bool generatedByRemoteAi;

  const AiXpProfile({
    this.version = currentVersion,
    required this.builtAtMs,
    required this.signalCount,
    this.sourceGids = const <int>[],
    this.tagWeights = const <String, double>{},
    this.titleWeights = const <String, double>{},
    this.tagPairs = const <AiXpTagPair>[],
    this.saturatedTags = const <String>[],
    this.summary,
    this.preferences = const <AiXpPreference>[],
    this.searchStrategies = const <AiXpSearchStrategy>[],
    this.generatedByRemoteAi = false,
  });

  bool get isEmpty => tagWeights.isEmpty && titleWeights.isEmpty;

  AiXpProfile copyWith({
    int? version,
    int? builtAtMs,
    int? signalCount,
    List<int>? sourceGids,
    Map<String, double>? tagWeights,
    Map<String, double>? titleWeights,
    List<AiXpTagPair>? tagPairs,
    List<String>? saturatedTags,
    String? summary,
    List<AiXpPreference>? preferences,
    List<AiXpSearchStrategy>? searchStrategies,
    bool? generatedByRemoteAi,
  }) {
    return AiXpProfile(
      version: version ?? this.version,
      builtAtMs: builtAtMs ?? this.builtAtMs,
      signalCount: signalCount ?? this.signalCount,
      sourceGids: sourceGids ?? this.sourceGids,
      tagWeights: tagWeights ?? this.tagWeights,
      titleWeights: titleWeights ?? this.titleWeights,
      tagPairs: tagPairs ?? this.tagPairs,
      saturatedTags: saturatedTags ?? this.saturatedTags,
      summary: summary ?? this.summary,
      preferences: preferences ?? this.preferences,
      searchStrategies: searchStrategies ?? this.searchStrategies,
      generatedByRemoteAi: generatedByRemoteAi ?? this.generatedByRemoteAi,
    );
  }

  Map<String, dynamic> toJson() {
    final List<String> tagKeys = tagWeights.keys.toList()..sort();
    final List<String> titleKeys = titleWeights.keys.toList()..sort();
    final List<int> gids = List<int>.from(sourceGids)..sort();
    final List<String> saturated = List<String>.from(saturatedTags)..sort();

    return <String, dynamic>{
      'version': version,
      'builtAtMs': builtAtMs,
      'signalCount': signalCount,
      'sourceGids': gids,
      'tagWeights': <String, double>{
        for (final String k in tagKeys) k: tagWeights[k]!
      },
      'titleWeights': <String, double>{
        for (final String k in titleKeys) k: titleWeights[k]!
      },
      'tagPairs': tagPairs.map((AiXpTagPair p) => p.toJson()).toList(),
      'saturatedTags': saturated,
      'summary': summary,
      'preferences': preferences.map((AiXpPreference p) => p.toJson()).toList(),
      'searchStrategies':
          searchStrategies.map((AiXpSearchStrategy s) => s.toJson()).toList(),
      'generatedByRemoteAi': generatedByRemoteAi,
    };
  }

  factory AiXpProfile.fromJson(Map<String, dynamic> json) {
    final Map<String, double> tags = <String, double>{};
    final Object? rawTags = json['tagWeights'];
    if (rawTags is Map) {
      rawTags.forEach((Object? k, Object? v) {
        tags[k.toString()] = (v as num).toDouble();
      });
    }

    final Map<String, double> titles = <String, double>{};
    final Object? rawTitles = json['titleWeights'];
    if (rawTitles is Map) {
      rawTitles.forEach((Object? k, Object? v) {
        titles[k.toString()] = (v as num).toDouble();
      });
    }

    final List<AiXpTagPair> pairs = <AiXpTagPair>[];
    final Object? rawPairs = json['tagPairs'];
    if (rawPairs is List) {
      for (final Object? item in rawPairs) {
        if (item is Map<String, dynamic>) {
          pairs.add(AiXpTagPair.fromJson(item));
        } else if (item is Map) {
          pairs.add(AiXpTagPair.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final List<AiXpPreference> prefs = <AiXpPreference>[];
    final Object? rawPrefs = json['preferences'];
    if (rawPrefs is List) {
      for (final Object? item in rawPrefs) {
        if (item is Map<String, dynamic>) {
          prefs.add(AiXpPreference.fromJson(item));
        } else if (item is Map) {
          prefs.add(AiXpPreference.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final List<AiXpSearchStrategy> strategies = <AiXpSearchStrategy>[];
    final Object? rawStrategies = json['searchStrategies'];
    if (rawStrategies is List) {
      for (final Object? item in rawStrategies) {
        if (item is Map<String, dynamic>) {
          strategies.add(AiXpSearchStrategy.fromJson(item));
        } else if (item is Map) {
          strategies.add(
              AiXpSearchStrategy.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    return AiXpProfile(
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      builtAtMs: (json['builtAtMs'] as num?)?.toInt() ?? 0,
      signalCount: (json['signalCount'] as num?)?.toInt() ?? 0,
      sourceGids: (json['sourceGids'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const <int>[],
      tagWeights: tags,
      titleWeights: titles,
      tagPairs: pairs,
      saturatedTags: (json['saturatedTags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      summary: json['summary'] as String?,
      preferences: prefs,
      searchStrategies: strategies,
      generatedByRemoteAi: json['generatedByRemoteAi'] as bool? ?? false,
    );
  }
}

/// One explainable contribution to a ranked score.
class AiXpScoreExplanation {
  /// `tag`, `title`, `pair`, `diversity`, or `remote_ai`.
  final String kind;
  final String detail;
  final double contribution;

  const AiXpScoreExplanation({
    required this.kind,
    required this.detail,
    required this.contribution,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind,
      'detail': detail,
      'contribution': contribution,
    };
  }

  factory AiXpScoreExplanation.fromJson(Map<String, dynamic> json) {
    return AiXpScoreExplanation(
      kind: json['kind'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      contribution: (json['contribution'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Ranked recommendation result with score breakdown.
class AiXpRankedCandidate {
  final AiGallerySignal signal;
  final double score;
  final List<AiXpScoreExplanation> explanations;

  const AiXpRankedCandidate({
    required this.signal,
    required this.score,
    this.explanations = const <AiXpScoreExplanation>[],
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'signal': signal.toJson(),
      'score': score,
      'explanations':
          explanations.map((AiXpScoreExplanation e) => e.toJson()).toList(),
    };
  }

  factory AiXpRankedCandidate.fromJson(Map<String, dynamic> json) {
    final Object? rawSignal = json['signal'];
    final Map<String, dynamic> signalMap = rawSignal is Map<String, dynamic>
        ? rawSignal
        : Map<String, dynamic>.from(rawSignal as Map);
    final List<AiXpScoreExplanation> explanations = <AiXpScoreExplanation>[];
    final Object? rawExpl = json['explanations'];
    if (rawExpl is List) {
      for (final Object? item in rawExpl) {
        if (item is Map<String, dynamic>) {
          explanations.add(AiXpScoreExplanation.fromJson(item));
        } else if (item is Map) {
          explanations.add(
              AiXpScoreExplanation.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return AiXpRankedCandidate(
      signal: AiGallerySignal.fromJson(signalMap),
      score: (json['score'] as num?)?.toDouble() ?? 0,
      explanations: explanations,
    );
  }
}

/// Conservative duplicate cluster with a single keeper.
class AiXpDuplicateGroup {
  final int keeperGid;
  final List<int> duplicateGids;
  final String normalizedTitle;
  final String normalizedCategory;

  const AiXpDuplicateGroup({
    required this.keeperGid,
    required this.duplicateGids,
    required this.normalizedTitle,
    required this.normalizedCategory,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'keeperGid': keeperGid,
      'duplicateGids': List<int>.from(duplicateGids),
      'normalizedTitle': normalizedTitle,
      'normalizedCategory': normalizedCategory,
    };
  }

  factory AiXpDuplicateGroup.fromJson(Map<String, dynamic> json) {
    return AiXpDuplicateGroup(
      keeperGid: (json['keeperGid'] as num).toInt(),
      duplicateGids: (json['duplicateGids'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const <int>[],
      normalizedTitle: json['normalizedTitle'] as String? ?? '',
      normalizedCategory: json['normalizedCategory'] as String? ?? '',
    );
  }
}

/// One parsed organization rule from free-form requirements text.
class AiXpOrganizationRule {
  final String matcher;
  final int targetIndex;
  final String targetName;
  final String raw;

  const AiXpOrganizationRule({
    required this.matcher,
    required this.targetIndex,
    required this.targetName,
    required this.raw,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'matcher': matcher,
      'targetIndex': targetIndex,
      'targetName': targetName,
      'raw': raw,
    };
  }

  factory AiXpOrganizationRule.fromJson(Map<String, dynamic> json) {
    return AiXpOrganizationRule(
      matcher: json['matcher'] as String? ?? '',
      targetIndex: (json['targetIndex'] as num?)?.toInt() ?? -1,
      targetName: json['targetName'] as String? ?? '',
      raw: json['raw'] as String? ?? '',
    );
  }
}

/// One planned favorite reassignment.
class AiXpOrganizationMove {
  final int gid;
  final int? fromIndex;
  final int targetIndex;
  final String targetName;
  final String matchedRule;
  final String matchedTerm;

  const AiXpOrganizationMove({
    required this.gid,
    required this.fromIndex,
    required this.targetIndex,
    required this.targetName,
    required this.matchedRule,
    required this.matchedTerm,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'gid': gid,
      'fromIndex': fromIndex,
      'targetIndex': targetIndex,
      'targetName': targetName,
      'matchedRule': matchedRule,
      'matchedTerm': matchedTerm,
    };
  }

  factory AiXpOrganizationMove.fromJson(Map<String, dynamic> json) {
    return AiXpOrganizationMove(
      gid: (json['gid'] as num).toInt(),
      fromIndex: (json['fromIndex'] as num?)?.toInt(),
      targetIndex: (json['targetIndex'] as num).toInt(),
      targetName: json['targetName'] as String? ?? '',
      matchedRule: json['matchedRule'] as String? ?? '',
      matchedTerm: json['matchedTerm'] as String? ?? '',
    );
  }
}

/// Result of rule-based favorite organization.
class AiXpOrganizationPlan {
  final List<AiXpOrganizationRule> rules;
  final List<AiXpOrganizationMove> moves;

  const AiXpOrganizationPlan({
    this.rules = const <AiXpOrganizationRule>[],
    this.moves = const <AiXpOrganizationMove>[],
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'rules': rules.map((AiXpOrganizationRule r) => r.toJson()).toList(),
      'moves': moves.map((AiXpOrganizationMove m) => m.toJson()).toList(),
    };
  }

  factory AiXpOrganizationPlan.fromJson(Map<String, dynamic> json) {
    final List<AiXpOrganizationRule> rules = <AiXpOrganizationRule>[];
    final Object? rawRules = json['rules'];
    if (rawRules is List) {
      for (final Object? item in rawRules) {
        if (item is Map<String, dynamic>) {
          rules.add(AiXpOrganizationRule.fromJson(item));
        } else if (item is Map) {
          rules.add(
              AiXpOrganizationRule.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final List<AiXpOrganizationMove> moves = <AiXpOrganizationMove>[];
    final Object? rawMoves = json['moves'];
    if (rawMoves is List) {
      for (final Object? item in rawMoves) {
        if (item is Map<String, dynamic>) {
          moves.add(AiXpOrganizationMove.fromJson(item));
        } else if (item is Map) {
          moves.add(
              AiXpOrganizationMove.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return AiXpOrganizationPlan(rules: rules, moves: moves);
  }
}

/// Parsed natural-language search intent.
class AiXpSearchIntent {
  final String rawQuery;

  /// Canonical language key when recognized (`chinese`, `english`, ...).
  final String? language;

  /// `true` = require torrent, `false` = require no torrent, `null` = either.
  final bool? requireTorrent;

  final int? minimumRating;
  final int? pageAtLeast;
  final int? pageAtMost;

  /// EH category names to keep enabled.
  final List<String> categories;

  /// Exact `namespace:key` tags.
  final List<String> tags;

  /// Free-form XP preference phrase.
  final String? xpPreference;

  /// Residual keyword text after structured extraction.
  final String residualKeyword;

  const AiXpSearchIntent({
    required this.rawQuery,
    this.language,
    this.requireTorrent,
    this.minimumRating,
    this.pageAtLeast,
    this.pageAtMost,
    this.categories = const <String>[],
    this.tags = const <String>[],
    this.xpPreference,
    this.residualKeyword = '',
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'rawQuery': rawQuery,
      'language': language,
      'requireTorrent': requireTorrent,
      'minimumRating': minimumRating,
      'pageAtLeast': pageAtLeast,
      'pageAtMost': pageAtMost,
      'categories': List<String>.from(categories),
      'tags': List<String>.from(tags),
      'xpPreference': xpPreference,
      'residualKeyword': residualKeyword,
    };
  }

  factory AiXpSearchIntent.fromJson(Map<String, dynamic> json) {
    return AiXpSearchIntent(
      rawQuery: json['rawQuery'] as String? ?? '',
      language: json['language'] as String?,
      requireTorrent: json['requireTorrent'] as bool?,
      minimumRating: (json['minimumRating'] as num?)?.toInt(),
      pageAtLeast: (json['pageAtLeast'] as num?)?.toInt(),
      pageAtMost: (json['pageAtMost'] as num?)?.toInt(),
      categories: (json['categories'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              const <String>[],
      xpPreference: json['xpPreference'] as String?,
      residualKeyword: json['residualKeyword'] as String? ?? '',
    );
  }
}
