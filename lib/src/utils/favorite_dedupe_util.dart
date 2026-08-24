/// Pure helpers for server-side favorite deduplication and batch torrent collection.
///
/// Dedup is intentionally conservative: only category + title, with title
/// normalized for case and whitespace (no punctuation/bracket stripping).
/// Items with an empty normalized category or title are never treated as
/// duplicates (and therefore never deleted).

/// Outcome after a batch torrent collection finishes (post-cancel checks).
///
/// Stats mapping:
/// - [noneFound]: magnetCount == 0 && failureCount == 0 -> `noFavoriteTorrentsFound`
/// - [unavailable]: magnetCount == 0 && failureCount > 0 -> `favoriteTorrentsUnavailable`
/// - [copied]: magnetCount > 0 -> clipboard copy + `favoriteTorrentsCopied`
enum FavoriteTorrentBatchOutcome {
  noneFound,
  unavailable,
  copied,
}

/// Resolve the user-facing result from magnet and failure counts.
FavoriteTorrentBatchOutcome resolveFavoriteTorrentBatchOutcome({
  required int magnetCount,
  required int failureCount,
}) {
  if (magnetCount > 0) {
    return FavoriteTorrentBatchOutcome.copied;
  }
  if (failureCount > 0) {
    return FavoriteTorrentBatchOutcome.unavailable;
  }
  return FavoriteTorrentBatchOutcome.noneFound;
}

/// Named params for the `favoriteTorrentsCopied` i18n key.
Map<String, String> favoriteTorrentsCopiedParams({
  required int galleryCount,
  required int torrentCount,
  required int failedCount,
}) {
  return <String, String>{
    'galleryCount': galleryCount.toString(),
    'torrentCount': torrentCount.toString(),
    'failedCount': failedCount.toString(),
  };
}

/// Named params for the `favoriteTorrentsUnavailable` i18n key.
Map<String, String> favoriteTorrentsUnavailableParams({
  required int failedCount,
}) {
  return <String, String>{
    'failedCount': failedCount.toString(),
  };
}

