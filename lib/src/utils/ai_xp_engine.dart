import 'dart:math' as math;

import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/utils/favorite_dedupe_util.dart';

/// Deterministic local AI XP engine.
///
/// Adapts Pixiv-XP-Pusher concepts to pure Dart over [AiGallerySignal]:
/// recency-decayed TF-IDF tag/title profiles, saturation filtering,
/// tag-pair PMI, explainable ranking with uploader diversity, conservative
/// duplicate grouping, rule-based favorite organization, and NL search intent.
class AiXpEngine {
  final int timeDecayDays;
  final double saturationThreshold;
  final int maxTagPairs;
  final double diversityDecay;
  final double diversityFloor;
  final double pairBonusScale;
  final double titleMatchScale;
  final int maxExplanations;

  const AiXpEngine({
    this.timeDecayDays = 180,
    this.saturationThreshold = 0.85,
    this.maxTagPairs = 50,
    this.diversityDecay = 0.7,
    this.diversityFloor = 0.1,
    this.pairBonusScale = 0.15,
    this.titleMatchScale = 0.25,
    this.maxExplanations = 8,
  });

  // ---------------------------------------------------------------------------
  // Profile
  // ---------------------------------------------------------------------------

  /// Build a versioned XP profile from source signals.
  ///
  /// Deterministic for the same [signals] and [nowMs]. Source gids are recorded
  /// so [rankCandidates] can exclude them.
  AiXpProfile buildProfile(
    List<AiGallerySignal> signals, {
    int? nowMs,
  }) {
    final int effectiveNow = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (signals.isEmpty) {
      return AiXpProfile(builtAtMs: effectiveNow, signalCount: 0);
    }

    final List<int> sourceGids = signals.map((AiGallerySignal s) => s.gid).toList()
      ..sort();

    // term -> list of (gid, timestampMs)
    final Map<String, List<_Occurrence>> tagOcc = <String, List<_Occurrence>>{};
    final Map<String, List<_Occurrence>> titleOcc = <String, List<_Occurrence>>{};
    final List<Set<String>> perDocTags = <Set<String>>[];

    for (final AiGallerySignal signal in signals) {
      final int ts = signal.recencyMs ?? effectiveNow;
      final Set<String> docTags = <String>{};

      for (final String raw in signal.tags) {
        final String tag = normalizeTag(raw);
        if (tag.isEmpty || _stopWords.contains(tag)) {
          continue;
        }
        docTags.add(tag);
        (tagOcc[tag] ??= <_Occurrence>[]).add(_Occurrence(signal.gid, ts));
      }

      for (final String token in tokenizeTitle(signal.title)) {
        if (_stopWords.contains(token)) {
          continue;
        }
        (titleOcc[token] ??= <_Occurrence>[]).add(_Occurrence(signal.gid, ts));
      }

      perDocTags.add(docTags);
    }

    final int totalDocs = signals.length;
    final List<String> saturatedTags = <String>[];
    final Map<String, int> tagDf = <String, int>{};

    for (final MapEntry<String, List<_Occurrence>> entry in tagOcc.entries) {
      final int df = _documentFrequency(entry.value);
      tagDf[entry.key] = df;
      if (_isSaturated(df: df, totalDocuments: totalDocs)) {
        saturatedTags.add(entry.key);
      }
    }
    saturatedTags.sort();
    final Set<String> saturatedSet = saturatedTags.toSet();

    final Map<String, double> tagWeights = <String, double>{};
    for (final MapEntry<String, List<_Occurrence>> entry in tagOcc.entries) {
      if (saturatedSet.contains(entry.key)) {
        continue;
      }
      final double weight = _calculateWeight(
        occurrences: entry.value,
        df: tagDf[entry.key]!,
        totalDocuments: totalDocs,
        nowMs: effectiveNow,
      );
      if (weight > 0) {
        tagWeights[entry.key] = weight;
      }
    }

    final Map<String, double> titleWeights = <String, double>{};
    for (final MapEntry<String, List<_Occurrence>> entry in titleOcc.entries) {
      final int df = _documentFrequency(entry.value);
      if (_isSaturated(df: df, totalDocuments: totalDocs)) {
        continue;
      }
      final double weight = _calculateWeight(
        occurrences: entry.value,
        df: df,
        totalDocuments: totalDocs,
        nowMs: effectiveNow,
      );
      if (weight > 0) {
        titleWeights[entry.key] = weight;
      }
    }

    // Tag-pair PMI over non-saturated tags present in the profile.
    //
    // Counted on interned integer ids rather than concatenated string keys: a
    // gallery with T profile tags contributes T*(T-1)/2 pairs, so string keys
    // allocate millions of short-lived strings on a large favorites library.
    // Ids are dense, so `left * idCount + right` is a collision-free int key;
    // strings are re-materialized only when building the pair list below.
    //
    // [tagWeights] already excludes saturated tags, so membership in
    // [pairTagIds] subsumes the previous saturated/weight double check.
    // Ids follow sorted tag order, so sorting ids per document yields the same
    // (left, right) orientation the previous string sort did.
    final List<String> pairTags = tagWeights.keys.toList()..sort();
    final int idCount = pairTags.length;
    final Map<String, int> pairTagIds = <String, int>{
      for (int i = 0; i < idCount; i++) pairTags[i]: i,
    };

    final Map<int, int> pairCounts = <int, int>{};
    final List<int> docIds = <int>[];
    for (final Set<String> docTags in perDocTags) {
      docIds.clear();
      for (final String tag in docTags) {
        final int? id = pairTagIds[tag];
        if (id != null) {
          docIds.add(id);
        }
      }
      if (docIds.length < 2) {
        continue;
      }
      docIds.sort();
      for (int i = 0; i < docIds.length; i++) {
        final int base = docIds[i] * idCount;
        for (int j = i + 1; j < docIds.length; j++) {
          final int key = base + docIds[j];
          pairCounts[key] = (pairCounts[key] ?? 0) + 1;
        }
      }
    }

    final List<AiXpTagPair> pairs = <AiXpTagPair>[];
    pairCounts.forEach((int key, int count) {
      final String left = pairTags[key ~/ idCount];
      final String right = pairTags[key % idCount];
      final double pT1 = (tagDf[left] ?? 1) / totalDocs;
      final double pT2 = (tagDf[right] ?? 1) / totalDocs;
      final double pJoint = count / totalDocs;
      final double pmi = math.log(pJoint / (pT1 * pT2 + 1e-10) + 1e-10);
      if (pmi > 0) {
        final double weight = pmi * ((tagWeights[left] ?? 0) + (tagWeights[right] ?? 0));
        pairs.add(AiXpTagPair(
          left: left,
          right: right,
          pmi: pmi,
          weight: weight,
          count: count,
        ));
      }
    });
    pairs.sort((AiXpTagPair a, AiXpTagPair b) {
      final int byWeight = b.weight.compareTo(a.weight);
      if (byWeight != 0) {
        return byWeight;
      }
      final int byLeft = a.left.compareTo(b.left);
      if (byLeft != 0) {
        return byLeft;
      }
      return a.right.compareTo(b.right);
    });
    final List<AiXpTagPair> topPairs =
        pairs.length > maxTagPairs ? pairs.sublist(0, maxTagPairs) : pairs;

    return AiXpProfile(
      version: AiXpProfile.currentVersion,
      builtAtMs: effectiveNow,
      signalCount: totalDocs,
      sourceGids: sourceGids,
      tagWeights: tagWeights,
      titleWeights: titleWeights,
      tagPairs: topPairs,
      saturatedTags: saturatedTags,
    );
  }

