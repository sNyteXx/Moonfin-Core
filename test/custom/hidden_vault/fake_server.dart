import 'package:server_core/server_core.dart';

/// One recorded API call.
class FakeCall {
  final String method;
  final Map<String, Object?> params;

  FakeCall(this.method, this.params);

  @override
  String toString() => '$method$params';
}

/// A small in-memory Jellyfin that behaves like the real one where the vault
/// depends on it:
///
/// * `Tags` matches any of the given tags against a cleaned form (lower case,
///   punctuation turned into spaces), like `GetCleanValue` in Jellyfin 12.
/// * Tags only come back when `Fields` asks for them.
/// * `Ids` combined with `ParentId` + `Recursive` intersects.
/// * Start index / limit paging with `TotalRecordCount`.
///
/// Every call is recorded so tests can count requests.
class FakeJellyfin implements ItemsApi {
  final Map<String, Map<String, dynamic>> _items = {};

  /// Library id per item id.
  final Map<String, String> libraryOf = {};

  final List<FakeCall> calls = [];

  int count(String method) => calls.where((c) => c.method == method).length;

  /// Items sent back across all list responses, i.e. the payload size.
  int transferred = 0;

  void resetCalls() {
    calls.clear();
    transferred = 0;
  }

  /// Item ids in insertion order, which is also the default sort.
  final List<String> _order = [];

  void add(
    String libraryId,
    Map<String, dynamic> item, {
    bool nextUp = false,
    bool resume = false,
  }) {
    final id = item['Id'] as String;
    _items[id] = {
      ...item,
      if (nextUp) '_nextUp': true,
      if (resume) '_resume': true,
    };
    libraryOf[id] = libraryId;
    _order.add(id);
  }

  Map<String, dynamic> series(
    String libraryId,
    String id, {
    List<String> tags = const [],
    String? name,
    String created = '2024-01-01',
  }) {
    final item = {
      'Id': id,
      'Name': name ?? id,
      'Type': 'Series',
      'Tags': tags,
      'DateCreated': created,
      'ParentId': 'folder-$libraryId',
    };
    add(libraryId, item);
    return item;
  }

  Map<String, dynamic> movie(
    String libraryId,
    String id, {
    List<String> tags = const [],
    String? name,
    String created = '2024-01-01',
    bool resume = false,
  }) {
    final item = {
      'Id': id,
      'Name': name ?? id,
      'Type': 'Movie',
      'Tags': tags,
      'DateCreated': created,
      'ParentId': 'folder-$libraryId',
    };
    add(libraryId, item, resume: resume);
    return item;
  }

  Map<String, dynamic> episode(
    String libraryId,
    String id, {
    required String seriesId,
    String? seasonId,
    List<String> tags = const [],
    bool nextUp = false,
    bool resume = false,
  }) {
    final season = seasonId ?? '$seriesId-s1';
    final item = {
      'Id': id,
      'Name': id,
      'Type': 'Episode',
      'Tags': tags,
      'SeriesId': seriesId,
      'SeasonId': season,
      'ParentId': season,
      'SeriesName': seriesId,
      'DateCreated': '2024-02-01',
    };
    add(libraryId, item, nextUp: nextUp, resume: resume);
    return item;
  }

