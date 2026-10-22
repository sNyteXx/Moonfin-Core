import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/hidden_vault.dart';
import 'package:moonfin/custom/hidden_vault/session/vault_session.dart';
import 'package:moonfin/data/database/offline_database.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/models/home_row.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/repositories/mdblist_repository.dart';
import 'package:moonfin/data/repositories/tmdb_repository.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/data/viewmodels/item_detail_view_model.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'harness.dart';

class _Factory extends Fake implements MediaServerClientFactory {
  final MediaServerClient client;

  _Factory(this.client);

  @override
  MediaServerClient clientForServerOrActive(String? serverId) => client;
}

class _PluginSyncService extends Mock implements PluginSyncService {}

class _Session extends Fake implements SessionRepository {
  @override
  String? get activeServerId => scope.serverId;

  @override
  String? get activeUserId => scope.userId;
}

AggregatedItem _item(String id, {String? seriesId, String type = 'Series'}) =>
    AggregatedItem(
      id: id,
      serverId: scope.serverId,
      rawData: {'Id': id, 'Type': type, 'SeriesId': ?seriesId},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeJellyfin server;
  late VisibilityMediaServerClient client;
  late VaultSessionController session;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<PreferenceStore>(store);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    final pluginSync = _PluginSyncService();
    when(() => pluginSync.seerrAvailable).thenReturn(false);
    GetIt.instance.registerSingleton<PluginSyncService>(pluginSync);

    HiddenContentRegistry.debugReset(store: MemoryVaultStore());
    session = VaultSessionController.debugReset();

    final harness = Harness()..seedStandard();
    server = harness.server;
    client = VisibilityMediaServerClient(
      FakeMediaServerClient(server),
      serverId: scope.serverId,
      onlineItemsApi: () => server,
    );
    GetIt.instance.registerSingleton<MediaServerClientFactory>(
      _Factory(client),
    );
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    GetIt.instance.registerSingleton<SessionRepository>(_Session());
    await client.visibilityService!.saveConfig(standardConfig());
  });

  tearDown(() async {
    session.dispose();
    await GetIt.instance.reset();
  });

  group('playback gate', () {
    test('hidden items are refused outside their vault', () async {
      expect(HiddenContentGate.isRefusedNow(_item('a1')), isTrue);
      expect(
        HiddenContentGate.isRefusedNow(
          _item('a1e1', seriesId: 'a1', type: 'Episode'),
        ),
        isTrue,
      );
      // No metadata is still pending, not evidence that the item is visible.
      expect(HiddenContentGate.isRefusedNow(_item('a5')), isTrue);
      expect(await HiddenContentGate.isRefused(_item('a5')), isFalse);
      expect(HiddenContentGate.isRefusedNow(_item('a5')), isFalse);
      expect(await HiddenContentGate.isRefused(_item('a1')), isTrue);
      expect(
        await HiddenContentGate.isRefused(
          _item('a1e1', seriesId: 'a1', type: 'Episode'),
        ),
        isTrue,
      );
    });

    test('a mixed queue keeps only what may play', () async {
      await client.itemsApi.getNextUp(limit: 15);
      await client.itemsApi.getItem('m3');
      final queue = [
        _item('a5e1', seriesId: 'a5', type: 'Episode'),
        _item('a1e1', seriesId: 'a1', type: 'Episode'),
        _item('m3', type: 'Movie'),
        _item('m1', type: 'Movie'),
      ];
      final allowed = queue
          .where((i) => !HiddenVault.refusePlaybackNow(i))
          .map((i) => i.id)
          .toList();
      expect(allowed, ['a5e1', 'm3']);
    });

    test(
      'a failed lookup cannot play, and a later successful check recovers',
      () async {
        await client.itemsApi.getItem('a5');
        server.series('lib-anime', 'new-series', tags: ['Ecchi']);
        server.episode('lib-anime', 'new-episode', seriesId: 'new-series');
        final item = _item(
          'new-episode',
          seriesId: 'new-series',
          type: 'Episode',
        );
        server.tagLookupError = StateError('lookup failed');
        session.unlock(scope, 'anime');
        session.enter(scope, 'anime');

        expect(await HiddenContentGate.isRefused(item), isTrue);
        expect(HiddenContentGate.isRefusedNow(item), isTrue);
        expect(HiddenContentGate.isRefusedNow(_item('a5')), isFalse);
        expect(await HiddenContentGate.isRefused(_item('a5')), isFalse);

        server.tagLookupError = null;
        expect(await HiddenContentGate.isRefused(item), isFalse);
        session.lock(scope, 'anime', VaultLockReason.manual);
        expect(await HiddenContentGate.isRefused(item), isTrue);
      },
    );

    test('unlocking alone does not let anything play', () async {
      session.unlock(scope, 'anime');
      expect(await HiddenContentGate.isRefused(_item('a1')), isTrue);
    });

    test('inside the open vault its own content plays, the other vault '
        'stays shut', () async {
      session.unlock(scope, 'anime');
      session.enter(scope, 'anime');
      expect(await HiddenContentGate.isRefused(_item('a1')), isFalse);
      expect(
        HiddenContentGate.isRefusedNow(
          _item('a1e1', seriesId: 'a1', type: 'Episode'),
        ),
        isFalse,
      );
      expect(await HiddenContentGate.isRefused(_item('s2')), isTrue);
      session.lock(scope, 'anime', VaultLockReason.manual);
      expect(await HiddenContentGate.isRefused(_item('a1')), isTrue);
    });
  });

  group('detail gate', () {
    ItemDetailViewModel detailFor(String id) {
      final tmdb = TmdbRepository(client);
      return ItemDetailViewModel(
        itemId: id,
        client: client,
        mutations: ItemMutationRepository(client),
        mdbListRepository: MdbListRepository(client, tmdb),
        tmdbRepository: tmdb,
      );
    }

    test('a hidden item outside the vault shows the neutral blocked state, '
        'with nothing of the item loaded', () async {
      final vm = detailFor('a1');
      await vm.load();
      expect(vm.state, ItemDetailState.blocked);
      expect(vm.item, isNull);
      // Nothing fanned out after the refusal: no episodes, no similar.
      expect(server.count('getEpisodes'), 0);
      expect(server.count('getSimilarItems'), 0);
    });

    test('an episode of a hidden series is blocked the same way', () async {
      final vm = detailFor('a1e1');
      await vm.load();
      expect(vm.state, ItemDetailState.blocked);
    });

    test(
      'unavailable parent tags block detail before any related data loads',
      () async {
        server.series('lib-anime', 'new-series', tags: ['Ecchi']);
        server.episode('lib-anime', 'new-episode', seriesId: 'new-series');
        server.tagLookupError = StateError('lookup failed');
        final vm = detailFor('new-episode');

        await vm.load();

        expect(vm.state, ItemDetailState.blocked);
        expect(vm.item, isNull);
        expect(server.count('getEpisodes'), 0);
        expect(server.count('getSimilarItems'), 0);
      },
    );

    test('inside the open vault the detail page opens', () async {
      session.unlock(scope, 'anime');
      session.enter(scope, 'anime');
      final vm = detailFor('a1');
      await vm.load();
      expect(vm.state, ItemDetailState.ready);
      expect(vm.item?.id, 'a1');
    });
  });

  group('normal screens', () {
    test('home rows read back from the cache are filtered again', () async {
      await client.itemsApi.getItem('a5');
      final rows = [
        HomeRow(
          id: 'latest',
          title: 'Latest',
          rowType: HomeRowType.latestMedia,
          items: [
            _item('a1'),
            _item('a5'),
            _item('m1', type: 'Movie'),
          ],
        ),
      ];
      final filtered = HiddenVault.filterCachedRows(rows);
      expect(filtered.single.items.map((i) => i.id), ['a5']);
    });

    test(
      'cached rows withhold pending and failed items but keep known ones',
      () async {
        await client.itemsApi.getItem('a5');
        server.series('lib-anime', 'new-series', tags: ['Ecchi']);
        final pending = _item('new-series');
        final rows = [
          HomeRow(
            id: 'latest',
            title: 'Latest',
            rowType: HomeRowType.latestMedia,
            items: [_item('a5'), pending],
          ),
        ];
        expect(
          HiddenVault.filterCachedRows(rows).single.items.map((i) => i.id),
          ['a5'],
        );
        server.tagLookupError = StateError('lookup failed');
        expect(await HiddenContentGate.isRefused(pending), isTrue);
        expect(
          HiddenVault.filterCachedRows(rows).single.items.map((i) => i.id),
          ['a5'],
        );
      },
    );

    test(
      'download filtering uses saved tags and preserves series inheritance',
      () async {
        await client.itemsApi.getItem('a5');
        DownloadedItem download(
          String id, {
          String type = 'Movie',
          String? seriesId,
          List<String>? tags,
        }) => DownloadedItem(
          itemId: id,
          serverId: scope.serverId,
          type: type,
          name: id,
          metadataJson: jsonEncode({'Tags': ?tags}),
          downloadStatus: 2,
          downloadProgress: 1,
          fileSizeBytes: 1,
          playbackPositionTicks: 0,
          progressSynced: true,
          qualityPreset: 'original',
          seriesId: seriesId,
          downloadSource: 'manual',
        );
        final rows = [
          download('safe-movie', tags: []),
          download('safe-episode', type: 'Episode', seriesId: 'a5', tags: []),
          download('tagged-movie', tags: ['Ecchi']),
          download('missing-metadata'),
          download('hidden-episode', type: 'Episode', seriesId: 'a1', tags: []),
          download(
            'unknown-episode',
            type: 'Episode',
            seriesId: 'unknown',
            tags: [],
          ),
        ];

        expect(HiddenVault.withoutHiddenDownloads(rows).map((i) => i.itemId), [
          'safe-movie',
          'safe-episode',
        ]);
      },
    );

    test('the cache token follows the rules', () async {
      final before = HiddenVault.cacheToken;
      expect(before, isNot('0'));
      await client.visibilityService!.saveConfig(
        client.visibilityService!.config.copyWith(vaults: const []),
      );
      expect(HiddenVault.cacheToken, isNot(before));
    });

    test('unlocking leaves the normal home filtered', () async {
      session.unlock(scope, 'anime');
      session.enter(scope, 'anime');
      final nextUp = await client.itemsApi.getNextUp(limit: 15);
      final ids = [
        for (final item in nextUp['Items'] as List) (item as Map)['Id'],
      ];
      expect(ids, isNot(contains('a1e1')));
      final resume = await client.itemsApi.getResumeItems(limit: 15);
      expect([
        for (final item in resume['Items'] as List) (item as Map)['Id'],
      ], isNot(contains('a2e1')));
    });
  });
}