  /// Minimum source-document count before hard saturation filtering applies.
  ///
  /// Below this, a small homogeneous library cannot separate universal noise
  /// from the only available preference signal, so all terms are kept.
  static const int _minDocumentsForSaturation = 5;

  /// Whether [df]/[totalDocuments] should be hard-filtered as saturated noise.
  ///
  /// Cold-start guard: saturation is disabled until the corpus has at least
  /// [_minDocumentsForSaturation] documents. Larger corpora keep the existing
  /// threshold behavior (e.g. 6/6 universal tags still drop out).
  bool _isSaturated({required int df, required int totalDocuments}) {
    if (totalDocuments < _minDocumentsForSaturation) {
      return false;
    }
    return df / totalDocuments > saturationThreshold;
  }

  /// Number of distinct source documents [occurrences] came from.
  static int _documentFrequency(List<_Occurrence> occurrences) {
    final Set<int> gids = <int>{};
    for (final _Occurrence occurrence in occurrences) {
      gids.add(occurrence.gid);
    }
    return gids.length;
  }

  /// Recency-decayed TF-IDF weight for one term.
  ///
  /// [df] is supplied by the caller, which has already computed it to decide
  /// saturation — recomputing it here would rebuild the same gid set twice for
  /// every term in the library. Callers filter saturated terms out beforehand.
  double _calculateWeight({
    required List<_Occurrence> occurrences,
    required int df,
    required int totalDocuments,
    required int nowMs,
  }) {
    double weightedTf = 0;
    for (final _Occurrence occ in occurrences) {
      final int daysAgo = math.max(0, ((nowMs - occ.timestampMs) / 86400000).floor());
      // Non-positive decay window disables recency decay (avoids /0, NaN, Inf).
      final double decay = timeDecayDays <= 0 ? 1.0 : math.exp(-daysAgo / timeDecayDays);
      weightedTf += decay;
    }
    if (weightedTf > 0) {
      weightedTf = math.log(1 + weightedTf) / math.ln10;
    }
    final double idf = math.log(totalDocuments / (df + 1)) + 1;
    return weightedTf * idf;
  }

