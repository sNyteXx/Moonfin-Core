import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_repository.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_items_api.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/services/row_data_source.dart';

import 'fake_server.dart';
import 'harness.dart';

/// Request counts with a catalog the size of the real one: Anime 793 series /
/// 23,548 episodes, Anime films 417, Shows 795 / 18,998, Films 2,843, with
/// about 150 anime series tagged "ecchi".
///
/// Home rows go through the app's own [RowDataSource], so the numbers are
/// what the home screen really asks for.
void main() {
  FakeJellyfin realisticServer() {
    final s = FakeJellyfin();
    String date(int i) =>
        DateTime(2020).add(Duration(days: i)).toIso8601String();
    var episodeBudget = 23548;
    var ecchi = 0;
    for (var i = 0; i < 793; i++) {
      final hidden = i % 5 == 0 && ecchi < 150;
      if (hidden) ecchi++;
      s.series(
        'lib-anime',
        'anime-$i',
        tags: hidden ? ['Ecchi', 'Comedy'] : ['Action', 'Adventure'],
        created: date(i),
      );
      final episodes = i == 792 ? episodeBudget : 30;
      for (var e = 0; e < episodes && episodeBudget > 0; e++, episodeBudget--) {
        s.episode(
          'lib-anime',
          'anime-$i-e$e',
          seriesId: 'anime-$i',
          nextUp: e == 0 && i % 26 == 0,
          resume: e == 1 && i % 40 == 0,
        );
      }
    }
    for (var i = 0; i < 417; i++) {
      s.movie(
        'lib-anime-movies',
        'amovie-$i',
        tags: i % 14 == 0 ? ['ecchi'] : ['Drama'],
        created: date(i),
      );
    }
    episodeBudget = 18998;
    for (var i = 0; i < 795; i++) {
      s.series(
        'lib-shows',
        'show-$i',
        tags: i % 40 == 0 ? ['private'] : ['Crime'],
        created: date(i),
      );
      final episodes = i == 794 ? episodeBudget : 23;
      for (var e = 0; e < episodes && episodeBudget > 0; e++, episodeBudget--) {
        s.episode(
          'lib-shows',
          'show-$i-e$e',
          seriesId: 'show-$i',
          nextUp: e == 0 && i % 30 == 0,
        );
      }
    }
    for (var i = 0; i < 2843; i++) {
      s.movie(
        'lib-movies',
        'movie-$i',
        tags: i % 70 == 0 ? ['adult'] : (i % 7 == 0 ? ['adult animation'] : []),
        created: date(i),
        resume: i % 300 == 0,
      );
    }
    return s;
  }

  VaultConfig ecchiOnly() => VaultConfig(
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
            tags: ['ecchi'],
          ),
        ],
      ),
    ],
  );

  Future<void> homeLoad(RowDataSource rows) async {
    await Future.wait([
      rows.loadResume(scope.serverId),
      rows.loadNextUp(scope.serverId),
      rows.loadLatestMedia('lib-anime', 'Anime', scope.serverId, 'tvshows'),
      rows.loadLatestMedia(
        'lib-anime-movies',
        'Filme (Anime)',
        scope.serverId,
        'movies',
      ),
      rows.loadLatestMedia('lib-shows', 'Serien', scope.serverId, 'tvshows'),
      rows.loadLatestMedia('lib-movies', 'Filme', scope.serverId, 'movies'),
    ]);
  }

  Future<List<String>> openLibrary(
    VisibilityItemsApiLike api,
    String lib,
  ) async {
    final seen = <String>[];
    for (var page = 0; page < 3; page++) {
      final response = await api.getItems(
        parentId: lib,
        includeItemTypes: const ['Series'],
        recursive: true,
        sortBy: 'SortName',
        startIndex: seen.length,
        limit: 48,
      );
      seen.addAll(idsOf(response));
    }
    return seen;
  }

  test('request counts: off vs. cold start vs. warm start', () async {
    final report = StringBuffer()
      ..writeln(
        '| Scenario | Requests | thereof index | thereof tag lookups | ms |',
      );

    Future<void> measure(
      String label,
      Harness h,
      Future<void> Function() run, {
      bool resetFirst = true,
    }) async {
      if (resetFirst) h.server.resetCalls();
      final watch = Stopwatch()..start();
      await run();
      watch.stop();
      final calls = h.server.calls;
      final index = calls.where((c) => c.params['tags'] != null).length;
      // The vault's own tag lookups; the home screen's own id batch (next up
      // enrichment) is there with the vault off too.
      final lookups = calls
          .where((c) => c.params['ids'] != null && c.params['fields'] == 'Tags')
          .length;
      report.writeln(
        '| $label | ${calls.length} | $index | $lookups | ${watch.elapsedMilliseconds} |',
      );
    }

    // Feature off: the plain app.
    final off = Harness();
    final offServer = realisticServer();
    final offApi = VisibilityItemsApi(offServer, off.context);
    final offRows = RowDataSource(FakeMediaServerClient(offApi));
    offServer.resetCalls();
    var watch = Stopwatch()..start();
    await homeLoad(offRows);
    watch.stop();
    final offHome = offServer.calls.length;
    report.writeln(
      '| Home, vault off | $offHome | 0 | 0 | ${watch.elapsedMilliseconds} |',
    );

    // Feature on, first start ever: the index is built once.
    final server = realisticServer();
    final h = (harness: Harness(catalog: server));
    await h.harness.service.saveConfig(ecchiOnly());
    final buildRequests = server.calls.length;
    report.writeln(
      '| Index build (config save / first start) | $buildRequests | $buildRequests | 0 | – |',
    );
    expect(buildRequests, 2, reason: 'one query per configured library');
    expect(h.harness.service.index!.length, 150 + 30);

    final rows = RowDataSource(FakeMediaServerClient(h.harness.api));
    await measure('Home, vault on, cold', h.harness, () => homeLoad(rows));
    final coldHome = h.harness.server.calls.length;
    await measure(
      'Home, vault on, warm (same session)',
      h.harness,
      () => homeLoad(rows),
    );
    final warmHome = h.harness.server.calls.length;

    // Next start: index and lookups come from storage, once the session ran
    // long enough to write them (they are written a moment after learning).
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    h.harness.restart();
    final rowsAfterRestart = RowDataSource(
      FakeMediaServerClient(h.harness.api),
    );
    await measure(
      'Home, vault on, next app start',
      h.harness,
      () => homeLoad(rowsAfterRestart),
    );
    final restartHome = h.harness.server.calls.length;

    await measure('Open Anime (3 pages of 48)', h.harness, () async {
      final ids = await openLibrary(h.harness.api, 'lib-anime');
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.where((id) => h.harness.service.index!.contains(id)), isEmpty);
    });
    final animeOpen = h.harness.server.calls.length;
    await measure('Open Serien (3 pages of 48)', h.harness, () async {
      await openLibrary(h.harness.api, 'lib-shows');
    });
    final showsOpen = h.harness.server.calls.length;
    await measure('Next Up', h.harness, () async {
      await h.harness.api.getNextUp(limit: 15);
    });
    await measure('Search "anime-1"', h.harness, () async {
      final r = await h.harness.api.getItems(
        searchTerm: 'anime-1',
        recursive: true,
        limit: 50,
      );
      expect(
        idsOf(r).where((id) => h.harness.service.index!.contains(id)),
        isEmpty,
      );
    });

    // ignore: avoid_print
    print(report);

    // No N+1: per-episode lookups never happen.
    expect(server.count('getItem'), 0);
    // The home load costs what it did without the vault, plus at most one
    // batched tag lookup for series it has never seen and the read-ahead of
    // rows that lost items to the filter.
    expect(coldHome, lessThanOrEqualTo(offHome + 3 + 3));
    expect(warmHome, lessThanOrEqualTo(offHome + 3));
    expect(restartHome, lessThanOrEqualTo(offHome + 3));
    // Opening a library: one request per page, as without the vault.
    expect(animeOpen, 3);
    expect(showsOpen, 3);
  });

  test('vault context: requests and payload of the vault screens', () async {
    final server = realisticServer();
    final h = Harness(catalog: server);
    await h.service.saveConfig(ecchiOnly());
    final repo = VaultRepository(
      service: h.service,
      vault: h.service.config.vault('anime')!,
      api: server,
      serverId: scope.serverId,
    );
    final report = StringBuffer()
      ..writeln('| Vault scenario | Requests | Items sent | Items shown |');

    Future<({int requests, int sent, List<AggregatedItem> shown})> measure(
      String label,
      Future<List<AggregatedItem>> Function() run,
    ) async {
      server.resetCalls();
      final shown = await run();
      report.writeln(
        '| $label | ${server.calls.length} | ${server.transferred} | '
        '${shown.length} |',
      );
      return (
        requests: server.calls.length,
        sent: server.transferred,
        shown: shown,
      );
    }

    void onlyThisVault(List<AggregatedItem> items) {
      expect(items, isNotEmpty);
      for (final item in items) {
        expect(h.service.belongsToVault(item.rawData, 'anime'), isTrue);
      }
    }

    Future<List<AggregatedItem>> home() async => [
      for (final row in await Future.wait([
        repo.continueWatching(),
        repo.nextUp(),
        repo.recentlyAdded(),
        for (final library in repo.libraries) repo.libraryRow(library),
      ]))
        ...row,
    ];

    final open = await measure('Vault home, all rows', home);
    onlyThisVault(open.shown);
    final back = await measure('Vault home again (same visit)', home);

    final anime = repo.vault.library('lib-anime')!;
    final grid = await measure('Anime grid, 3 pages of 48', () async {
      final items = <AggregatedItem>[];
      var start = 0;
      for (var page = 0; page < 3; page++) {
        final result = await repo.libraryPage(anime, startIndex: start);
        items.addAll(result.items);
        start += result.rawCount;
      }
      return items;
    });
    onlyThisVault(grid.shown);

    final search = await measure(
      'Vault search "anime-1"',
      () => repo.search('anime-1'),
    );
    onlyThisVault(search.shown);

    // ignore: avoid_print
    print(report);

    // Resume and recently added per library, next up for the show library,
    // one row per library: 2 + 1 + 2 + 2.
    expect(open.requests, 7);
    expect(back.requests, 0);
    // The grid asks the server for the tags, so only hidden titles travel.
    expect(grid.requests, 3);
    expect(grid.sent, grid.shown.length);
    expect(grid.shown.map((i) => i.id).toSet(), hasLength(grid.shown.length));
    expect(grid.shown, hasLength(144));
    // Titles by tag in both libraries, episodes in the show library.
    expect(search.requests, 3);
    // No lookups per item anywhere in the vault.
    expect(server.count('getItem'), 0);
  });
}

typedef VisibilityItemsApiLike = VisibilityItemsApi;
