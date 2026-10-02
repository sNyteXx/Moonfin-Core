import 'package:server_core/server_core.dart';

import '../session/vault_session.dart';
import 'hidden_content_registry.dart';
import 'hidden_content_service.dart';
import 'visibility_items_api.dart';
import 'vault_store.dart';

/// Wraps a [MediaServerClient] so every item list it hands out is filtered
/// for the normal context. Everything else forwards untouched.
///
/// Sits outside the connectivity wrapper, so offline lists from the
/// downloads catalog are filtered the same way as online ones.
class VisibilityMediaServerClient implements MediaServerClient {
  final MediaServerClient _inner;

  /// The id the client factory knows this server by.
  final String serverId;

  /// The always-online, unfiltered items API, used for the hidden index and
  /// tag lookups. Defaults to the wrapped client's.
  final ItemsApi Function() _onlineItemsApi;

  late final _Context _context = _Context(this);
  final Map<ItemsApi, VisibilityItemsApi> _itemsApis = Map.identity();
  final Map<UserLibraryApi, _VisibilityUserLibraryApi> _userLibraryApis =
      Map.identity();
  final Map<InstantMixApi, _VisibilityInstantMixApi> _instantMixApis =
      Map.identity();

  VisibilityMediaServerClient(
    this._inner, {
    required this.serverId,
    ItemsApi Function()? onlineItemsApi,
  }) : _onlineItemsApi = onlineItemsApi ?? (() => _inner.itemsApi);

  /// The wrapped client, for the vault's own screens and anything that must
  /// never be filtered (downloads, playback info, sockets).
  MediaServerClient get unfilteredClient => _inner;

  VaultScope get scope => VaultScope(serverId, _inner.userId ?? '');

  /// The rules for whoever is signed in on this client right now.
  HiddenContentService? get visibilityService => HiddenContentRegistry.instance
      .serviceFor(scope, onlineApi: _onlineItemsApi);

  /// The filtered items API for the current routing (online or offline).
  @override
  ItemsApi get itemsApi {
    final inner = _inner.itemsApi;
    return _itemsApis.putIfAbsent(
      inner,
      () => VisibilityItemsApi(
        inner,
        _context,
        defaultItemFields: _inner.serverType == ServerType.jellyfin
            ? kDetailItemFields
            : null,
      ),
    );
  }

  @override
  UserLibraryApi get userLibraryApi {
    final inner = _inner.userLibraryApi;
    return _userLibraryApis.putIfAbsent(
      inner,
      () => _VisibilityUserLibraryApi(inner, _context),
    );
  }

  @override
  InstantMixApi get instantMixApi {
    final inner = _inner.instantMixApi;
    return _instantMixApis.putIfAbsent(
      inner,
      () => _VisibilityInstantMixApi(inner, _context),
    );
  }

  @override
  ServerType get serverType => _inner.serverType;

  @override
  DeviceInfo get deviceInfo => _inner.deviceInfo;

  @override
  String get baseUrl => _inner.baseUrl;

  @override
  set baseUrl(String url) => _inner.baseUrl = url;

  @override
  String? get accessToken => _inner.accessToken;

  @override
  set accessToken(String? token) => _inner.accessToken = token;

  @override
  String? get userId => _inner.userId;

  @override
  set userId(String? id) => _inner.userId = id;

  @override
  AuthApi get authApi => _inner.authApi;

  @override
  PlaybackApi get playbackApi => _inner.playbackApi;

  @override
  ImageApi get imageApi => _inner.imageApi;

  @override
  TrickplayApi? get trickplayApi => _inner.trickplayApi;

  @override
  SessionApi get sessionApi => _inner.sessionApi;

  @override
  SystemApi get systemApi => _inner.systemApi;

  @override
  UserViewsApi get userViewsApi => _inner.userViewsApi;

  @override
  LiveTvApi get liveTvApi => _inner.liveTvApi;

  @override
  DisplayPreferencesApi get displayPreferencesApi =>
      _inner.displayPreferencesApi;

  @override
  UsersApi get usersApi => _inner.usersApi;

  @override
  AdminSystemApi get adminSystemApi => _inner.adminSystemApi;

  @override
  AdminUsersApi get adminUsersApi => _inner.adminUsersApi;