  // ---------------------------------------------------------------------------
  // Ranking
  // ---------------------------------------------------------------------------

  /// Rank [candidates] against [profile], excluding source gids.
  ///
  /// Scores are explainable; when [applyUploaderDiversity] is true the same
  /// uploader is decayed after the first hit.
  List<AiXpRankedCandidate> rankCandidates({
    required AiXpProfile profile,
    required List<AiGallerySignal> candidates,
    int? limit,
    bool applyUploaderDiversity = true,
  }) {
    if (candidates.isEmpty || profile.isEmpty) {
      return const <AiXpRankedCandidate>[];
    }

    final Set<int> excluded = profile.sourceGids.toSet();
    final List<double> sortedWeights = profile.tagWeights.values.toList()
      ..sort((double a, double b) => b.compareTo(a));
    final double maxWeight = sortedWeights.isEmpty ? 1.0 : sortedWeights.first;
    final double topThreshold = sortedWeights.length >= 5
        ? sortedWeights[sortedWeights.length ~/ 5]
        : maxWeight * 0.8;

    final List<AiXpRankedCandidate> scored = <AiXpRankedCandidate>[];

    for (final AiGallerySignal candidate in candidates) {
      if (excluded.contains(candidate.gid)) {
        continue;
      }

      final List<AiXpScoreExplanation> explanations = <AiXpScoreExplanation>[];
      double totalTagScore = 0;
      int matchedCount = 0;
      int highWeightMatches = 0;
      final Set<String> candidateTags = <String>{};

      for (final String raw in candidate.tags) {
        final String tag = normalizeTag(raw);
        if (tag.isEmpty) {
          continue;
        }
        candidateTags.add(tag);
        final double? weight = profile.tagWeights[tag];
        if (weight == null) {
          continue;
        }
        totalTagScore += weight;
        matchedCount++;
        if (weight >= topThreshold) {
          highWeightMatches++;
        }
        explanations.add(AiXpScoreExplanation(
          kind: 'tag',
          detail: tag,
          contribution: weight,
        ));
      }

      double pairBonus = 0;
      for (final AiXpTagPair pair in profile.tagPairs) {
        if (candidateTags.contains(pair.left) && candidateTags.contains(pair.right)) {
          final double contrib = pair.weight * pairBonusScale;
          pairBonus += contrib;
          explanations.add(AiXpScoreExplanation(
            kind: 'pair',
            detail: '${pair.left}+${pair.right}',
            contribution: contrib,
          ));
        }
      }

      double titleScore = 0;
      for (final String token in tokenizeTitle(candidate.title)) {
        final double? weight = profile.titleWeights[token];
        if (weight == null) {
          continue;
        }
        final double contrib = weight * titleMatchScale;
        titleScore += contrib;
        explanations.add(AiXpScoreExplanation(
          kind: 'title',
          detail: token,
          contribution: contrib,
        ));
      }

      if (matchedCount == 0 && pairBonus == 0 && titleScore == 0) {
        continue;
      }

      final double baseScore = matchedCount > 0 && maxWeight > 0
          ? totalTagScore / (matchedCount * maxWeight)
          : 0;
      final double quantityBonus =
          matchedCount > 0 ? math.min(math.log(1 + matchedCount) / math.log(6), 0.3) : 0;
      final double qualityBonus = math.min(highWeightMatches * 0.05, 0.2);
      double score = baseScore + quantityBonus + qualityBonus + pairBonus + titleScore;
      score = score.clamp(0.0, 2.0).toDouble();

      explanations.sort((AiXpScoreExplanation a, AiXpScoreExplanation b) {
        final int byContrib = b.contribution.compareTo(a.contribution);
        if (byContrib != 0) {
          return byContrib;
        }
        return a.detail.compareTo(b.detail);
      });
      final List<AiXpScoreExplanation> trimmed = explanations.length > maxExplanations
          ? explanations.sublist(0, maxExplanations)
          : explanations;

      scored.add(AiXpRankedCandidate(
        signal: candidate,
        score: score,
        explanations: trimmed,
      ));
    }

    scored.sort(_compareRanked);

    if (!applyUploaderDiversity || scored.isEmpty) {
      if (limit != null && scored.length > limit) {
        return scored.sublist(0, limit);
      }
      return scored;
    }

    final Map<String, int> uploaderPosition = <String, int>{};
    final List<AiXpRankedCandidate> diversified = <AiXpRankedCandidate>[];

    for (final AiXpRankedCandidate item in scored) {
      final String key = (item.signal.uploader ?? '').trim().toLowerCase();
      final int pos = key.isEmpty ? 0 : (uploaderPosition[key] ?? 0);
      final double multiplier = key.isEmpty
          ? 1.0
          : (1.0 - diversityFloor) * math.pow(diversityDecay, pos).toDouble() + diversityFloor;
      final double newScore = item.score * multiplier;

      final List<AiXpScoreExplanation> explanations =
          List<AiXpScoreExplanation>.from(item.explanations);
      if (key.isNotEmpty && pos > 0) {
        explanations.add(AiXpScoreExplanation(
          kind: 'diversity',
          detail: 'uploader:$key#${pos + 1}',
          contribution: newScore - item.score,
        ));
      }
      if (key.isNotEmpty) {
        uploaderPosition[key] = pos + 1;
      }

      diversified.add(AiXpRankedCandidate(
        signal: item.signal,
        score: newScore,
        explanations: explanations,
      ));
    }

    diversified.sort(_compareRanked);
    if (limit != null && diversified.length > limit) {
      return diversified.sublist(0, limit);
    }
    return diversified;
  }

