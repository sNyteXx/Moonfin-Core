import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_service.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_items_api.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';

import 'harness.dart';

void main() {
  group('hidden index', () {
    test('one tag query per configured library, exact validation', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      final tagQueries = h.server.calls
          .where((c) => c.method == 'getItems' && c.params['tags'] != null)
          .toList();
      expect(tagQueries, hasLength(4));
      expect(
        tagQueries.map((c) => c.params['parentId']).toSet(),
        {'lib-anime', 'lib-anime-movies', 'lib-shows', 'lib-movies'},
      );
      final index = h.service.index!;
      expect(index.ids.toSet(), {'a1', 'a2', 'm1', 'm2', 's2', 'f2'});
      // The server's cleaned match let "Ecchi!" through; exact matching
      // drops it again.
      expect(index.contains('a6'), isFalse);
      expect(index['a1']!.vaultId, 'anime');
      expect(index['s2']!.vaultId, 'shows');
    });

    test('several tags in one library are one query (Jellyfin ORs them)', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      final animeMovies = h.server.calls.singleWhere(
        (c) => c.params['parentId'] == 'lib-anime-movies' && c.params['tags'] != null,
      );
      expect(animeMovies.params['tags'], ['ecchi', 'private']);
    });

    test('persists and is reused on the next start without a request', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      h.server.resetCalls();
      final service = h.restart();
      expect(service.index, isNotNull);
      await service.ensureReady();
      expect(h.server.calls, isEmpty);
    });

    test('rebuilds in the background once stale', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      h.server.resetCalls();
      h.now = h.now.add(HiddenContentService.staleAfter + const Duration(minutes: 1));
      await h.service.ensureReady();
      await h.service.refreshIndex();
      expect(h.server.count('getItems'), 4);
    });
  });

  group('normal context never shows hidden content', () {
    late Harness h;

    setUp(() async {
      h = Harness()..seedStandard();
      await h.configure();
      h.server.resetCalls();
    });

    test('latest', () async {
      final latest = await h.api.getLatestItems(parentId: 'lib-anime', limit: 15);
      expect(idsOf(latest), ['a6', 'a5', 'a4', 'a3']);
    });

    test('resume', () async {
      final resume = await h.api.getResumeItems(limit: 15);
      expect(idsOf(resume), ['a5e2']);
    });

    test('next up, with episodes inheriting from their series', () async {
      final nextUp = await h.api.getNextUp(limit: 15);
      // a1e1 and s2e1 belong to hidden series and carry no tag of their own.
      expect(idsOf(nextUp), ['a5e1', 's1e1']);
    });

    test('library grid', () async {
      final grid = await h.api.getItems(
        parentId: 'lib-anime',
        includeItemTypes: ['Series'],
        recursive: true,
        limit: 48,
      );
      expect(idsOf(grid), ['a3', 'a4', 'a5', 'a6']);
    });

    test('search', () async {
      final results = await h.api.getItems(searchTerm: 'a', recursive: true, limit: 50);
      final ids = idsOf(results);
      for (final hidden in ['a1', 'a2', 'a1e1', 'a2e1', 'm1', 'm2']) {
        expect(ids, isNot(contains(hidden)));
      }
      expect(ids, containsAll(['a3', 'a5', 'a5e1']));
    });

    test('similar items and recommendations', () async {
      final similar = await h.api.getSimilarItems('a5', limit: 10);
      expect(idsOf(similar), isNot(contains('a1')));
      expect(idsOf(similar), isNot(contains('a2')));
      expect(idsOf(similar), contains('a3'));
    });

    test('library scope: an anime tag outside the anime vault stays visible', () async {
      final grid = await h.api.getItems(
        parentId: 'lib-shows',
        includeItemTypes: ['Series'],
        recursive: true,
        limit: 48,
      );
      // s1 carries "ecchi" but sits in the shows library, whose vault hides
      // "private" and "hidden" only. s3's "hidden gem" is not "hidden".
      expect(idsOf(grid), ['s1', 's3']);
    });

    test('exact matching on films: adult vs adult animation', () async {
      final grid = await h.api.getItems(parentId: 'lib-movies', recursive: true, limit: 48);
      expect(idsOf(grid), ['f1', 'f3']);
    });

    test('collections hide on their own tags', () async {
      h.server.add('lib-boxsets', {
        'Id': 'box1',
        'Name': 'box1',
        'Type': 'BoxSet',
        'Tags': ['ecchi'],
      });
      h.server.add('lib-boxsets', {
        'Id': 'box2',
        'Name': 'box2',
        'Type': 'BoxSet',
        'Tags': ['Classics'],
      });
      final grid = await h.api.getItems(parentId: 'lib-boxsets', recursive: true, limit: 48);
      expect(idsOf(grid), ['box2']);
    });

    test('hidden tags are not offered as filters', () async {
      final anime = await h.api.getQueryFilters(parentId: 'lib-anime');
      expect(anime.tags, isNot(contains('Ecchi')));
      expect(anime.tags, isNot(contains('ECCHI')));
      expect(anime.tags, contains('ecchi comedy'));
      final shows = await h.api.getQueryFilters(parentId: 'lib-shows');
      // "ecchi" is not a shows rule.
      expect(shows.tags, contains('ecchi'));
      expect(shows.tags, isNot(contains('private')));
    });

    test('opening a hidden item is refused like a missing one', () async {
      await expectLater(
        h.api.getItem('a1'),
        throwsA(isA<HiddenContentRefusal>()),
      );
      await expectLater(
        h.api.getItem('a1e1'),
        throwsA(isA<HiddenContentRefusal>()),
      );
      expect((await h.api.getItem('a5'))['Id'], 'a5');
    });

    test('series episodes of a hidden series are empty outside the vault', () async {
      final episodes = await h.api.getEpisodes('a1');
      expect(idsOf(episodes), isEmpty);
    });

    test('Tags is requested with the normal fields, not separately', () async {
      await h.api.getItems(parentId: 'lib-anime', limit: 10, fields: 'Overview,Genres');
      final call = h.server.calls.lastWhere((c) => c.method == 'getItems');
      expect(call.params['fields'], 'Overview,Genres,Tags');
    });
  });

  group('suspects and out-of-scope items', () {
    test('a new out-of-scope tag match costs one rebuild, then is remembered', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      final buildsAfterConfig = h.service.indexBuilds;
      await h.api.getItems(parentId: 'lib-shows', recursive: true, limit: 48);
      expect(h.service.indexBuilds, buildsAfterConfig + 1);
      await h.api.getItems(parentId: 'lib-shows', recursive: true, limit: 48);
      await h.api.getNextUp(limit: 15);
      expect(h.service.indexBuilds, buildsAfterConfig + 1);
      // And across a restart.
      h.restart();
      final grid = await h.api.getItems(parentId: 'lib-shows', recursive: true, limit: 48);
      expect(idsOf(grid), contains('s1'));
      expect(h.service.indexBuilds, 0);
    });

    test('an item tagged after the index was built is caught at once', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      h.server.series('lib-anime', 'a7', tags: ['ecchi'], created: '2025-01-01');
      final latest = await h.api.getLatestItems(parentId: 'lib-anime', limit: 15);
      expect(idsOf(latest), isNot(contains('a7')));
      expect(h.service.index!.contains('a7'), isTrue);
    });

    test('episodes of a series tagged after the build are caught by the batch lookup', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      h.server.series('lib-anime', 'a8', tags: ['Ecchi']);
      h.server.episode('lib-anime', 'a8e1', seriesId: 'a8', nextUp: true);
      final nextUp = await h.api.getNextUp(limit: 15);
      expect(idsOf(nextUp), isNot(contains('a8e1')));
    });
  });

  group('batch resolution', () {
    test('20 episodes from 3 unknown series cost one lookup request', () async {
      final h = Harness();
      h.server.series('lib-anime', 'hidden-series', tags: ['ecchi']);
      for (final series in ['x', 'y', 'z']) {
        h.server.series('lib-other', series, tags: ['Drama']);
      }
      var n = 0;
      for (final series in ['x', 'y', 'z']) {
        for (var e = 0; e < 7 && n < 20; e++, n++) {
          h.server.episode('lib-other', '$series-e$e', seriesId: series, nextUp: true);
        }
      }
      await h.configure();
      h.server.resetCalls();

      final nextUp = await h.api.getNextUp(limit: 50);
      expect(idsOf(nextUp), hasLength(20));
      final lookups = h.server.calls
          .where((c) => c.method == 'getItems' && c.params['ids'] != null)
          .toList();
      expect(lookups, hasLength(1));
      expect((lookups.single.params['ids'] as List).toSet(), {'x', 'y', 'z'});
      expect(h.server.count('getItem'), 0);

      // Known now: no further lookups, also after a restart.
      h.server.resetCalls();
      await h.api.getNextUp(limit: 50);
      await Future<void>.delayed(const Duration(seconds: 3));
      h.restart();
      await h.api.getNextUp(limit: 50);
      expect(
        h.server.calls.where((c) => c.params['ids'] != null),
        isEmpty,
      );
    });

    test('concurrent rows share one lookup', () async {
      final h = Harness();
      h.server.series('lib-anime', 'hidden-series', tags: ['ecchi']);
      h.server.series('lib-other', 'x', tags: []);
      h.server.episode('lib-other', 'x-e1', seriesId: 'x', nextUp: true, resume: true);
      await h.configure();
      h.server.resetCalls();
      await Future.wait([
        h.api.getNextUp(limit: 10),
        h.api.getResumeItems(limit: 10),
      ]);
      expect(
        h.server.calls.where((c) => c.params['ids'] != null),
        hasLength(1),
      );
    });
  });

  group('paging', () {
    Future<Harness> bigLibrary() async {
      final h = Harness();
      for (var i = 0; i < 60; i++) {
        h.server.series(
          'lib-anime',
          's${i.toString().padLeft(2, '0')}',
          tags: i % 3 == 0 ? ['ecchi'] : ['Action'],
        );
      }
      await h.configure();
      h.server.resetCalls();
      return h;
    }

    test('visible offsets page through without repeats or gaps', () async {
      final h = await bigLibrary();
      final seen = <String>[];
      var total = -1;
      for (var page = 0; page < 10; page++) {
        final response = await h.api.getItems(
          parentId: 'lib-anime',
          recursive: true,
          startIndex: seen.length,
          limit: 10,
        );
        final ids = idsOf(response);
        total = response['TotalRecordCount'] as int;
        if (ids.isEmpty) break;
        seen.addAll(ids);
      }
      expect(seen, hasLength(40));
      expect(seen.toSet(), hasLength(40));
      expect(seen.where((id) => int.parse(id.substring(1)) % 3 == 0), isEmpty);
      expect(total, 40);
    });

    test('rows stay full: a short page reads ahead within a budget', () async {
      final h = await bigLibrary();
      final page = await h.api.getItems(parentId: 'lib-anime', recursive: true, limit: 15);
      expect(idsOf(page), hasLength(15));
      expect(h.server.count('getItems'), lessThanOrEqualTo(2));
    });

    test('read-ahead stops at its budget', () async {
      final h = Harness();
      for (var i = 0; i < 2000; i++) {
        h.server.series('lib-anime', 'h$i', tags: ['ecchi']);
      }
      h.server.series('lib-anime', 'visible', tags: []);
      await h.configure();
      h.server.resetCalls();
      final page = await h.api.getItems(parentId: 'lib-anime', recursive: true, limit: 15);
      expect(idsOf(page), isEmpty);
      expect(h.server.count('getItems'), 1 + 3);
    });

    test('nothing hidden costs no extra request', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      h.server.resetCalls();
      await h.api.getItems(parentId: 'lib-movies', recursive: true, limit: 2, startIndex: 2);
      expect(h.server.count('getItems'), 1);
    });
  });

  group('unlock does not change the normal app', () {
    late Harness h;

    setUp(() async {
      h = Harness()..seedStandard();
      await h.configure();
      h.context.enteredVaults = {'anime'};
    });

    test('global lists stay filtered while the vault is open', () async {
      expect(idsOf(await h.api.getNextUp(limit: 15)), ['a5e1', 's1e1']);
      expect(idsOf(await h.api.getResumeItems(limit: 15)), ['a5e2']);
      expect(
        idsOf(await h.api.getLatestItems(parentId: 'lib-anime', limit: 15)),
        isNot(contains('a1')),
      );
      expect(
        idsOf(
          await h.api.getItems(parentId: 'lib-anime', recursive: true, limit: 48),
        ),
        isNot(contains('a1')),
      );
    });

    test('item specific calls inside the open vault see its content', () async {
      expect((await h.api.getItem('a1'))['Id'], 'a1');
      expect((await h.api.getItem('a1e1'))['Id'], 'a1e1');
      expect(idsOf(await h.api.getEpisodes('a1')), ['a1e1']);
      expect(idsOf(await h.api.getNextUp(seriesId: 'a1', limit: 5)), ['a1e1']);
      expect(h.context.activity, contains('anime'));
    });

    test('the other vault stays closed', () async {
      await expectLater(
        h.api.getItem('s2'),
        throwsA(isA<HiddenContentRefusal>()),
      );
      expect(idsOf(await h.api.getEpisodes('s2')), isEmpty);
    });
  });

  group('config changes', () {
    test('changing tags rebuilds and swaps what is hidden', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      final before = h.service.fingerprint;
      expect(
        idsOf(await h.api.getLatestItems(parentId: 'lib-anime', limit: 15)),
        isNot(contains('a1')),
      );
      await h.service.saveConfig(
        VaultConfig(
          vaults: [
            VaultDefinition(
              id: 'anime',
              name: 'Anime',
              libraries: [
                VaultLibrary(libraryId: 'lib-anime', name: 'Anime', tags: ['Action']),
              ],
            ),
          ],
        ),
      );
      expect(h.service.fingerprint, isNot(before));
      final latest = idsOf(await h.api.getLatestItems(parentId: 'lib-anime', limit: 15));
      expect(latest, contains('a1'));
      expect(latest, isNot(contains('a5')));
    });

    test('no rules: every call passes straight through', () async {
      final h = Harness()..seedStandard();
      final latest = await h.api.getLatestItems(parentId: 'lib-anime', limit: 15);
      expect(idsOf(latest), hasLength(6));
      expect(h.server.calls, hasLength(1));
      expect(h.server.calls.single.params, isNot(contains('tags')));
    });

    test('the store keeps nothing about an unlocked state', () async {
      final h = Harness()..seedStandard();
      await h.configure();
      for (final key in h.store.values.keys) {
        expect(key, isNot(contains('unlock')));
      }
      expect(
        h.store.values.keys,
        containsAll([
          VaultStorageKeys.config(scope),
          VaultStorageKeys.index(scope),
        ]),
      );
    });
  });
}
