import 'dart:convert';

import 'package:server_core/server_core.dart';

import '../model/hidden_tag_policy.dart';
import '../model/tag_match.dart';

/// Where a hidden item came from.
class HiddenEntry {
  final String vaultId;
  final String libraryId;
  final String? type;

  const HiddenEntry({
    required this.vaultId,
    required this.libraryId,
    this.type,
  });
}

/// Every item the server holds that the current rules hide, keyed by id.
///
/// Built from one tag query per configured library, so an item is only in it
/// when it really sits in that library. Episodes and seasons are not listed;
/// they are hidden through their series.
class HiddenContentIndex {
  final String fingerprint;
  final DateTime builtAt;
  final Map<String, HiddenEntry> _entries;

  HiddenContentIndex({
    required this.fingerprint,
    required this.builtAt,
    required Map<String, HiddenEntry> entries,
  }) : _entries = Map.unmodifiable(entries);

  HiddenEntry? operator [](String? id) =>
      id == null || id.isEmpty ? null : _entries[id];

  bool contains(String? id) => this[id] != null;

  int get length => _entries.length;

  Iterable<String> get ids => _entries.keys;

  Iterable<MapEntry<String, HiddenEntry>> get entries => _entries.entries;

  /// The ids hidden into [vaultId], optionally only those from [libraryId].
  Iterable<String> idsOf(String vaultId, {String? libraryId}) => _entries
      .entries
      .where(
        (e) =>
            e.value.vaultId == vaultId &&
            (libraryId == null || e.value.libraryId == libraryId),
      )
      .map((e) => e.key);

  bool isStale(DateTime now, Duration maxAge) =>
      now.difference(builtAt) > maxAge;

  /// Grouped per library so the stored form doesn't repeat the vault and
  /// library ids for every item.
  String encode() {
    final groups = <String, List<String>>{};
    for (final entry in _entries.entries) {
      final e = entry.value;
      groups
          .putIfAbsent('${e.vaultId}|${e.libraryId}', () => [])
          .add(e.type == null ? entry.key : '${entry.key}:${e.type}');
    }
    return jsonEncode({
      'v': 1,
      'fp': fingerprint,
      'builtAt': builtAt.millisecondsSinceEpoch,
      'groups': groups,
    });
  }

  static HiddenContentIndex? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final json = jsonDecode(source);
      if (json is! Map || json['v'] != 1) return null;
      final groups = json['groups'];
      if (groups is! Map) return null;
      final entries = <String, HiddenEntry>{};
      groups.forEach((key, value) {
        final parts = key.toString().split('|');
        if (parts.length != 2 || value is! List) return;
        for (final raw in value) {
          final text = raw.toString();
          final colon = text.indexOf(':');
          final id = colon < 0 ? text : text.substring(0, colon);
          final type = colon < 0 ? null : text.substring(colon + 1);
          if (id.isEmpty) continue;
          entries[id] = HiddenEntry(
            vaultId: parts[0],
            libraryId: parts[1],
            type: type,
          );
        }
      });
      final builtAt = json['builtAt'];
      return HiddenContentIndex(
        fingerprint: json['fp']?.toString() ?? '',
        builtAt: DateTime.fromMillisecondsSinceEpoch(
          builtAt is int ? builtAt : 0,
        ),
        entries: entries,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Counts what a build cost, for the performance log and the tests.
class HiddenIndexBuildStats {
  int requests = 0;
  int itemsSeen = 0;
  int itemsRejected = 0;
  Duration elapsed = Duration.zero;

  @override
  String toString() =>
      'requests=$requests seen=$itemsSeen rejected=$itemsRejected '
      'elapsed=${elapsed.inMilliseconds}ms';
}

/// Builds a [HiddenContentIndex] with one tag query per configured library.
///
/// Jellyfin reads several `Tags` as "any of them" (an `Any` over the item's
/// cleaned tag values), so one query per library covers all of its tags. The
/// server compares a cleaned form of each tag, which is looser than exact
/// matching, so every result is checked against its own tags here and
/// anything the server matched too generously is dropped.
class HiddenIndexBuilder {
  static const pageSize = 1000;

  /// A library with more tagged items than this is very unusual; the cap only
  /// stops a misbehaving server from paging forever.
  static const maxPages = 50;

  static const concurrency = 3;

  final ItemsApi _api;

  HiddenIndexBuilder(this._api);

  Future<HiddenContentIndex> build(
    HiddenTagPolicy policy, {
    DateTime? now,
    HiddenIndexBuildStats? stats,
  }) async {
    final started = DateTime.now();
    final entries = <String, HiddenEntry>{};
    final rules = policy.rules.toList();
    var next = 0;

    Future<void> worker() async {
      while (next < rules.length) {
        final rule = rules[next++];
        await _collect(rule, entries, stats);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < rules.length; i++) worker(),
    ]);
    stats?.elapsed = DateTime.now().difference(started);
    return HiddenContentIndex(
      fingerprint: policy.fingerprint,
      builtAt: now ?? DateTime.now(),
      entries: entries,
    );
  }

  Future<void> _collect(
    LibraryRule rule,
    Map<String, HiddenEntry> into,
    HiddenIndexBuildStats? stats,
  ) async {
    final tags = rule.tags.toList()..sort();
    var start = 0;
    for (var page = 0; page < maxPages; page++) {
      final response = await _api.getItems(
        parentId: rule.libraryId,
        recursive: true,
        tags: tags,
        fields: 'Tags',
        sortBy: 'SortName',
        sortOrder: 'Ascending',
        startIndex: start,
        limit: pageSize,
        imageTypeLimit: 0,
        enableTotalRecordCount: true,
      );
      stats?.requests++;
      final items = (response['Items'] as List?) ?? const [];
      for (final raw in items) {
        if (raw is! Map) continue;
        final id = raw['Id']?.toString() ?? '';
        if (id.isEmpty) continue;
        stats?.itemsSeen++;
        final itemTags = extractTags(raw);
        // A server that ignored the field would leave nothing to check
        // against. It already filtered on the tag, so keeping the item is the
        // answer that can't leak.
        if (itemTags != null && !matchesAnyTag(itemTags, rule.tags)) {
          stats?.itemsRejected++;
          continue;
        }
        into[id] = HiddenEntry(
          vaultId: rule.vaultId,
          libraryId: rule.libraryId,
          type: raw['Type']?.toString(),
        );
      }
      start += items.length;
      final total = response['TotalRecordCount'];
      if (items.length < pageSize) break;
      if (total is int && start >= total) break;
    }
  }
}