  int _compareRanked(AiXpRankedCandidate a, AiXpRankedCandidate b) {
    final int byScore = b.score.compareTo(a.score);
    if (byScore != 0) {
      return byScore;
    }
    return a.signal.gid.compareTo(b.signal.gid);
  }

  // ---------------------------------------------------------------------------
  // Duplicates
  // ---------------------------------------------------------------------------

  /// Conservatively group duplicates by category + normalized title.
  ///
  /// Empty titles (after normalization) are never grouped. The first item in
  /// input order for each key is the keeper.
  List<AiXpDuplicateGroup> groupDuplicates(List<AiGallerySignal> items) {
    final Map<String, _DedupeBucket> buckets = <String, _DedupeBucket>{};
    final List<String> order = <String>[];

    for (final AiGallerySignal item in items) {
      final String? key = buildDedupeKey(category: item.category, title: item.title);
      if (key == null) {
        continue;
      }
      final _DedupeBucket? existing = buckets[key];
      if (existing == null) {
        buckets[key] = _DedupeBucket(
          keeperGid: item.gid,
          duplicateGids: <int>[],
          normalizedTitle: normalizeTitle(item.title),
          normalizedCategory: normalizeCategory(item.category),
        );
        order.add(key);
      } else {
        existing.duplicateGids.add(item.gid);
      }
    }

    final List<AiXpDuplicateGroup> groups = <AiXpDuplicateGroup>[];
    for (final String key in order) {
      final _DedupeBucket bucket = buckets[key]!;
      if (bucket.duplicateGids.isEmpty) {
        continue;
      }
      groups.add(AiXpDuplicateGroup(
        keeperGid: bucket.keeperGid,
        duplicateGids: List<int>.from(bucket.duplicateGids),
        normalizedTitle: bucket.normalizedTitle,
        normalizedCategory: bucket.normalizedCategory,
      ));
    }
    return groups;
  }

  /// Build a stable dedupe key, or null when title/category is empty.
  ///
  /// Delegates to [buildFavoriteDedupeKey] so the AI duplicate scanner and the
  /// favorites-page dedupe button agree on what counts as the same gallery.
  static String? buildDedupeKey({required String category, required String title}) {
    return buildFavoriteDedupeKey(category: category, title: title);
  }

  static String normalizeTitle(String title) => normalizeFavoriteTitle(title);

  static String normalizeCategory(String category) => normalizeFavoriteCategory(category);

  // ---------------------------------------------------------------------------
  // Organization
  // ---------------------------------------------------------------------------

