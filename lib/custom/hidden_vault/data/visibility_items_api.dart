import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

import '../model/tag_match.dart';
import 'hidden_content_service.dart';
import 'virtual_pager.dart';

/// What a [VisibilityItemsApi] needs to know about the moment it's called in.
abstract class VisibilityContext {
  /// The rules for the account this client is signed in as, or null when
  /// there are none (the API then passes everything straight through).
  HiddenContentService? get service;

  /// The vaults that are unlocked and currently open for this account. Only
  /// item specific calls ever look at it.
  Set<String> get enteredVaults;

  /// Something of [vaultId] was just let through, which keeps it open.
  void noteVaultActivity(String vaultId);
}

/// The answer to opening a hidden item outside its vault: indistinguishable
/// from an item that doesn't exist.
class HiddenContentRefusal extends DioException {
  HiddenContentRefusal(String itemId)
    : super(
        requestOptions: RequestOptions(path: '/Items/$itemId'),
        response: Response(
          requestOptions: RequestOptions(path: '/Items/$itemId'),
          statusCode: 404,
        ),
        type: DioExceptionType.badResponse,
        message: 'Item not found',
      );
}

bool isHiddenContentRefusal(Object? error) => error is HiddenContentRefusal;

/// Wraps an [ItemsApi] so the normal app never sees hidden content.
///
/// Every list the app reads goes through here, which is what makes this the
/// one place hidden content is kept out: home rows, next up, resume, latest,
/// search, library grids, genres, favorites, collections, similar items,
/// filmographies, the screensaver, launcher channels, shuffle, car browse and
/// playback queues alike. Lists keep their paging (see [VirtualPager]).
///
/// Global lists never make exceptions. Only calls about one particular item
/// (the item itself, its seasons, episodes, extras, similar items) let a
/// vault's own items through, and only while that vault is unlocked and open.
///
/// With no rules configured every call goes straight to the wrapped API.
class VisibilityItemsApi implements ItemsApi {
  final ItemsApi _inner;
  final VisibilityContext _context;
  final VirtualPager _pager = VirtualPager();

  /// What the wrapped API asks for when a single item fetch names no fields,
  /// when that is known (Jellyfin). Lets the item's own tags come along so
  /// opening it costs no extra lookup.
  final String? _defaultItemFields;

  VisibilityItemsApi(
    this._inner,
    this._context, {
    this._defaultItemFields,
  });

  /// The wrapped API, for the vault's own queries and the settings screen.
  ItemsApi get unfiltered => _inner;

  /// Requests the read-ahead sent, for tests and the performance log.
  int get pagerRequests => _pager.requestCount;

  HiddenContentService? get _service {
    final service = _context.service;
    return service != null && service.isActive ? service : null;
  }

  static String? _withTags(String? fields) {
    if (fields == null || fields.trim().isEmpty) return 'Tags';
    final parts = fields.split(',').map((f) => f.trim());
    if (parts.contains('Tags')) return fields;
    return '$fields,Tags';
  }

  static String _signature(String method, Map<String, Object?> params, int gen) {
    final sorted = Map.fromEntries(
      params.entries.where((e) => e.value != null).toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    return '$method#$gen#${jsonEncode(sorted, toEncodable: (o) => o.toString())}';
  }

  bool _allowed(Set<String> entered, String vaultId) {
    if (!entered.contains(vaultId)) return false;
    _context.noteVaultActivity(vaultId);
    return true;
  }

  VaultAllowance? _anyEnteredVault() {
    final entered = _context.enteredVaults;
    if (entered.isEmpty) return null;
    return (_, vaultId) => _allowed(entered, vaultId);
  }

  VaultAllowance? _childrenOf(String anchorId, HiddenContentService service) {
    if (service.isRuleLibrary(anchorId)) return null;
    final entered = _context.enteredVaults;
    if (entered.isEmpty) return null;
    // Only the seasons and episodes of the item asked about. A folder or a
    // collection holding vault titles is not one of them.
    return (raw, vaultId) =>
        (raw['SeriesId']?.toString() == anchorId ||
            raw['SeasonId']?.toString() == anchorId) &&
        _allowed(entered, vaultId);
  }

  Future<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>)
  _visibleOf(HiddenContentService service, VaultAllowance? allow) =>
      (raw) => service.visible(raw, allow: allow);

