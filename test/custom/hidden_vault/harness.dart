import 'package:moonfin/custom/hidden_vault/data/hidden_content_service.dart';
import 'package:server_core/server_core.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_items_api.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';

import 'fake_server.dart';

class TestContext implements VisibilityContext {
  @override
  HiddenContentService? service;

  @override
  Set<String> enteredVaults = {};

  final List<String> activity = [];

  @override
  void noteVaultActivity(String vaultId) => activity.add(vaultId);
}

const scope = VaultScope('server-1', 'user-1');

/// The library layout the tests share, shaped like the real setup: an anime
/// vault over Anime + Anime films and a shows vault over Shows + Films.
VaultConfig standardConfig() => VaultConfig(
  vaults: [
    VaultDefinition(
      id: 'anime',
      name: 'Anime',
      libraries: [
        VaultLibrary(
          libraryId: 'lib-anime',
          name: 'Anime',
          collectionType: 'tvshows',
          tags: ['ecchi'],
        ),
        VaultLibrary(
          libraryId: 'lib-anime-movies',
          name: 'Filme (Anime)',
          collectionType: 'movies',
          tags: ['ecchi', 'private'],
        ),
      ],
    ),
    VaultDefinition(
      id: 'shows',
      name: 'Serien/Filme',
      libraries: [
        VaultLibrary(
          libraryId: 'lib-shows',
          name: 'Serien',
          collectionType: 'tvshows',
          tags: ['private', 'hidden'],
        ),
        VaultLibrary(
          libraryId: 'lib-movies',
          name: 'Filme',
          collectionType: 'movies',
          tags: ['adult'],
        ),
      ],
    ),
  ],
);

class Harness {
  final FakeJellyfin server;
  final MemoryVaultStore store = MemoryVaultStore();
  final TestContext context = TestContext();
  late HiddenContentService service;
  late VisibilityItemsApi api;
  DateTime now = DateTime(2026, 10, 2, 12);

  Harness({FakeJellyfin? catalog}) : server = catalog ?? FakeJellyfin() {
    service = HiddenContentService(
      scope: scope,
      store: store,
      onlineApi: () => server,
      now: () => now,
    );
    context.service = service;
    api = VisibilityItemsApi(server, context);
  }

  /// A fresh service over the same store, like the next app start.
  HiddenContentService restart() {
    service = HiddenContentService(
      scope: scope,
      store: store,
      onlineApi: () => server,
      now: () => now,
    );
    context.service = service;
    api = VisibilityItemsApi(server, context);
    return service;
  }

  Future<void> configure([VaultConfig? config]) =>
      service.saveConfig(config ?? standardConfig());

  /// The small catalog most tests use.
  void seedStandard() {
    final s = server;
    // Anime: a1, a2 hidden; a3/a4 carry look-alike tags and stay visible.
    s.series(
      'lib-anime',
      'a1',
      tags: ['Ecchi', 'Romance'],
      created: '2024-05-01',
    );
    s.series('lib-anime', 'a2', tags: ['ECCHI'], created: '2024-05-02');
    s.series('lib-anime', 'a3', tags: ['ecchi comedy'], created: '2024-05-03');
    s.series('lib-anime', 'a4', tags: ['super-ecchi'], created: '2024-05-04');
    s.series('lib-anime', 'a5', tags: ['Action'], created: '2024-05-05');
    s.series('lib-anime', 'a6', tags: ['Ecchi!'], created: '2024-05-06');
    s.episode('lib-anime', 'a1e1', seriesId: 'a1', nextUp: true);
    s.episode('lib-anime', 'a2e1', seriesId: 'a2', resume: true);
    s.episode('lib-anime', 'a5e1', seriesId: 'a5', nextUp: true);
    s.episode('lib-anime', 'a5e2', seriesId: 'a5', resume: true);
    // Anime films.
    s.movie('lib-anime-movies', 'm1', tags: ['ecchi'], resume: true);
    s.movie('lib-anime-movies', 'm2', tags: ['Private']);
    s.movie('lib-anime-movies', 'm3', tags: ['Drama']);
    // Shows: s1 carries an anime tag but sits outside the anime vault.
    s.series('lib-shows', 's1', tags: ['ecchi'], created: '2024-06-01');
    s.series('lib-shows', 's2', tags: ['private'], created: '2024-06-02');
    s.series('lib-shows', 's3', tags: ['hidden gem'], created: '2024-06-03');
    s.episode('lib-shows', 's1e1', seriesId: 's1', nextUp: true);
    s.episode('lib-shows', 's2e1', seriesId: 's2', nextUp: true);
    // Films.
    s.movie('lib-movies', 'f1', tags: ['adult animation']);
    s.movie('lib-movies', 'f2', tags: ['Adult']);
    s.movie('lib-movies', 'f3', tags: []);
  }
}

List<String> idsOf(Map<String, dynamic> response) => [
  for (final item in (response['Items'] as List)) (item as Map)['Id'] as String,
];

/// Image urls that point nowhere; enough for screens to lay out.
class FakeImageApi implements ImageApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => '';
}

/// A signed in client over [FakeJellyfin]; everything the tests don't use
/// throws.
class FakeMediaServerClient implements MediaServerClient {
  @override
  final ImageApi imageApi = FakeImageApi();

  @override
  final ItemsApi itemsApi;

  @override
  String? userId = scope.userId;

  @override
  String baseUrl = 'http://server';

  @override
  String? accessToken = 'token';

  FakeMediaServerClient(this.itemsApi);

  @override
  ServerType get serverType => ServerType.jellyfin;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