  /// Parse free-form requirements into moves against existing favorite categories.
  ///
  /// Supported rule arrows: `->`, `=>`, `放入`, `归入`.
  /// Targets match category names (case-insensitive) or numeric indexes.
  AiXpOrganizationPlan organizeFavorites({
    required String requirements,
    required List<AiGallerySignal> favorites,
    required List<String> categoryNames,
  }) {
    final List<AiXpOrganizationRule> rules = parseOrganizationRules(
      requirements,
      categoryNames,
    );
    if (rules.isEmpty || favorites.isEmpty) {
      return AiXpOrganizationPlan(rules: rules);
    }

    final List<AiXpOrganizationMove> moves = <AiXpOrganizationMove>[];
    final Set<int> moved = <int>{};

    for (final AiGallerySignal fav in favorites) {
      if (moved.contains(fav.gid)) {
        continue;
      }
      for (final AiXpOrganizationRule rule in rules) {
        final String? matched = _matchOrganizationRule(fav, rule.matcher);
        if (matched == null) {
          continue;
        }
        if (fav.favoriteCategoryIndex == rule.targetIndex) {
          break;
        }
        moves.add(AiXpOrganizationMove(
          gid: fav.gid,
          fromIndex: fav.favoriteCategoryIndex,
          targetIndex: rule.targetIndex,
          targetName: rule.targetName,
          matchedRule: rule.raw,
          matchedTerm: matched,
        ));
        moved.add(fav.gid);
        break;
      }
    }

    return AiXpOrganizationPlan(rules: rules, moves: moves);
  }

  /// Parse organization rules from free-form text.
  List<AiXpOrganizationRule> parseOrganizationRules(
    String requirements,
    List<String> categoryNames,
  ) {
    final List<AiXpOrganizationRule> rules = <AiXpOrganizationRule>[];
    final List<String> chunks = requirements
        .split(RegExp(r'[\n;；]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();

    final RegExp arrow = RegExp(r'\s*(?:->|=>|放入|归入)\s*');

    for (final String chunk in chunks) {
      final Match? match = arrow.firstMatch(chunk);
      if (match == null) {
        continue;
      }
      final String left = chunk.substring(0, match.start).trim();
      final String right = chunk.substring(match.end).trim();
      if (left.isEmpty || right.isEmpty) {
        continue;
      }

      final ({int index, String name})? target = resolveCategoryTarget(right, categoryNames);
      if (target == null) {
        continue;
      }

      rules.add(AiXpOrganizationRule(
        matcher: left,
        targetIndex: target.index,
        targetName: target.name,
        raw: chunk,
      ));
    }
    return rules;
  }

  /// Resolve a category target by exact/case-insensitive name or numeric index.
  static ({int index, String name})? resolveCategoryTarget(
    String raw,
    List<String> categoryNames,
  ) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty || categoryNames.isEmpty) {
      return null;
    }

    final int? asIndex = int.tryParse(trimmed);
    if (asIndex != null && asIndex >= 0 && asIndex < categoryNames.length) {
      return (index: asIndex, name: categoryNames[asIndex]);
    }

    final String lower = trimmed.toLowerCase();
    for (int i = 0; i < categoryNames.length; i++) {
      if (categoryNames[i].toLowerCase() == lower) {
        return (index: i, name: categoryNames[i]);
      }
    }

    // Prefix / contains match only when unique.
    final List<int> partial = <int>[];
    for (int i = 0; i < categoryNames.length; i++) {
      final String name = categoryNames[i].toLowerCase();
      if (name.contains(lower) || lower.contains(name)) {
        partial.add(i);
      }
    }
    if (partial.length == 1) {
      final int i = partial.first;
      return (index: i, name: categoryNames[i]);
    }
    return null;
  }

