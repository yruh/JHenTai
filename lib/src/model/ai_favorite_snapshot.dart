import 'dart:collection';

import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';

/// One lightweight favorite row for persistent snapshot storage.
///
/// Stores ranking signal fields plus gallery identity ([token], [isEH]).
/// Full cover images are intentionally omitted.
class AiFavoriteSnapshotEntry {
  final AiGallerySignal signal;
  final String token;
  final bool isEH;

  const AiFavoriteSnapshotEntry({
    required this.signal,
    required this.token,
    required this.isEH,
  });

  /// Build from a live [Gallery] row without retaining cover bytes/url payload.
  factory AiFavoriteSnapshotEntry.fromGallery(Gallery gallery) {
    return AiFavoriteSnapshotEntry(
      signal: AiGallerySignal(
        gid: gallery.gid,
        title: gallery.title,
        category: gallery.category,
        tags: _tagsToSignalList(gallery.tags),
        uploader: gallery.uploader,
        rating: gallery.rating,
        pageCount: gallery.pageCount,
        language: gallery.language,
        favoriteCategoryIndex: gallery.favoriteTagIndex,
        favoriteCategoryName: gallery.favoriteTagName,
        favoritedAtMs: _parseTimeMs(gallery.publishTime),
        publishedAtMs: null,
      ),
      token: gallery.token,
      isEH: gallery.galleryUrl.isEH,
    );
  }

  /// Reconstruct a minimal [Gallery] sufficient for gid/token/title/category
  /// and favorite-category operations. Cover and tags are empty placeholders.
  Gallery toGallery() {
    final int? timeMs = signal.favoritedAtMs ?? signal.publishedAtMs;
    return Gallery(
      galleryUrl: GalleryUrl(isEH: isEH, gid: signal.gid, token: token),
      title: signal.title,
      category: signal.category,
      cover: GalleryImage(url: ''),
      pageCount: signal.pageCount,
      rating: signal.rating,
      hasRated: false,
      favoriteTagIndex: signal.favoriteCategoryIndex,
      favoriteTagName: signal.favoriteCategoryName,
      language: signal.language,
      uploader: signal.uploader,
      publishTime: timeMs == null ? '' : _formatTimeMs(timeMs),
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'signal': signal.toJson(),
      'token': token,
      'isEH': isEH,
    };
  }

  factory AiFavoriteSnapshotEntry.fromJson(Map<String, dynamic> json) {
    final Object? rawSignal = json['signal'];
    final Map<String, dynamic> signalMap = rawSignal is Map<String, dynamic>
        ? rawSignal
        : Map<String, dynamic>.from(rawSignal as Map);
    return AiFavoriteSnapshotEntry(
      signal: AiGallerySignal.fromJson(signalMap),
      token: json['token'] as String? ?? '',
      isEH: json['isEH'] as bool? ?? true,
    );
  }

  static List<String> _tagsToSignalList(
      LinkedHashMap<String, List<GalleryTag>> tags) {
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
    // Common EH list format: yyyy-MM-dd HH:mm
    final RegExpMatch? m =
        RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$')
            .firstMatch(text);
    if (m != null) {
      return DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6) ?? '0'),
      ).millisecondsSinceEpoch;
    }
    return null;
  }

  static String _formatTimeMs(int ms) {
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// Versioned envelope of lightweight favorite snapshots for one owner.
class AiFavoriteSnapshot {
  static const int currentVersion = 1;

  final int version;
  final String ownerKey;
  final int capturedAtMs;
  final List<AiFavoriteSnapshotEntry> entries;

  const AiFavoriteSnapshot({
    this.version = currentVersion,
    required this.ownerKey,
    required this.capturedAtMs,
    this.entries = const <AiFavoriteSnapshotEntry>[],
  });

  Map<String, dynamic> toJson() {
    // Deterministic order by gid then token for stable persistence hashes.
    final List<AiFavoriteSnapshotEntry> ordered =
        List<AiFavoriteSnapshotEntry>.from(entries)
          ..sort((AiFavoriteSnapshotEntry a, AiFavoriteSnapshotEntry b) {
            final int byGid = a.signal.gid.compareTo(b.signal.gid);
            if (byGid != 0) {
              return byGid;
            }
            return a.token.compareTo(b.token);
          });

    return <String, dynamic>{
      'version': version,
      'ownerKey': ownerKey,
      'capturedAtMs': capturedAtMs,
      'entries':
          ordered.map((AiFavoriteSnapshotEntry e) => e.toJson()).toList(),
    };
  }

  factory AiFavoriteSnapshot.fromJson(Map<String, dynamic> json) {
    final List<AiFavoriteSnapshotEntry> entries = <AiFavoriteSnapshotEntry>[];
    final Object? rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final Object? item in rawEntries) {
        if (item is Map<String, dynamic>) {
          entries.add(AiFavoriteSnapshotEntry.fromJson(item));
        } else if (item is Map) {
          entries.add(AiFavoriteSnapshotEntry.fromJson(
              Map<String, dynamic>.from(item)));
        }
      }
    }

    return AiFavoriteSnapshot(
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      ownerKey: json['ownerKey'] as String? ?? '',
      capturedAtMs: (json['capturedAtMs'] as num?)?.toInt() ?? 0,
      entries: entries,
    );
  }
}