  static String _clean(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Map<String, dynamic> _out(Map<String, dynamic> item, String? fields) {
    final wantsTags =
        fields != null &&
        fields.split(',').map((f) => f.trim()).contains('Tags');
    return {
      for (final e in item.entries)
        if (!e.key.startsWith('_') && (e.key != 'Tags' || wantsTags))
          e.key: e.value,
    };
  }

  Map<String, dynamic> _page(
    List<Map<String, dynamic>> all,
    int? startIndex,
    int? limit,
    String? fields,
  ) {
    final start = startIndex ?? 0;
    final slice = all.skip(start).take(limit ?? all.length).toList();
    transferred += slice.length;
    return {
      'Items': [for (final item in slice) _out(item, fields)],
      'TotalRecordCount': all.length,
      'StartIndex': start,
    };
  }

  Iterable<Map<String, dynamic>> get _all => _order.map((id) => _items[id]!);

  @override
  Future<Map<String, dynamic>> getItems({
    bool? serverWide,
    String? parentId,
    List<String>? ids,
    List<String>? includeItemTypes,
    List<String>? excludeItemTypes,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? searchTerm,
    String? fields,
    List<String>? personIds,
    List<String>? artistIds,
    List<String>? filters,
    List<String>? seriesStatus,
    String? nameStartsWith,
    String? nameLessThan,
    List<String>? genreIds,
    List<String>? genres,
    bool? isFavorite,
    bool? collapseBoxSetItems,
    bool? enableTotalRecordCount,
    String? enableImageTypes,
    int? imageTypeLimit,
    List<String>? tags,
    List<String>? studios,
    DateTime? minPremiereDate,
    String? maxOfficialRating,
    bool? hasParentalRating,
    String? anyProviderIdEquals,
    List<String>? officialRatings,
    List<int>? years,
    List<String>? videoTypes,
    List<String>? audioLanguages,
    List<String>? subtitleLanguages,
    bool? hasSubtitles,
    bool? hasTrailer,
    bool? hasSpecialFeature,
    bool? hasThemeSong,
    bool? hasThemeVideo,
    bool? isHd,
    bool? is4K,
    bool? is3D,
  }) async {
    calls.add(
      FakeCall('getItems', {
        'parentId': parentId,
        'ids': ids,
        'tags': tags,
        'startIndex': startIndex,
        'limit': limit,
        'fields': fields,
        'searchTerm': searchTerm,
        'includeItemTypes': includeItemTypes,
      }),
    );
    Iterable<Map<String, dynamic>> result = _all;
    if (ids != null && ids.isNotEmpty) {
      final wanted = ids.toSet();
      result = result.where((i) => wanted.contains(i['Id']));
    }
    if (parentId != null) {
      result = result.where((i) {
        if (recursive == true || ids != null) {
          return libraryOf[i['Id']] == parentId ||
              i['SeriesId'] == parentId ||
              i['SeasonId'] == parentId;
        }
        return libraryOf[i['Id']] == parentId &&
                (i['Type'] == 'Series' || i['Type'] == 'Movie') ||
            i['ParentId'] == parentId;
      });
    }
    if (includeItemTypes != null && includeItemTypes.isNotEmpty) {
      result = result.where((i) => includeItemTypes.contains(i['Type']));
    }
    if (isFavorite == true) {
      result = result.where((i) => i['IsFavorite'] == true);
    }
    if (personIds != null && personIds.isNotEmpty) {
      result = result.where(
        (i) => (i['_people'] as List? ?? const []).any(personIds.contains),
      );
    }
    if (tags != null && tags.isNotEmpty) {
      final wanted = tags.map(_clean).toSet();
      result = result.where(
        (i) => (i['Tags'] as List? ?? const []).any(
          (t) => wanted.contains(_clean(t.toString())),
        ),
      );
    }
    if (searchTerm != null && searchTerm.isNotEmpty) {
      final term = searchTerm.toLowerCase();
      result = result.where(
        (i) => i['Name'].toString().toLowerCase().contains(term),
      );
    }
    final list = result.toList();
    if (sortBy == 'DateCreated' ||
        sortBy?.startsWith('DateLastContentAdded') == true) {
      list.sort(
        (a, b) =>
            b['DateCreated'].toString().compareTo(a['DateCreated'].toString()),
      );
    }
    return _page(list, startIndex, limit, fields);
  }

  @override
  Future<Map<String, dynamic>> getItem(
    String itemId, {
    String? mediaSourceId,
    String? fields,
  }) async {
    calls.add(FakeCall('getItem', {'id': itemId, 'fields': fields}));
    final item = _items[itemId];
    if (item == null) throw StateError('not found $itemId');
    return _out(item, fields);
  }

  @override
  Future<Map<String, dynamic>> getNextUp({
    String? seriesId,
    String? parentId,
    int? startIndex,
    int? limit,
    String? fields,
    bool? enableResumable,
    DateTime? nextUpDateCutoff,
    String? enableImageTypes,
    int? imageTypeLimit,
  }) async {
    calls.add(
      FakeCall('getNextUp', {
        'seriesId': seriesId,
        'parentId': parentId,
        'startIndex': startIndex,
        'limit': limit,
      }),
    );
    final list = _all
        .where((i) => i['_nextUp'] == true)
        .where((i) => seriesId == null || i['SeriesId'] == seriesId)
        .where((i) => parentId == null || libraryOf[i['Id']] == parentId)
        .toList();
    return _page(list, startIndex, limit, fields);
  }

  @override
  Future<Map<String, dynamic>> getResumeItems({
    String? parentId,
    List<String>? includeItemTypes,
    String? mediaTypes,
    int? startIndex,
    int? limit,
    String? fields,
    String? enableImageTypes,
    int? imageTypeLimit,
  }) async {
    calls.add(
      FakeCall('getResumeItems', {
        'parentId': parentId,
        'startIndex': startIndex,
        'limit': limit,
      }),
    );
    final list = _all
        .where((i) => i['_resume'] == true)
        .where((i) => parentId == null || libraryOf[i['Id']] == parentId)
        .toList();
    return _page(list, startIndex, limit, fields);
  }

  @override
  Future<Map<String, dynamic>> getLatestItems({
    String? parentId,
    List<String>? includeItemTypes,
    int? limit,
    String? fields,
    String? enableImageTypes,
    int? imageTypeLimit,
  }) async {
    calls.add(
      FakeCall('getLatestItems', {'parentId': parentId, 'limit': limit}),
    );
    final list =
        _all
            .where((i) => i['Type'] == 'Series' || i['Type'] == 'Movie')
            .where((i) => parentId == null || libraryOf[i['Id']] == parentId)
            .toList()
          ..sort(
            (a, b) => b['DateCreated'].toString().compareTo(
              a['DateCreated'].toString(),
            ),
          );
    final page = _page(list, 0, limit, fields);
    return page;
  }

  @override
  Future<Map<String, dynamic>> getRecentlyReleasedItems({
    String? parentId,
    List<String>? includeItemTypes,
    int? limit,
    String? fields,
    String? enableImageTypes,
    int? imageTypeLimit,
    bool recursive = false,
  }) async {
    calls.add(FakeCall('getRecentlyReleasedItems', {'parentId': parentId}));
    final list = _all
        .where((i) => i['Type'] == 'Series' || i['Type'] == 'Movie')
        .where((i) => parentId == null || libraryOf[i['Id']] == parentId)
        .toList();
    return _page(list, 0, limit, fields);
  }

  @override
  Future<Map<String, dynamic>> getSimilarItems(
    String itemId, {
    int? limit,
    String? bypass,
  }) async {
    calls.add(FakeCall('getSimilarItems', {'id': itemId, 'limit': limit}));
    final type = _items[itemId]?['Type'];
    final list = _all
        .where((i) => i['Type'] == type && i['Id'] != itemId)
        .toList();
    return _page(list, 0, limit, null);
  }

  @override
  Future<Map<String, dynamic>> getEpisodes(
    String seriesId, {
    String? seasonId,
    String? fields,
  }) async {
    calls.add(FakeCall('getEpisodes', {'seriesId': seriesId}));
    final list = _all
        .where((i) => i['Type'] == 'Episode' && i['SeriesId'] == seriesId)
        .where((i) => seasonId == null || i['SeasonId'] == seasonId)
        .toList();
    return _page(list, null, null, fields);
  }

  @override
  Future<Map<String, dynamic>> getSeasons(
    String seriesId, {
    String? fields,
  }) async {
    calls.add(FakeCall('getSeasons', {'seriesId': seriesId}));
    final seasons = <String>{
      for (final i in _all)
        if (i['SeriesId'] == seriesId && i['SeasonId'] != null)
          i['SeasonId'] as String,
    };
    return {
      'Items': [
        for (final s in seasons)
          {
            'Id': s,
            'Type': 'Season',
            'SeriesId': seriesId,
            'ParentId': seriesId,
          },
      ],
      'TotalRecordCount': seasons.length,
    };
  }

  @override
  Future<QueryFilterValues> getQueryFilters({
    String? parentId,
    List<String>? includeItemTypes,
  }) async {
    calls.add(FakeCall('getQueryFilters', {'parentId': parentId}));
    final tags = <String>{};
    for (final item in _all) {
      if (parentId != null && libraryOf[item['Id']] != parentId) continue;
      for (final t in (item['Tags'] as List? ?? const [])) {
        tags.add(t.toString());
      }
    }
    return QueryFilterValues(tags: tags.toList()..sort());
  }

  @override
  Future<List<Map<String, dynamic>>> getSpecialFeatures(String itemId) async {
    calls.add(FakeCall('getSpecialFeatures', {'id': itemId}));
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
