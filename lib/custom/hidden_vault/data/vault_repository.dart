import 'dart:async';

import 'package:server_core/server_core.dart';

import '../../../data/models/aggregated_item.dart';
import '../model/tag_match.dart';
import '../model/vault_config.dart';
import 'hidden_content_service.dart';

/// One page of a vault library.
class VaultPage {
  final List<AggregatedItem> items;

  /// How many server items this page consumed, for the next start index.
  final int rawCount;
  final int? totalCount;

  const VaultPage(this.items, {required this.rawCount, this.totalCount});
}

/// The vault context: reads only the hidden content of one vault.
///
/// Library lists ask the server for the vault's tags directly
/// (`ParentId=<library>&Tags=…`), so thousands of ordinary items never travel
/// just to be thrown away, and every result is checked exactly against its
/// own tags before it is shown. Lists that can't filter by tag (resume, next
/// up, episode search) keep only what the hidden index places in this vault.
///
/// Lives as long as the vault's screens do; nothing here is cached beyond it.
class VaultRepository {
  static const fields =
      'DateCreated,Type,UserData,Overview,Genres,CommunityRating,'
      'OfficialRating,RunTimeTicks,ProductionYear,SeriesName,'
      'ParentIndexNumber,IndexNumber,Status,ImageTags,BackdropImageTags,'
      'ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,'
      'ParentThumbImageTag,SeriesId,SeriesPrimaryImageTag,'
      'PrimaryImageAspectRatio,Tags';
  static const _imageTypes = 'Primary,Backdrop,Thumb';
  static const rowLimit = 20;

  final HiddenContentService service;
  final VaultDefinition vault;
  final ItemsApi _api;
  final String serverId;

  final Map<String, Future<Object>> _memo = {};

  /// Requests sent, for tests and the performance log.
  int requestCount = 0;

  VaultRepository({
    required this.service,
    required this.vault,
    required this._api,
    required this.serverId,
  });

  Iterable<VaultLibrary> get libraries =>
      vault.libraries.where((l) => l.hasTags);

  static List<String> typesFor(VaultLibrary library) =>
      switch (library.collectionType) {
        'tvshows' => const ['Series'],
        'movies' => const ['Movie'],
        _ => const ['Series', 'Movie', 'Video'],
      };

  AggregatedItem _item(Map<String, dynamic> raw) => AggregatedItem(
    id: raw['Id']?.toString() ?? '',
    serverId: serverId,
    rawData: raw,
  );

  /// Exactly hidden in [library] by its own tags.
  bool _taggedIn(Map<String, dynamic> raw, VaultLibrary library) {
    final tags = extractTags(raw);
    if (tags == null) return service.belongsToVault(raw, vault.id);
    return matchesAnyTag(tags, library.normalizedTags);
  }

  bool _inVault(Map<String, dynamic> raw) =>
      service.belongsToVault(raw, vault.id);

  static List<Map<String, dynamic>> _items(Map<String, dynamic> response) => [
    for (final item in (response['Items'] as List?) ?? const [])
      if (item is Map) item.cast<String, dynamic>(),
  ];