/// Collapse surrounding/internal whitespace and lower-case [title].
String normalizeFavoriteTitle(String title) {
  return title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

/// Normalized category used in dedupe keys (trim + lower-case).
String normalizeFavoriteCategory(String category) {
  return category.trim().toLowerCase();
}

/// Build a stable dedupe key from gallery [category] and [title].
///
/// Returns `null` when the normalized category or title is empty - callers
/// must skip such items so they are never deleted.
String? buildFavoriteDedupeKey({required String category, required String title}) {
  final String normalizedCategory = normalizeFavoriteCategory(category);
  final String normalizedTitle = normalizeFavoriteTitle(title);
  if (normalizedCategory.isEmpty || normalizedTitle.isEmpty) {
    return null;
  }
  return '$normalizedCategory\u0000$normalizedTitle';
}

/// Return items that are duplicates of an earlier item in [items] (server order).
///
/// The first occurrence of each key is kept; subsequent matches are returned
/// as duplicates to delete. Items with empty normalized category or title are
/// skipped entirely and never appear in the result.
List<T> findFavoriteDuplicates<T>({
  required List<T> items,
  required String Function(T item) categoryOf,
  required String Function(T item) titleOf,
}) {
  final Set<String> seenKeys = <String>{};
  final List<T> duplicates = <T>[];

  for (final T item in items) {
    final String? key = buildFavoriteDedupeKey(
      category: categoryOf(item),
      title: titleOf(item),
    );
    if (key == null) {
      // Empty category/title after normalization - never delete.
      continue;
    }
    if (!seenKeys.add(key)) {
      duplicates.add(item);
    }
  }

  return duplicates;
}

/// Reconcile one gdata chunk: match response rows to [requested] by gid.
///
/// - Response gids that were not requested are ignored.
/// - Duplicate response rows for the same requested gid use the first row only.
/// - Each requested item whose gid is absent from the response counts as one
///   failure ([missingCount]).
/// - Items with `torrentCount > 0` are returned as [withTorrents] **in request
///   order**, preserving the original request objects (gid/token source).
({List<T> withTorrents, int missingCount}) reconcileFavoriteMetadataChunk<T>({
  required List<T> requested,
  required int Function(T item) gidOf,
  required Iterable<({int gid, int torrentCount})> responseItems,
}) {
  final Set<int> requestedGids = <int>{for (final T item in requested) gidOf(item)};
  final Map<int, int> torrentCountByGid = <int, int>{};

  for (final ({int gid, int torrentCount}) row in responseItems) {
    if (!requestedGids.contains(row.gid)) {
      continue;
    }
    // First response row wins; later duplicates for the same gid are ignored.
    torrentCountByGid.putIfAbsent(row.gid, () => row.torrentCount);
  }

  final List<T> withTorrents = <T>[];
  int missingCount = 0;
  final Set<int> accountedGids = <int>{};

  for (final T item in requested) {
    final int gid = gidOf(item);
    // Request list is expected unique; skip accidental duplicate request rows.
    if (!accountedGids.add(gid)) {
      continue;
    }
    final int? torrentCount = torrentCountByGid[gid];
    if (torrentCount == null) {
      missingCount++;
      continue;
    }
    if (torrentCount > 0) {
      withTorrents.add(item);
    }
  }

  return (withTorrents: withTorrents, missingCount: missingCount);
}

/// Collect unique non-outdated magnet URLs, preserving first-seen order.
List<String> collectUniqueNonOutdatedMagnets({
  required Iterable<({String magnetUrl, bool outdated})> torrents,
}) {
  final Set<String> seen = <String>{};
  final List<String> magnets = <String>[];

  for (final ({String magnetUrl, bool outdated}) torrent in torrents) {
    if (torrent.outdated) {
      continue;
    }
    final String magnet = torrent.magnetUrl.trim();
    if (magnet.isEmpty) {
      continue;
    }
    if (seen.add(magnet)) {
      magnets.add(magnet);
    }
  }

  return magnets;
}

/// Split [items] into chunks of at most [size] (size must be > 0).
List<List<T>> chunkList<T>(List<T> items, int size) {
  assert(size > 0);
  if (items.isEmpty) {
    return const [];
  }
  final List<List<T>> chunks = <List<T>>[];
  for (int i = 0; i < items.length; i += size) {
    final int end = i + size > items.length ? items.length : i + size;
    chunks.add(items.sublist(i, end));
  }
  return chunks;
}

/// Run [action] over [items] with at most [concurrency] in-flight tasks.
///
/// When [isCancelled] becomes true, no new tasks are started; in-flight tasks
/// are still awaited. [onProgress] is invoked after each item finishes
/// (success or error). [completedOffset] includes items resolved before this
/// batch in both the completed and total values reported to [onProgress].
Future<void> runWithConcurrency<T>({
  required List<T> items,
  required int concurrency,
  required Future<void> Function(T item) action,
  required bool Function() isCancelled,
  int completedOffset = 0,
  void Function(int completed, int total)? onProgress,
}) async {
  assert(completedOffset >= 0);
  if (items.isEmpty) {
    return;
  }

  final int itemCount = items.length;
  final int total = completedOffset + itemCount;
  final int effectiveConcurrency =
      concurrency < 1 ? 1 : (concurrency > itemCount ? itemCount : concurrency);
  int nextIndex = 0;
  int completed = completedOffset;

  Future<void> worker() async {
    while (true) {
      // Check + claim is synchronous, so cancel set during another task's await
      // is observed before any new request starts (in-flight tasks still finish).
      if (isCancelled()) {
        return;
      }
      if (nextIndex >= itemCount) {
        return;
      }
      final int index = nextIndex++;
      try {
        await action(items[index]);
      } finally {
        completed++;
        onProgress?.call(completed, total);
      }
    }
  }

  await Future.wait(List<Future<void>>.generate(effectiveConcurrency, (_) => worker()));
}