  Future<Map<String, dynamic>> _filterAll(
    HiddenContentService service,
    Future<Map<String, dynamic>> Function() fetch, {
    VaultAllowance? allow,
  }) async {
    await service.ensureReady();
    return _pager.page(
      signature: '',
      startIndex: null,
      limit: null,
      paged: false,
      fetch: (_, _) => fetch(),
      visibleOf: _visibleOf(service, allow),
    );
  }

  Future<List<Map<String, dynamic>>> _filterList(
    HiddenContentService service,
    Future<List<Map<String, dynamic>>> Function() fetch, {
    VaultAllowance? allow,
  }) async {
    await service.ensureReady();
    final items = await fetch();
    return service.visible(items, allow: allow);
  }

  /// One item, refused outright when hidden outside its open vault.
  Future<Map<String, dynamic>> _guardItem(
    HiddenContentService service,
    String itemId,
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    await service.ensureReady();
    final data = await fetch();
    final verdict = (await service.settle([data])).single;
    if (!verdict.isHidden) return data;
    final vaultId = verdict.vaultId;
    if (vaultId != null && _allowed(_context.enteredVaults, vaultId)) {
      return data;
    }
    throw HiddenContentRefusal(itemId);
  }

  // ---------------------------------------------------------------------------
  // Lists
  // ---------------------------------------------------------------------------

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
    final service = _service;
    final effectiveFields = service == null ? fields : _withTags(fields);
    Future<Map<String, dynamic>> call(int? start, int? lim) => _inner.getItems(
      serverWide: serverWide,
      parentId: parentId,
      ids: ids,
      includeItemTypes: includeItemTypes,
      excludeItemTypes: excludeItemTypes,
      sortBy: sortBy,
      sortOrder: sortOrder,
      startIndex: start,
      limit: lim,
      recursive: recursive,
      searchTerm: searchTerm,
      fields: effectiveFields,
      personIds: personIds,
      artistIds: artistIds,
      filters: filters,
      seriesStatus: seriesStatus,
      nameStartsWith: nameStartsWith,
      nameLessThan: nameLessThan,
      genreIds: genreIds,
      genres: genres,
      isFavorite: isFavorite,
      collapseBoxSetItems: collapseBoxSetItems,
      enableTotalRecordCount: enableTotalRecordCount,
      enableImageTypes: enableImageTypes,
      imageTypeLimit: imageTypeLimit,
      tags: tags,
      studios: studios,
      minPremiereDate: minPremiereDate,
      maxOfficialRating: maxOfficialRating,
      hasParentalRating: hasParentalRating,
      anyProviderIdEquals: anyProviderIdEquals,
      officialRatings: officialRatings,
      years: years,
      videoTypes: videoTypes,
      audioLanguages: audioLanguages,
      subtitleLanguages: subtitleLanguages,
      hasSubtitles: hasSubtitles,
      hasTrailer: hasTrailer,
      hasSpecialFeature: hasSpecialFeature,
      hasThemeSong: hasThemeSong,
      hasThemeVideo: hasThemeVideo,
      isHd: isHd,
      is4K: is4K,
      is3D: is3D,
    );
    if (service == null) return call(startIndex, limit);