  Future<T> _cached<T extends Object>(String key, Future<T> Function() load) {
    final existing = _memo[key];
    if (existing != null) return existing.then((value) => value as T);
    final future = load();
    _memo[key] = future;
    // A failed load is forgotten so the next look tries again.
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          _memo.remove(key);
        },
      ),
    );
    return future;
  }

  void clear() => _memo.clear();

  // ---------------------------------------------------------------------------

  Future<VaultPage> libraryPage(
    VaultLibrary library, {
    int startIndex = 0,
    int limit = 48,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    requestCount++;
    final response = await _api.getItems(
      parentId: library.libraryId,
      recursive: true,
      tags: library.normalizedTags.toList()..sort(),
      includeItemTypes: typesFor(library),
      sortBy: sortBy,
      sortOrder: sortOrder,
      startIndex: startIndex,
      limit: limit,
      fields: fields,
      enableImageTypes: _imageTypes,
      imageTypeLimit: 1,
      enableTotalRecordCount: true,
    );
    final raw = _items(response);
    final total = response['TotalRecordCount'];
    return VaultPage(
      [
        for (final item in raw)
          if (_taggedIn(item, library)) _item(item),
      ],
      rawCount: raw.length,
      totalCount: total is int ? total : null,
    );
  }

  /// The first row of a vault library on the vault's home.
  Future<List<AggregatedItem>> libraryRow(VaultLibrary library) => _cached(
    'row:${library.libraryId}',
    () async => (await libraryPage(library, limit: rowLimit)).items,
  );

  Future<List<AggregatedItem>> recentlyAdded() => _cached('recent', () async {
    final lists = await Future.wait([
      for (final library in libraries)
        libraryPage(
          library,
          limit: rowLimit,
          sortBy: library.collectionType == 'tvshows'
              ? 'DateLastContentAdded,DateCreated'
              : 'DateCreated',
          sortOrder: 'Descending',
        ).then((p) => p.items),
    ]);
    final merged = lists.expand((e) => e).toList()
      ..sort((a, b) => _dateOf(b).compareTo(_dateOf(a)));
    return merged.take(rowLimit).toList();
  });

  static String _dateOf(AggregatedItem item) =>
      item.rawData['DateLastContentAdded']?.toString() ??
      item.rawData['DateCreated']?.toString() ??
      '';

  static String _lastPlayed(AggregatedItem item) =>
      (item.rawData['UserData'] as Map?)?['LastPlayedDate']?.toString() ?? '';

  Future<List<AggregatedItem>> continueWatching() =>
      _cached('resume', () async {
        await service.ensureReady();
        final lists = await Future.wait([
          for (final library in libraries)
            _api
                .getResumeItems(
                  parentId: library.libraryId,
                  limit: 60,
                  fields: fields,
                  enableImageTypes: _imageTypes,
                  imageTypeLimit: 1,
                )
                .then(_items),
        ]);
        requestCount += lists.length;
        final items = [
          for (final raw in lists.expand((e) => e))
            if (_inVault(raw)) _item(raw),
        ]..sort((a, b) => _lastPlayed(b).compareTo(_lastPlayed(a)));
        return items.take(rowLimit).toList();
      });

  Future<List<AggregatedItem>> nextUp() => _cached('nextUp', () async {
    await service.ensureReady();
    final shows = libraries.where((l) => l.collectionType != 'movies').toList();
    final lists = await Future.wait([
      for (final library in shows)
        _api
            .getNextUp(
              parentId: library.libraryId,
              limit: 60,
              fields: fields,
              enableImageTypes: _imageTypes,
              imageTypeLimit: 1,
            )
            .then(_items),
    ]);
    requestCount += lists.length;
    return [
      for (final raw in lists.expand((e) => e))
        if (_inVault(raw)) _item(raw),
    ].take(rowLimit).toList();
  });

  /// Titles by tag query, episodes by the index.
  Future<List<AggregatedItem>> search(String query) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    await service.ensureReady();
    final futures = <Future<List<AggregatedItem>>>[];
    for (final library in libraries) {
      futures.add(
        _api
            .getItems(
              parentId: library.libraryId,
              recursive: true,
              searchTerm: term,
              tags: library.normalizedTags.toList()..sort(),
              includeItemTypes: typesFor(library),
              limit: 40,
              fields: fields,
              enableImageTypes: _imageTypes,
              imageTypeLimit: 1,
            )
            .then(
              (r) => [
                for (final raw in _items(r))
                  if (_taggedIn(raw, library)) _item(raw),
              ],
            ),
      );
      if (library.collectionType != 'movies') {
        futures.add(
          _api
              .getItems(
                parentId: library.libraryId,
                recursive: true,
                searchTerm: term,
                includeItemTypes: const ['Episode'],
                limit: 40,
                fields: fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: 1,
              )
              .then(
                (r) => [
                  for (final raw in _items(r))
                    if (_inVault(raw)) _item(raw),
                ],
              ),
        );
      }
    }
    requestCount += futures.length;
    final lists = await Future.wait(futures);
    final seen = <String>{};
    return [
      for (final item in lists.expand((e) => e))
        if (seen.add(item.id)) item,
    ];
  }
}
