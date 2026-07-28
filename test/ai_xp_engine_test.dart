import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/utils/ai_xp_engine.dart';

AiGallerySignal _sig({
  required int gid,
  String title = 'Title',
  String category = 'Doujinshi',
  List<String> tags = const <String>[],
  String? uploader,
  double rating = 4,
  int? pageCount,
  int? favoritedAtMs,
  int? favoriteCategoryIndex,
  String? favoriteCategoryName,
}) {
  return AiGallerySignal(
    gid: gid,
    title: title,
    category: category,
    tags: tags,
    uploader: uploader,
    rating: rating,
    pageCount: pageCount,
    favoritedAtMs: favoritedAtMs,
    favoriteCategoryIndex: favoriteCategoryIndex,
    favoriteCategoryName: favoriteCategoryName,
  );
}

void main() {
  const AiXpEngine engine = AiXpEngine();
  // Fixed clock: 2024-01-01 UTC
  const int nowMs = 1704067200000;
  const int dayMs = 86400000;

  group('AiXpProfile build + serialization', () {
    test('recency-decayed TF-IDF prefers recent tags; saturated tags drop out', () {
      final List<AiGallerySignal> signals = <AiGallerySignal>[
        for (int i = 0; i < 6; i++)
          _sig(
            gid: i + 1,
            // common in every doc -> saturated (6/6 > default 0.85)
            tags: <String>[
              'female:common',
              if (i < 2) 'female:rare_a',
              if (i >= 4) 'female:rare_b',
            ],
            favoritedAtMs: nowMs - (i < 2 ? 1 : 120) * dayMs,
          ),
      ];

      final AiXpProfile profile = engine.buildProfile(signals, nowMs: nowMs);

      expect(profile.version, AiXpProfile.currentVersion);
      expect(profile.signalCount, 6);
      expect(profile.sourceGids, <int>[1, 2, 3, 4, 5, 6]);
      expect(profile.saturatedTags, contains('female:common'));
      expect(profile.tagWeights.containsKey('female:common'), isFalse);
      expect(profile.tagWeights.containsKey('female:rare_a'), isTrue);
      expect(profile.tagWeights.containsKey('female:rare_b'), isTrue);
      // rare_a is more recent than rare_b -> higher weight
      expect(
        profile.tagWeights['female:rare_a']!,
        greaterThan(profile.tagWeights['female:rare_b']!),
      );
    });

    test('JSON round-trip preserves weights, pairs, and source gids', () {
      final List<AiGallerySignal> signals = <AiGallerySignal>[
        _sig(
          gid: 10,
          title: 'Blue Archive Sensei',
          tags: <String>['female:loli', 'parody:blue_archive'],
          favoritedAtMs: nowMs - dayMs,
        ),
        _sig(
          gid: 11,
          title: 'Blue Archive Vol.2',
          tags: <String>['female:loli', 'parody:blue_archive', 'female:maid'],
          favoritedAtMs: nowMs - 2 * dayMs,
        ),
        _sig(
          gid: 12,
          title: 'Other Work',
          tags: <String>['female:maid', 'male:glasses'],
          favoritedAtMs: nowMs - 3 * dayMs,
        ),
        _sig(
          gid: 13,
          title: 'Filler A',
          tags: <String>['misc:noise_a'],
          favoritedAtMs: nowMs - 4 * dayMs,
        ),
        _sig(
          gid: 14,
          title: 'Filler B',
          tags: <String>['misc:noise_b'],
          favoritedAtMs: nowMs - 5 * dayMs,
        ),
      ];

      final AiXpProfile original = engine.buildProfile(signals, nowMs: nowMs);
      expect(original.tagWeights.isNotEmpty, isTrue);
      expect(original.titleWeights.isNotEmpty, isTrue);
      expect(original.tagWeights.containsKey('female:loli'), isTrue);
      // co-occurring loli + blue_archive should yield a positive PMI pair
      expect(
        original.tagPairs.any(
          (AiXpTagPair p) =>
              (p.left == 'female:loli' && p.right == 'parody:blue_archive') ||
              (p.right == 'female:loli' && p.left == 'parody:blue_archive'),
        ),
        isTrue,
      );

      final AiXpProfile restored = AiXpProfile.fromJson(original.toJson());
      expect(restored.version, original.version);
      expect(restored.builtAtMs, original.builtAtMs);
      expect(restored.signalCount, original.signalCount);
      expect(restored.sourceGids, original.sourceGids);
      expect(restored.tagWeights, original.tagWeights);
      expect(restored.titleWeights, original.titleWeights);
      expect(restored.saturatedTags, original.saturatedTags);
      expect(restored.tagPairs.length, original.tagPairs.length);
      for (int i = 0; i < original.tagPairs.length; i++) {
        expect(restored.tagPairs[i].left, original.tagPairs[i].left);
        expect(restored.tagPairs[i].right, original.tagPairs[i].right);
        expect(restored.tagPairs[i].pmi, original.tagPairs[i].pmi);
        expect(restored.tagPairs[i].weight, original.tagPairs[i].weight);
        expect(restored.tagPairs[i].count, original.tagPairs[i].count);
      }
    });

    test('buildProfile is deterministic for fixed nowMs', () {
      final List<AiGallerySignal> signals = <AiGallerySignal>[
        _sig(gid: 1, tags: <String>['female:a', 'female:b'], favoritedAtMs: nowMs),
        _sig(gid: 2, tags: <String>['female:a'], favoritedAtMs: nowMs - dayMs),
        _sig(gid: 3, tags: <String>['female:c'], favoritedAtMs: nowMs - 2 * dayMs),
      ];
      final AiXpProfile a = engine.buildProfile(signals, nowMs: nowMs);
      final AiXpProfile b = engine.buildProfile(signals, nowMs: nowMs);
      expect(a.toJson(), b.toJson());
    });

    test('small homogeneous library (N=2) keeps shared tags and titles', () {
      final AiXpProfile profile = engine.buildProfile(
        <AiGallerySignal>[
          _sig(
            gid: 1,
            title: 'Blue Archive Sensei',
            tags: <String>['female:loli', 'parody:blue_archive'],
            favoritedAtMs: nowMs,
          ),
          _sig(
            gid: 2,
            title: 'Blue Archive Sensei',
            tags: <String>['female:loli', 'parody:blue_archive'],
            favoritedAtMs: nowMs - dayMs,
          ),
        ],
        nowMs: nowMs,
      );

      // N < 5: hard saturation off even when every tag/title is universal.
      expect(profile.isEmpty, isFalse);
      expect(profile.saturatedTags, isEmpty);
      expect(profile.tagWeights.containsKey('female:loli'), isTrue);
      expect(profile.tagWeights.containsKey('parody:blue_archive'), isTrue);
      expect(profile.titleWeights.containsKey('blue'), isTrue);
      expect(profile.titleWeights.containsKey('archive'), isTrue);

      final List<AiXpRankedCandidate> ranked = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(
            gid: 200,
            title: 'Blue Archive Vol.2',
            tags: <String>['female:loli'],
          ),
        ],
        applyUploaderDiversity: false,
      );
      expect(ranked, isNotEmpty);
      expect(ranked.first.signal.gid, 200);
      expect(ranked.first.score, greaterThan(0));
    });

    test('single favorite cold-start keeps tags and titles for ranking', () {
      final AiXpProfile profile = engine.buildProfile(
        <AiGallerySignal>[
          _sig(
            gid: 1,
            title: 'Blue Archive Sensei',
            tags: <String>['female:loli', 'parody:blue_archive'],
            favoritedAtMs: nowMs,
          ),
        ],
        nowMs: nowMs,
      );

      expect(profile.isEmpty, isFalse);
      expect(profile.tagWeights.containsKey('female:loli'), isTrue);
      expect(profile.tagWeights.containsKey('parody:blue_archive'), isTrue);
      expect(profile.titleWeights.containsKey('blue'), isTrue);
      expect(profile.titleWeights.containsKey('archive'), isTrue);
      expect(profile.titleWeights.containsKey('sensei'), isTrue);
      expect(profile.saturatedTags, isEmpty);
      // All finite positive weights (no NaN/Inf from cold-start path).
      for (final double w in profile.tagWeights.values) {
        expect(w.isFinite, isTrue);
        expect(w, greaterThan(0));
      }
      for (final double w in profile.titleWeights.values) {
        expect(w.isFinite, isTrue);
        expect(w, greaterThan(0));
      }

      final List<AiXpRankedCandidate> ranked = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(
            gid: 200,
            title: 'Other Work',
            tags: <String>['female:loli', 'parody:blue_archive'],
          ),
          _sig(
            gid: 201,
            title: 'Unrelated',
            tags: <String>['male:solo'],
          ),
        ],
        applyUploaderDiversity: false,
      );

      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), contains(200));
      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), isNot(contains(201)));
      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), isNot(contains(1)));
      expect(ranked.first.signal.gid, 200);
      expect(ranked.first.score.isFinite, isTrue);
      expect(ranked.first.score, greaterThan(0));
    });

    test('pure title favorite forms profile and drives title-match ranking', () {
      final AiXpProfile profile = engine.buildProfile(
        <AiGallerySignal>[
          _sig(
            gid: 1,
            title: 'Blue Archive Sensei',
            tags: const <String>[],
            favoritedAtMs: nowMs,
          ),
        ],
        nowMs: nowMs,
      );

      expect(profile.isEmpty, isFalse);
      expect(profile.tagWeights, isEmpty);
      expect(profile.titleWeights.containsKey('blue'), isTrue);
      expect(profile.titleWeights.containsKey('archive'), isTrue);
      expect(profile.titleWeights.containsKey('sensei'), isTrue);

      final List<AiXpRankedCandidate> ranked = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(gid: 200, title: 'Blue Archive Vol.2', tags: const <String>[]),
          _sig(gid: 201, title: 'Completely Different Work', tags: const <String>[]),
        ],
        applyUploaderDiversity: false,
      );

      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), contains(200));
      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), isNot(contains(201)));
      expect(ranked.first.signal.gid, 200);
      expect(
        ranked.first.explanations.any((AiXpScoreExplanation e) => e.kind == 'title'),
        isTrue,
      );
      expect(ranked.first.score.isFinite, isTrue);
      expect(ranked.first.score, greaterThan(0));
    });

    test('timeDecayDays <= 0 yields finite weights without NaN or Inf', () {
      final List<AiGallerySignal> signals = <AiGallerySignal>[
        _sig(
          gid: 1,
          title: 'Recent Title',
          tags: <String>['female:loli'],
          favoritedAtMs: nowMs,
        ),
        _sig(
          gid: 2,
          title: 'Older Title',
          tags: <String>['female:maid'],
          favoritedAtMs: nowMs - 30 * dayMs,
        ),
      ];

      for (final int decayDays in <int>[0, -1, -180]) {
        final AiXpEngine noDecay = AiXpEngine(timeDecayDays: decayDays);
        final AiXpProfile profile = noDecay.buildProfile(signals, nowMs: nowMs);

        expect(profile.isEmpty, isFalse, reason: 'timeDecayDays=$decayDays');
        for (final double w in <double>[
          ...profile.tagWeights.values,
          ...profile.titleWeights.values,
        ]) {
          expect(w.isNaN, isFalse, reason: 'timeDecayDays=$decayDays weight=$w');
          expect(w.isInfinite, isFalse, reason: 'timeDecayDays=$decayDays weight=$w');
          expect(w.isFinite, isTrue, reason: 'timeDecayDays=$decayDays weight=$w');
          expect(w, greaterThan(0), reason: 'timeDecayDays=$decayDays weight=$w');
        }
        for (final AiXpTagPair pair in profile.tagPairs) {
          expect(pair.pmi.isFinite, isTrue);
          expect(pair.weight.isFinite, isTrue);
        }

        // Same-age terms get equal decay (factor 1.0); ranking stays usable.
        final List<AiXpRankedCandidate> ranked = noDecay.rankCandidates(
          profile: profile,
          candidates: <AiGallerySignal>[
            _sig(gid: 100, tags: <String>['female:loli']),
            _sig(gid: 101, tags: <String>['female:maid']),
          ],
          applyUploaderDiversity: false,
        );
        expect(ranked, isNotEmpty, reason: 'timeDecayDays=$decayDays');
        for (final AiXpRankedCandidate c in ranked) {
          expect(c.score.isFinite, isTrue, reason: 'timeDecayDays=$decayDays');
          expect(c.score.isNaN, isFalse, reason: 'timeDecayDays=$decayDays');
        }
      }
    });
  });

  group('tokenizeTitle', () {
    test('keeps Latin, CJK, hiragana, katakana, and Hangul runs', () {
      final List<String> tokens = AiXpEngine.tokenizeTitle(
        'Hello 美少女 かわいい カタカナ 한글 Title',
      );
      expect(tokens, containsAll(<String>['hello', 'title']));
      expect(tokens, contains('美少女'));
      expect(tokens, contains('かわいい'));
      expect(tokens, contains('カタカナ'));
      expect(tokens, contains('한글'));
      // single-letter Latin still dropped (len < 2)
      expect(AiXpEngine.tokenizeTitle('A あ 한'), containsAll(<String>['あ', '한']));
      expect(AiXpEngine.tokenizeTitle('A あ 한'), isNot(contains('a')));
    });
  });

  group('rankCandidates', () {
    late AiXpProfile profile;

    setUp(() {
      // Mixed sources; default saturation 0.85 keeps tags below that DF ratio.
      profile = engine.buildProfile(
        <AiGallerySignal>[
          _sig(
            gid: 100,
            title: 'Source One',
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'alice',
            favoritedAtMs: nowMs,
          ),
          _sig(
            gid: 101,
            title: 'Source Two',
            tags: <String>['female:loli', 'female:maid'],
            uploader: 'bob',
            favoritedAtMs: nowMs - dayMs,
          ),
          _sig(
            gid: 102,
            title: 'Source Three',
            tags: <String>['male:glasses'],
            uploader: 'carol',
            favoritedAtMs: nowMs - 2 * dayMs,
          ),
          _sig(
            gid: 103,
            title: 'Source Four',
            tags: <String>['mixed:group'],
            uploader: 'dave',
            favoritedAtMs: nowMs - 3 * dayMs,
          ),
        ],
        nowMs: nowMs,
      );
    });

    test('excludes source gids and ranks matching candidates with explanations', () {
      final List<AiXpRankedCandidate> ranked = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(gid: 100, tags: <String>['female:loli'], uploader: 'alice'), // source
          _sig(
            gid: 200,
            title: 'Candidate Match',
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'carol',
          ),
          _sig(
            gid: 201,
            title: 'Weak Match',
            tags: <String>['female:maid'],
            uploader: 'dave',
          ),
          _sig(
            gid: 202,
            title: 'No Match',
            tags: <String>['male:solo'],
            uploader: 'eve',
          ),
        ],
        applyUploaderDiversity: false,
      );

      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), isNot(contains(100)));
      expect(ranked.map((AiXpRankedCandidate c) => c.signal.gid), isNot(contains(202)));
      expect(ranked.first.signal.gid, 200);
      expect(ranked.first.score, greaterThan(ranked.last.score));
      expect(ranked.first.explanations, isNotEmpty);
      expect(
        ranked.first.explanations.any((AiXpScoreExplanation e) => e.kind == 'tag'),
        isTrue,
      );
    });

    test('uploader diversity decays repeated uploaders', () {
      final List<AiXpRankedCandidate> ranked = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(
            gid: 300,
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'same_uploader',
          ),
          _sig(
            gid: 301,
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'same_uploader',
          ),
          _sig(
            gid: 302,
            tags: <String>['female:loli'],
            uploader: 'other',
          ),
        ],
        applyUploaderDiversity: true,
      );

      expect(ranked.length, 3);
      expect(
        ranked.any(
          (AiXpRankedCandidate c) =>
              c.signal.uploader == 'same_uploader' &&
              c.explanations.any((AiXpScoreExplanation e) => e.kind == 'diversity'),
        ),
        isTrue,
      );

      final List<AiXpRankedCandidate> without = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(
            gid: 300,
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'same_uploader',
          ),
          _sig(
            gid: 301,
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'same_uploader',
          ),
        ],
        applyUploaderDiversity: false,
      );
      final List<AiXpRankedCandidate> withDiv = engine.rankCandidates(
        profile: profile,
        candidates: <AiGallerySignal>[
          _sig(
            gid: 300,
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'same_uploader',
          ),
          _sig(
            gid: 301,
            tags: <String>['female:loli', 'parody:blue_archive'],
            uploader: 'same_uploader',
          ),
        ],
        applyUploaderDiversity: true,
      );
      // Without diversity both scores equal; with diversity second is lower.
      expect(without[0].score, closeTo(without[1].score, 1e-9));
      expect(withDiv[0].score, greaterThan(withDiv[1].score));
    });
  });

  group('groupDuplicates', () {
    test('never groups empty titles and keeps first as keeper', () {
      final List<AiXpDuplicateGroup> groups = engine.groupDuplicates(<AiGallerySignal>[
        _sig(gid: 1, category: 'Doujinshi', title: 'Alpha'),
        _sig(gid: 2, category: 'Doujinshi', title: '  alpha '),
        _sig(gid: 3, category: 'Doujinshi', title: '   '),
        _sig(gid: 4, category: 'Doujinshi', title: ''),
        _sig(gid: 5, category: 'Manga', title: 'Alpha'),
        _sig(gid: 6, category: 'Doujinshi', title: 'Alpha'),
      ]);

      expect(groups.length, 1);
      expect(groups.single.keeperGid, 1);
      expect(groups.single.duplicateGids, <int>[2, 6]);
      expect(groups.single.normalizedTitle, 'alpha');
      // empty titles never appear
      expect(groups.any((AiXpDuplicateGroup g) => g.keeperGid == 3), isFalse);
      expect(groups.any((AiXpDuplicateGroup g) => g.duplicateGids.contains(3)), isFalse);
      expect(groups.any((AiXpDuplicateGroup g) => g.duplicateGids.contains(4)), isFalse);
      // different category is not a duplicate
      expect(groups.any((AiXpDuplicateGroup g) => g.duplicateGids.contains(5)), isFalse);
    });
  });

  group('organizeFavorites', () {
    const List<String> categories = <String>[
      'Favorite 0',
      '本子',
      'CG',
      'Misc Slot',
    ];

    test('parses -> => 放入 归入 and matches names/indexes', () {
      final AiXpOrganizationPlan plan = engine.organizeFavorites(
        requirements: '''
female:loli -> 本子
artist:foo => 0
maid 放入 CG
parody:bar 归入 3
unknown -> missing
''',
        favorites: <AiGallerySignal>[
          _sig(
            gid: 1,
            tags: <String>['female:loli'],
            favoriteCategoryIndex: 0,
            favoriteCategoryName: 'Favorite 0',
          ),
          _sig(
            gid: 2,
            tags: <String>['artist:foo'],
            favoriteCategoryIndex: 2,
            favoriteCategoryName: 'CG',
          ),
          _sig(
            gid: 3,
            title: 'Cute Maid Cafe',
            tags: <String>['female:other'],
            favoriteCategoryIndex: 0,
          ),
          _sig(
            gid: 4,
            tags: <String>['parody:bar'],
            favoriteCategoryIndex: 1,
          ),
          _sig(
            gid: 5,
            tags: <String>['female:loli'],
            favoriteCategoryIndex: 1, // already in 本子
            favoriteCategoryName: '本子',
          ),
        ],
        categoryNames: categories,
      );

      expect(plan.rules.length, 4);
      expect(plan.rules[0].targetIndex, 1);
      expect(plan.rules[0].targetName, '本子');
      expect(plan.rules[1].targetIndex, 0);
      expect(plan.rules[2].targetIndex, 2);
      expect(plan.rules[3].targetIndex, 3);

      final Map<int, AiXpOrganizationMove> byGid = <int, AiXpOrganizationMove>{
        for (final AiXpOrganizationMove m in plan.moves) m.gid: m,
      };
      expect(byGid.keys.toSet(), <int>{1, 2, 3, 4});
      expect(byGid[1]!.targetIndex, 1);
      expect(byGid[2]!.targetIndex, 0);
      expect(byGid[3]!.targetIndex, 2);
      expect(byGid[3]!.matchedTerm.toLowerCase(), contains('maid'));
      expect(byGid[4]!.targetIndex, 3);
      // already in target category: no move
      expect(byGid.containsKey(5), isFalse);
    });
  });

  group('parseSearchIntent', () {
    test('recognizes language, torrent, bounds, category, tags, and xp phrase', () {
      final AiXpSearchIntent intent = engine.parseSearchIntent(
        '中文 doujinshi female:loli artist:"blue archive" with torrent '
        '评分至少4 页数至少20 页数至多100 xp: soft pastel maid',
      );

      expect(intent.language, 'chinese');
      expect(intent.requireTorrent, isTrue);
      expect(intent.minimumRating, 4);
      expect(intent.pageAtLeast, 20);
      expect(intent.pageAtMost, 100);
      expect(intent.categories, contains('Doujinshi'));
      expect(intent.tags, containsAll(<String>['female:loli', 'artist:blue_archive']));
      expect(intent.xpPreference, 'soft pastel maid');
    });

    test('english language, without torrent, and residual xp preference', () {
      final AiXpSearchIntent intent = engine.parseSearchIntent(
        'english manga without torrent min rating 3 at least 10 pages cute fox girl',
      );

      expect(intent.language, 'english');
      expect(intent.requireTorrent, isFalse);
      expect(intent.minimumRating, 3);
      expect(intent.pageAtLeast, 10);
      expect(intent.categories, contains('Manga'));
      expect(intent.xpPreference, isNotNull);
      expect(intent.xpPreference!.toLowerCase(), contains('fox'));
    });

    test('without-torrent wins over with-torrent when both present', () {
      final AiXpSearchIntent intent = engine.parseSearchIntent(
        'with torrent 无种子',
      );
      expect(intent.requireTorrent, isFalse);
    });

    test('language:tag form sets language and is not kept as a tag', () {
      final AiXpSearchIntent intent = engine.parseSearchIntent(
        'language:chinese female:maid',
      );
      expect(intent.language, 'chinese');
      expect(intent.tags, <String>['female:maid']);
    });
  });
}