    await service.ensureReady();
    final VaultAllowance? allow;
    if (ids != null && ids.isNotEmpty) {
      allow = _anyEnteredVault();
    } else if (parentId != null && parentId.isNotEmpty) {
      allow = _childrenOf(parentId, service);
    } else {
      allow = null;
    }
    final signature = _signature('getItems', {
      'serverWide': serverWide,
      'parentId': parentId,
      'ids': ids,
      'includeItemTypes': includeItemTypes,
      'excludeItemTypes': excludeItemTypes,
      'sortBy': sortBy,
      'sortOrder': sortOrder,
      'recursive': recursive,
      'searchTerm': searchTerm,
      'personIds': personIds,
      'artistIds': artistIds,
      'filters': filters,
      'seriesStatus': seriesStatus,
      'nameStartsWith': nameStartsWith,
      'nameLessThan': nameLessThan,
      'genreIds': genreIds,
      'genres': genres,
      'isFavorite': isFavorite,
      'collapseBoxSetItems': collapseBoxSetItems,
      'tags': tags,
      'studios': studios,
      'minPremiereDate': minPremiereDate,
      'maxOfficialRating': maxOfficialRating,
      'hasParentalRating': hasParentalRating,
      'anyProviderIdEquals': anyProviderIdEquals,
      'officialRatings': officialRatings,
      'years': years,
      'videoTypes': videoTypes,
      'audioLanguages': audioLanguages,
      'subtitleLanguages': subtitleLanguages,
      'hasSubtitles': hasSubtitles,
      'hasTrailer': hasTrailer,
      'hasSpecialFeature': hasSpecialFeature,
      'hasThemeSong': hasThemeSong,
      'hasThemeVideo': hasThemeVideo,
      'isHd': isHd,
      'is4K': is4K,
      'is3D': is3D,
      'allow': _context.enteredVaults.join(','),
    }, service.generation);
    return _pager.page(
      signature: signature,
      startIndex: startIndex,
      limit: (ids != null && ids.isNotEmpty) ? null : limit,
      paged: true,
      fetch: (start, lim) =>
          call(start, (ids != null && ids.isNotEmpty) ? limit : lim),
      visibleOf: _visibleOf(service, allow),
    );
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
    final service = _service;
    Future<Map<String, dynamic>> call(int? start, int? lim) => _inner.getNextUp(
      seriesId: seriesId,
      parentId: parentId,
      startIndex: start,
      limit: lim,
      fields: fields,
      enableResumable: enableResumable,
      nextUpDateCutoff: nextUpDateCutoff,
      enableImageTypes: enableImageTypes,
      imageTypeLimit: imageTypeLimit,
    );
    if (service == null) return call(startIndex, limit);
    await service.ensureReady();
    final allow = (seriesId != null && seriesId.isNotEmpty)
        ? _childrenOf(seriesId, service)
        : null;
    return _pager.page(
      signature: _signature('getNextUp', {
        'seriesId': seriesId,
        'parentId': parentId,
        'enableResumable': enableResumable,
        'cutoff': nextUpDateCutoff?.toIso8601String(),
        'allow': _context.enteredVaults.join(','),
      }, service.generation),
      startIndex: startIndex,
      limit: limit,
      paged: true,
      fetch: call,
      visibleOf: _visibleOf(service, allow),
    );
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
    final service = _service;
    final effectiveFields = service == null ? fields : _withTags(fields);
    Future<Map<String, dynamic>> call(int? start, int? lim) =>
        _inner.getResumeItems(
          parentId: parentId,
          includeItemTypes: includeItemTypes,
          mediaTypes: mediaTypes,
          startIndex: start,
          limit: lim,
          fields: effectiveFields,
          enableImageTypes: enableImageTypes,
          imageTypeLimit: imageTypeLimit,
        );
    if (service == null) return call(startIndex, limit);
    await service.ensureReady();
    return _pager.page(
      signature: _signature('getResumeItems', {
        'parentId': parentId,
        'includeItemTypes': includeItemTypes,
        'mediaTypes': mediaTypes,
      }, service.generation),
      startIndex: startIndex,
      limit: limit,
      paged: true,
      fetch: call,
      visibleOf: _visibleOf(service, null),
    );
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
    final service = _service;
    final effectiveFields = service == null ? fields : _withTags(fields);
    Future<Map<String, dynamic>> call(int? start, int? lim) =>
        _inner.getLatestItems(
          parentId: parentId,
          includeItemTypes: includeItemTypes,
          limit: lim,
          fields: effectiveFields,
          enableImageTypes: enableImageTypes,
          imageTypeLimit: imageTypeLimit,
        );
    if (service == null) return call(null, limit);
    await service.ensureReady();
    return _pager.page(
      signature: 'getLatestItems',
      startIndex: null,
      limit: limit,
      paged: false,
      fetch: call,
      visibleOf: _visibleOf(service, null),
    );
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
    final service = _service;
    final effectiveFields = service == null ? fields : _withTags(fields);
    Future<Map<String, dynamic>> call(int? start, int? lim) =>
        _inner.getRecentlyReleasedItems(
          parentId: parentId,
          includeItemTypes: includeItemTypes,
          limit: lim,
          fields: effectiveFields,
          enableImageTypes: enableImageTypes,
          imageTypeLimit: imageTypeLimit,
          recursive: recursive,
        );
    if (service == null) return call(null, limit);
    await service.ensureReady();
    return _pager.page(
      signature: 'getRecentlyReleasedItems',
      startIndex: null,
      limit: limit,
      paged: false,
      fetch: call,
      visibleOf: _visibleOf(service, null),
    );
  }

  @override
  Future<Map<String, dynamic>> getSimilarItems(
    String itemId, {
    int? limit,
    String? bypass,
  }) async {
    final service = _service;
    Future<Map<String, dynamic>> call(int? start, int? lim) =>
        _inner.getSimilarItems(itemId, limit: lim, bypass: bypass);
    if (service == null) return call(null, limit);
    await service.ensureReady();
    return _pager.page(
      signature: 'getSimilarItems',
      startIndex: null,
      limit: limit,
      paged: false,
      fetch: call,
      visibleOf: _visibleOf(service, _anyEnteredVault()),
    );
  }

  @override
  Future<Map<String, dynamic>> getSeasons(String seriesId, {String? fields}) {
    final service = _service;
    if (service == null) return _inner.getSeasons(seriesId, fields: fields);
    return _filterAll(
      service,
      () => _inner.getSeasons(seriesId, fields: fields),
      allow: _childrenOf(seriesId, service),
    );
  }

  @override
  Future<Map<String, dynamic>> getEpisodes(
    String seriesId, {
    String? seasonId,
    String? fields,
  }) {
    final service = _service;
    if (service == null) {
      return _inner.getEpisodes(seriesId, seasonId: seasonId, fields: fields);
    }
    return _filterAll(
      service,
      () => _inner.getEpisodes(seriesId, seasonId: seasonId, fields: fields),
      allow: _childrenOf(seriesId, service),
    );
  }

  @override
  Future<Map<String, dynamic>> getPlaylists() {
    final service = _service;
    if (service == null) return _inner.getPlaylists();
    return _filterAll(service, _inner.getPlaylists);
  }

  @override
  Future<Map<String, dynamic>> getPlaylistItems(
    String playlistId, {
    int? startIndex,
    int? limit,
  }) async {
    final service = _service;
    Future<Map<String, dynamic>> call(int? start, int? lim) =>
        _inner.getPlaylistItems(playlistId, startIndex: start, limit: lim);
    if (service == null) return call(startIndex, limit);
    await service.ensureReady();
    return _pager.page(
      signature: _signature('getPlaylistItems', {
        'playlistId': playlistId,
      }, service.generation),
      startIndex: startIndex,
      limit: limit,
      paged: true,
      fetch: call,
      visibleOf: _visibleOf(service, null),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getSpecialFeatures(String itemId) {
    final service = _service;
    if (service == null) return _inner.getSpecialFeatures(itemId);
    return _filterList(
      service,
      () => _inner.getSpecialFeatures(itemId),
      allow: _anyEnteredVault(),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getLocalTrailers(String itemId) {
    final service = _service;
    if (service == null) return _inner.getLocalTrailers(itemId);
    return _filterList(
      service,
      () => _inner.getLocalTrailers(itemId),
      allow: _anyEnteredVault(),
    );
  }

  @override
  Future<Map<String, dynamic>> getItem(
    String itemId, {
    String? mediaSourceId,
    String? fields,
  }) {
    final service = _service;
    if (service == null) {
      return _inner.getItem(
        itemId,
        mediaSourceId: mediaSourceId,
        fields: fields,
      );
    }
    final base = fields ?? _defaultItemFields;
    final effectiveFields = base == null ? null : _withTags(base);
    return _guardItem(
      service,
      itemId,
      () => _inner.getItem(
        itemId,
        mediaSourceId: mediaSourceId,
        fields: effectiveFields,
      ),
    );
  }

  /// Hidden tags never show up as a filter choice outside the vault.
  @override
  Future<QueryFilterValues> getQueryFilters({
    String? parentId,
    List<String>? includeItemTypes,
  }) async {
    final values = await _inner.getQueryFilters(
      parentId: parentId,
      includeItemTypes: includeItemTypes,
    );
    final service = _service;
    if (service == null) return values;
    final hidden = service.policy.tagsForScope(
      service.isRuleLibrary(parentId) ? parentId : null,
    );
    if (hidden.isEmpty) return values;
    return QueryFilterValues(
      genres: values.genres,
      officialRatings: values.officialRatings,
      tags: [
        for (final tag in values.tags)
          if (!hidden.contains(normalizeTag(tag))) tag,
      ],
      years: values.years,
      audioLanguages: values.audioLanguages,
      subtitleLanguages: values.subtitleLanguages,
    );
  }

  // ---------------------------------------------------------------------------
  // Straight through: not item lists, or about an item already let through.
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> getPersons({
    required String searchTerm,
    int? limit,
    String? fields,
    String? enableImageTypes,
  }) => _inner.getPersons(
    searchTerm: searchTerm,
    limit: limit,
    fields: fields,
    enableImageTypes: enableImageTypes,
  );

  @override
  Future<List<Map<String, dynamic>>> getAncestors(String itemId) =>
      _inner.getAncestors(itemId);

  @override
  Future<Map<String, dynamic>> getThemeMedia(
    String itemId, {
    bool inheritFromParent = true,
  }) => _inner.getThemeMedia(itemId, inheritFromParent: inheritFromParent);

  @override
  Future<Map<String, dynamic>> getArtists({
    String? parentId,
    String? userId,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? fields,
    String? nameStartsWith,
    String? nameLessThan,
    bool? isFavorite,
  }) => _inner.getArtists(
    parentId: parentId,
    userId: userId,
    sortBy: sortBy,
    sortOrder: sortOrder,
    startIndex: startIndex,
    limit: limit,
    recursive: recursive,
    fields: fields,
    nameStartsWith: nameStartsWith,
    nameLessThan: nameLessThan,
    isFavorite: isFavorite,
  );

  @override
  Future<Map<String, dynamic>> getAlbumArtists({
    String? parentId,
    String? userId,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? fields,
    String? nameStartsWith,
    String? nameLessThan,
    bool? isFavorite,
  }) => _inner.getAlbumArtists(
    parentId: parentId,
    userId: userId,
    sortBy: sortBy,
    sortOrder: sortOrder,
    startIndex: startIndex,
    limit: limit,
    recursive: recursive,
    fields: fields,
    nameStartsWith: nameStartsWith,
    nameLessThan: nameLessThan,
    isFavorite: isFavorite,
  );

  @override
  Future<Map<String, dynamic>> createPlaylist({
    required String name,
    List<String>? itemIds,
  }) => _inner.createPlaylist(name: name, itemIds: itemIds);

  @override
  Future<Map<String, dynamic>> createCollection({
    required String name,
    List<String>? itemIds,
  }) => _inner.createCollection(name: name, itemIds: itemIds);

  @override
  Future<void> addToPlaylist(String playlistId, List<String> itemIds) =>
      _inner.addToPlaylist(playlistId, itemIds);

  @override
  Future<void> addToCollection(String collectionId, List<String> itemIds) =>
      _inner.addToCollection(collectionId, itemIds);

  @override
  Future<void> removeFromCollection(
    String collectionId,
    List<String> itemIds,
  ) => _inner.removeFromCollection(collectionId, itemIds);

  @override
  Future<void> removeFromPlaylist(String playlistId, List<String> entryIds) =>
      _inner.removeFromPlaylist(playlistId, entryIds);

  @override
  Future<void> movePlaylistItem(
    String playlistId,
    String playlistItemId,
    int newIndex,
  ) => _inner.movePlaylistItem(playlistId, playlistItemId, newIndex);

  @override
  Future<void> renamePlaylist(String playlistId, String name) =>
      _inner.renamePlaylist(playlistId, name);

  @override
  Future<void> deleteItem(String itemId) => _inner.deleteItem(itemId);

  @override
  Future<void> deletePlaylist(String playlistId) =>
      _inner.deletePlaylist(playlistId);

  @override
  Future<Map<String, dynamic>> getGenres({
    String? parentId,
    String? userId,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? fields,
    List<String>? includeItemTypes,
  }) => _inner.getGenres(
    parentId: parentId,
    userId: userId,
    sortBy: sortBy,
    sortOrder: sortOrder,
    startIndex: startIndex,
    limit: limit,
    recursive: recursive,
    fields: fields,
    includeItemTypes: includeItemTypes,
  );

  @override
  Future<Map<String, dynamic>> getStudios({
    String? parentId,
    String? userId,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? fields,
    List<String>? includeItemTypes,
  }) => _inner.getStudios(
    parentId: parentId,
    userId: userId,
    sortBy: sortBy,
    sortOrder: sortOrder,
    startIndex: startIndex,
    limit: limit,
    recursive: recursive,
    fields: fields,
    includeItemTypes: includeItemTypes,
  );

  @override
  Future<Map<String, dynamic>> getLyrics(String itemId) =>
      _inner.getLyrics(itemId);

  @override
  Future<List<Map<String, dynamic>>> getIntros(String itemId) =>
      _inner.getIntros(itemId);

  @override
  Future<List<Map<String, dynamic>>> getMediaSegments(String itemId) =>
      _inner.getMediaSegments(itemId);

  @override
  Future<List<Map<String, dynamic>>> searchRemoteSubtitles(
    String itemId, {
    required String language,
    bool? isPerfectMatch,
  }) => _inner.searchRemoteSubtitles(
    itemId,
    language: language,
    isPerfectMatch: isPerfectMatch,
  );

  @override
  Future<void> downloadRemoteSubtitle(String itemId, String subtitleId) =>
      _inner.downloadRemoteSubtitle(itemId, subtitleId);
}