  String? _matchOrganizationRule(AiGallerySignal fav, String matcher) {
    final String m = matcher.trim();
    if (m.isEmpty) {
      return null;
    }

    final String normalizedMatcher = normalizeTag(m);
    for (final String raw in fav.tags) {
      final String tag = normalizeTag(raw);
      if (tag == normalizedMatcher || tag.endsWith(':$normalizedMatcher')) {
        return tag;
      }
      // Allow bare key match against namespace:key.
      if (!m.contains(':') && tag.contains(':')) {
        final String key = tag.substring(tag.indexOf(':') + 1);
        if (key == normalizedMatcher || key == m.toLowerCase()) {
          return tag;
        }
      }
    }

    final String titleLower = fav.title.toLowerCase();
    final String matcherLower = m.toLowerCase();
    if (titleLower.contains(matcherLower)) {
      return m;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Search intent
  // ---------------------------------------------------------------------------

  /// Parse a free-form search string into structured intent fields.
  AiXpSearchIntent parseSearchIntent(String query) {
    String remaining = query.trim();
    if (remaining.isEmpty) {
      return AiXpSearchIntent(rawQuery: query);
    }

    String? language;
    bool? requireTorrent;
    int? minimumRating;
    int? pageAtLeast;
    int? pageAtMost;
    final List<String> categories = <String>[];
    final List<String> tags = <String>[];
    String? xpPreference;

    // XP preference phrase: xp:..., 偏好..., 性癖...
    final RegExp xpPhrase = RegExp(
      r'(?:xp\s*[:=：]\s*|偏好\s*[:=：]?\s*|性癖\s*[:=：]?\s*)(.+)$',
      caseSensitive: false,
    );
    final Match? xpMatch = xpPhrase.firstMatch(remaining);
    if (xpMatch != null) {
      xpPreference = xpMatch.group(1)!.trim();
      remaining = remaining.replaceRange(xpMatch.start, xpMatch.end, ' ').trim();
    }

    // Exact namespace:key tags (quoted key optional).
    final RegExp exactTag = RegExp(
      r'''([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(?:"([^"]+)"|'([^']+)'|([^\s,;；，]+))''',
    );
    remaining = remaining.replaceAllMapped(exactTag, (Match m) {
      final String ns = m.group(1)!.toLowerCase();
      final String key = (m.group(2) ?? m.group(3) ?? m.group(4)!)
          .trim()
          .toLowerCase()
          .replaceAll(' ', '_');
      // Skip language:xxx handled as language field when ns is language.
      if (ns == 'language') {
        language ??= key;
        return ' ';
      }
      tags.add('$ns:$key');
      return ' ';
    });

    // Language words (CN/EN).
    final Map<String, String> languageWords = <String, String>{
      'chinese': 'chinese',
      '中文': 'chinese',
      '汉语': 'chinese',
      '漢語': 'chinese',
      '国语': 'chinese',
      '國語': 'chinese',
      '中国語': 'chinese',
      'english': 'english',
      '英文': 'english',
      '英语': 'english',
      '英語': 'english',
      'japanese': 'japanese',
      '日文': 'japanese',
      '日语': 'japanese',
      '日語': 'japanese',
      '日本語': 'japanese',
      'korean': 'korean',
      '韩文': 'korean',
      '韓文': 'korean',
      '韩语': 'korean',
      '韓語': 'korean',
      'spanish': 'spanish',
      '西班牙语': 'spanish',
      'french': 'french',
      '法语': 'french',
      '法語': 'french',
      'russian': 'russian',
      '俄语': 'russian',
      '俄語': 'russian',
    };
    for (final MapEntry<String, String> entry in languageWords.entries) {
      final RegExp word = RegExp(
        '(?:^|[\\s,;；，])${RegExp.escape(entry.key)}(?=[\\s,;；，]|\$)',
        caseSensitive: false,
      );
      if (word.hasMatch(remaining)) {
        language ??= entry.value;
        remaining = remaining.replaceAll(word, ' ');
      }
    }

    // Torrent flags.
    final List<RegExp> withTorrentPatterns = <RegExp>[
      RegExp(r'\bwith\s+torrents?\b', caseSensitive: false),
      RegExp(r'\bhas\s+torrents?\b', caseSensitive: false),
      RegExp(r'\btorrent\s+only\b', caseSensitive: false),
      RegExp(r'有种子'),
      RegExp(r'有種子'),
      RegExp(r'带种子'),
      RegExp(r'帶種子'),
      RegExp(r'含种子'),
      RegExp(r'含種子'),
    ];
    final List<RegExp> withoutTorrentPatterns = <RegExp>[
      RegExp(r'\bwithout\s+torrents?\b', caseSensitive: false),
      RegExp(r'\bno\s+torrents?\b', caseSensitive: false),
      RegExp(r'无种子'),
      RegExp(r'無種子'),
      RegExp(r'没有种子'),
      RegExp(r'沒有種子'),
      RegExp(r'不含种子'),
      RegExp(r'不含種子'),
    ];
    for (final RegExp re in withoutTorrentPatterns) {
      if (re.hasMatch(remaining)) {
        requireTorrent = false;
        remaining = remaining.replaceAll(re, ' ');
      }
    }
    for (final RegExp re in withTorrentPatterns) {
      if (re.hasMatch(remaining)) {
        // without wins if both present (stable with SearchConfig semantics).
        requireTorrent ??= true;
        remaining = remaining.replaceAll(re, ' ');
      }
    }

    // Min rating. English "stars" suffix is optional; capture the full numeric token.
    final List<RegExp> ratingPatterns = <RegExp>[
      RegExp(
        r'(?:min(?:imum)?\s*rating|rating)\s*[>=:：]?\s*(\d+(?:\.\d+)?)\s*(?:stars?)?',
        caseSensitive: false,
      ),
      RegExp(r'rating\s*[>=:：]\s*(\d+(?:\.\d+)?)', caseSensitive: false),
      RegExp(r'评分\s*(?:至少|>=?|不低于)\s*(\d+(?:\.\d+)?)'),
      RegExp(r'評分\s*(?:至少|>=?|不低於)\s*(\d+(?:\.\d+)?)'),
      RegExp(r'(?:至少\s*)(\d+(?:\.\d+)?)\s*星'),
      RegExp(r'(\d+(?:\.\d+)?)\s*星(?:以上|及以上)?'),
    ];
    for (final RegExp re in ratingPatterns) {
      final Match? m = re.firstMatch(remaining);
      if (m != null) {
        final double value = double.tryParse(m.group(1)!) ?? 0;
        minimumRating = value.round().clamp(1, 5).toInt();
        remaining = remaining.replaceFirst(re, ' ');
        break;
      }
    }

    // Page bounds. Max is parsed before min: the min list has a bare
    // `pages?` alternative with an optional operator, so it would otherwise
    // claim the number in "max pages: 30" and record it as a minimum.
    final List<RegExp> maxPagePatterns = <RegExp>[
      RegExp(
        r'(?:max(?:imum)?\s*pages?|pages?)\s*[<=:：]\s*(\d+)',
        caseSensitive: false,
      ),
      RegExp(r'at\s+most\s+(\d+)\s*pages?', caseSensitive: false),
      RegExp(r'页数\s*(?:至多|最多|<=?|不超过)\s*(\d+)'),
      RegExp(r'頁數\s*(?:至多|最多|<=?|不超過)\s*(\d+)'),
      RegExp(r'最多\s*(\d+)\s*页'),
      RegExp(r'最多\s*(\d+)\s*頁'),
    ];
    for (final RegExp re in maxPagePatterns) {
      final Match? m = re.firstMatch(remaining);
      if (m != null) {
        pageAtMost = int.tryParse(m.group(1)!);
        remaining = remaining.replaceFirst(re, ' ');
        break;
      }
    }

    final List<RegExp> minPagePatterns = <RegExp>[
      RegExp(
        r'(?:min(?:imum)?\s*pages?|pages?)\s*[>=:：]?\s*(\d+)',
        caseSensitive: false,
      ),
      RegExp(r'at\s+least\s+(\d+)\s*pages?', caseSensitive: false),
      RegExp(r'页数\s*(?:至少|>=?|不少于)\s*(\d+)'),
      RegExp(r'頁數\s*(?:至少|>=?|不少於)\s*(\d+)'),
      RegExp(r'至少\s*(\d+)\s*页'),
      RegExp(r'至少\s*(\d+)\s*頁'),
    ];
    for (final RegExp re in minPagePatterns) {
      final Match? m = re.firstMatch(remaining);
      if (m != null) {
        pageAtLeast = int.tryParse(m.group(1)!);
        remaining = remaining.replaceFirst(re, ' ');
        break;
      }
    }

    // Category words.
    for (final MapEntry<String, String> entry in _categoryAliases.entries) {
      final RegExp word = RegExp(
        '(?:^|[\\s,;；，])${RegExp.escape(entry.key)}(?=[\\s,;；，]|\$)',
        caseSensitive: false,
      );
      if (word.hasMatch(remaining)) {
        if (!categories.contains(entry.value)) {
          categories.add(entry.value);
        }
        remaining = remaining.replaceAll(word, ' ');
      }
    }

    remaining = remaining.replaceAll(RegExp(r'\s+'), ' ').trim();

    // If no explicit xp phrase, residual free text becomes the preference.
    if (xpPreference == null && remaining.isNotEmpty) {
      xpPreference = remaining;
    }

    return AiXpSearchIntent(
      rawQuery: query,
      language: language,
      requireTorrent: requireTorrent,
      minimumRating: minimumRating,
      pageAtLeast: pageAtLeast,
      pageAtMost: pageAtMost,
      categories: categories,
      tags: tags,
      xpPreference: xpPreference,
      residualKeyword: remaining,
    );
  }

  // ---------------------------------------------------------------------------
  // Shared normalization helpers
  // ---------------------------------------------------------------------------

  /// Normalize a tag to lowercase `namespace:key` or bare key with spaces -> `_`.
  static String normalizeTag(String raw) {
    String tag = raw.trim().toLowerCase();
    if (tag.isEmpty) {
      return '';
    }
    // Strip common Pixiv-style popularity suffixes if present ("1000users入り").
    // り = hiragana り, リ = katakana リ (both spellings occur in the wild).
    tag = tag.replaceFirst(RegExp(r'\d+users入[りリ]?$'), '');
    tag = tag.replaceAll(RegExp(r'\s+'), '_');
    tag = tag.replaceAll(RegExp(r'_+'), '_');
    tag = tag.replaceAll(RegExp(r'^_|_$'), '');
    return tag;
  }

  /// Tokenize a gallery title into lowercase terms for the title profile.
  ///
  /// Keeps Latin alphanumerics (len >= 2), CJK ideographs, Japanese
  /// hiragana/katakana runs, and Korean Hangul syllable runs.
  static List<String> tokenizeTitle(String title) {
    final String cleaned = title.toLowerCase().replaceAll(RegExp(r'[\[\]\(\)【】（）{}]'), ' ');
    final Iterable<RegExpMatch> matches = RegExp(
      r'[a-z0-9]{2,}'
      r'|[\u4e00-\u9fff]+'
      r'|[\u3040-\u309f]+'
      r'|[\u30a0-\u30ff]+'
      r'|[\uac00-\ud7af]+',
    ).allMatches(cleaned);
    final List<String> tokens = <String>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch m in matches) {
      final String t = m.group(0)!;
      if (_stopWords.contains(t)) {
        continue;
      }
      if (seen.add(t)) {
        tokens.add(t);
      }
    }
    return tokens;
  }

  static const Set<String> _stopWords = <String>{
    'the',
    'and',
    'for',
    'with',
    'from',
    'original',
    'manga',
    'doujinshi',
    'comic',
    'digital',
    'artist',
    'group',
    'various',
    'translated',
    'english',
    'chinese',
    'japanese',
    'rewrite',
    'full',
    'color',
    'coloured',
    'colored',
  };

  /// Alias -> canonical EH category name.
  static const Map<String, String> _categoryAliases = <String, String>{
    'doujinshi': 'Doujinshi',
    '同人': 'Doujinshi',
    '同人志': 'Doujinshi',
    'manga': 'Manga',
    '漫画': 'Manga',
    '漫畫': 'Manga',
    'artist cg': 'Artist CG',
    'artistcg': 'Artist CG',
    '画师cg': 'Artist CG',
    '畫師cg': 'Artist CG',
    'artist_cg': 'Artist CG',
    'game cg': 'Game CG',
    'gamecg': 'Game CG',
    '游戏cg': 'Game CG',
    '遊戲cg': 'Game CG',
    'game_cg': 'Game CG',
    'western': 'Western',
    '西方': 'Western',
    'non-h': 'Non-H',
    'nonh': 'Non-H',
    'non_h': 'Non-H',
    '非h': 'Non-H',
    'image set': 'Image Set',
    'imageset': 'Image Set',
    'image_set': 'Image Set',
    '图集': 'Image Set',
    '圖集': 'Image Set',
    'cosplay': 'Cosplay',
    '角色扮演': 'Cosplay',
    'asian porn': 'Asian Porn',
    'asianporn': 'Asian Porn',
    'asian_porn': 'Asian Porn',
    '亚洲': 'Asian Porn',
    '亞洲': 'Asian Porn',
    'misc': 'Misc',
    '杂项': 'Misc',
    '雜項': 'Misc',
  };
}

class _Occurrence {
  final int gid;
  final int timestampMs;

  const _Occurrence(this.gid, this.timestampMs);
}

class _DedupeBucket {
  final int keeperGid;
  final List<int> duplicateGids;
  final String normalizedTitle;
  final String normalizedCategory;

  _DedupeBucket({
    required this.keeperGid,
    required this.duplicateGids,
    required this.normalizedTitle,
    required this.normalizedCategory,
  });
}