  @override
  AdminLibraryApi get adminLibraryApi => _inner.adminLibraryApi;

  @override
  AdminEnvironmentApi get adminEnvironmentApi => _inner.adminEnvironmentApi;

  @override
  AdminTasksApi get adminTasksApi => _inner.adminTasksApi;

  @override
  AdminPluginsApi get adminPluginsApi => _inner.adminPluginsApi;

  @override
  AdminDevicesApi get adminDevicesApi => _inner.adminDevicesApi;

  @override
  AdminApiKeysApi get adminApiKeysApi => _inner.adminApiKeysApi;

  @override
  AdminBackupApi get adminBackupApi => _inner.adminBackupApi;

  @override
  AdminLiveTvApi get adminLiveTvApi => _inner.adminLiveTvApi;

  @override
  AdminItemsApi get adminItemsApi => _inner.adminItemsApi;

  @override
  SyncPlayApi? get syncPlayApi => _inner.syncPlayApi;

  @override
  ClientLogApi? get clientLogApi => _inner.clientLogApi;

  @override
  GamesApi? get gamesApi => _inner.gamesApi;

  @override
  void dispose() => _inner.dispose();
}

class _Context implements VisibilityContext {
  final VisibilityMediaServerClient _client;

  _Context(this._client);

  @override
  HiddenContentService? get service => _client.visibilityService;

  @override
  Set<String> get enteredVaults {
    final session = VaultSessionController.instance;
    if (!session.hasUnlocked) return const {};
    return session.enteredVaults(_client.scope);
  }

  @override
  void noteVaultActivity(String vaultId) =>
      VaultSessionController.instance.touch(_client.scope, vaultId);
}

class _VisibilityUserLibraryApi implements UserLibraryApi {
  final UserLibraryApi _inner;
  final VisibilityContext _context;

  _VisibilityUserLibraryApi(this._inner, this._context);

  @override
  Future<Map<String, dynamic>> getItem(String itemId) async {
    final data = await _inner.getItem(itemId);
    final service = _context.service;
    if (service == null || !service.isActive) return data;
    await service.ensureReady();
    final verdict = (await service.settle([data])).single;
    if (!verdict.isHidden) return data;
    final vaultId = verdict.vaultId;
    if (vaultId != null && _context.enteredVaults.contains(vaultId)) {
      _context.noteVaultActivity(vaultId);
      return data;
    }
    throw HiddenContentRefusal(itemId);
  }

  @override
  bool get supportsNumericUserRatings => _inner.supportsNumericUserRatings;

  @override
  Future<void> markFavorite(String itemId) => _inner.markFavorite(itemId);

  @override
  Future<void> unmarkFavorite(String itemId) => _inner.unmarkFavorite(itemId);

  @override
  Future<void> markPlayed(String itemId) => _inner.markPlayed(itemId);

  @override
  Future<void> unmarkPlayed(String itemId) => _inner.unmarkPlayed(itemId);

  @override
  Future<void> updateUserRating(String itemId, {required bool likes}) =>
      _inner.updateUserRating(itemId, likes: likes);

  @override
  Future<void> updateNumericUserRating(
    String itemId, {
    required double rating,
  }) => _inner.updateNumericUserRating(itemId, rating: rating);

  @override
  Future<void> deleteUserRating(String itemId) =>
      _inner.deleteUserRating(itemId);
}

class _VisibilityInstantMixApi implements InstantMixApi {
  final InstantMixApi _inner;
  final VisibilityContext _context;

  _VisibilityInstantMixApi(this._inner, this._context);

  @override
  Future<Map<String, dynamic>> getInstantMix(String itemId, {int? limit}) async {
    final response = await _inner.getInstantMix(itemId, limit: limit);
    final service = _context.service;
    if (service == null || !service.isActive) return response;
    await service.ensureReady();
    final items = [
      for (final item in (response['Items'] as List?) ?? const [])
        if (item is Map) item.cast<String, dynamic>(),
    ];
    final entered = _context.enteredVaults;
    final visible = await service.visible(
      items,
      allow: entered.isEmpty ? null : (_, vaultId) => entered.contains(vaultId),
    );
    return {...response, 'Items': visible};
  }
}
