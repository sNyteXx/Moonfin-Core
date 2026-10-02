import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_repository.dart';
import 'package:moonfin/data/models/aggregated_item.dart';

import 'harness.dart';

/// The vault context: each vault lists only its own hidden content.
void main() {
  late Harness h;

  setUp(() async {
    h = Harness()..seedStandard();
    await h.configure();
    h.server.resetCalls();
  });

  VaultRepository repoFor(String vaultId) => VaultRepository(
    service: h.service,
    vault: h.service.config.vault(vaultId)!,
    api: h.server,
    serverId: scope.serverId,
  );

  List<String> ids(Iterable<AggregatedItem> items) => [
    for (final item in items) item.id,
  ];

  test('library grids ask the server for the tags of that library', () async {
    final repo = repoFor('anime');
    final anime = repo.vault.library('lib-anime')!;
    final page = await repo.libraryPage(anime);
    expect(ids(page.items), ['a1', 'a2']);
    final call = h.server.calls.single;
    expect(call.params['parentId'], 'lib-anime');
    expect(call.params['tags'], ['ecchi']);
    // "Ecchi!" matched the server's loose comparison, not the exact one.
    expect(page.rawCount, 3);
  });

  test('anime vault: only anime hidden content', () async {
    final repo = repoFor('anime');
    expect(
      ids((await repo.libraryPage(repo.vault.library('lib-anime-movies')!)).items),
      ['m1', 'm2'],
    );
    expect(ids(await repo.continueWatching()), unorderedEquals(['a2e1', 'm1']));
    expect(ids(await repo.nextUp()), ['a1e1']);
    final search = ids(await repo.search('a'));
    expect(search, containsAll(['a1', 'a2', 'a1e1', 'a2e1']));
    for (final other in ['a3', 'a5', 'a5e1', 's1', 's2', 's2e1', 'f2']) {
      expect(search, isNot(contains(other)));
    }
  });

  test('shows vault: its own content, nothing from the anime vault', () async {
    final repo = repoFor('shows');
    expect(
      ids((await repo.libraryPage(repo.vault.library('lib-shows')!)).items),
      ['s2'],
    );
    expect(
      ids((await repo.libraryPage(repo.vault.library('lib-movies')!)).items),
      ['f2'],
    );
    expect(ids(await repo.nextUp()), ['s2e1']);
    expect(ids(await repo.continueWatching()), isEmpty);
    final search = ids(await repo.search('s'));
    expect(search, containsAll(['s2', 's2e1']));
    expect(search, isNot(contains('s1')));
    expect(search, isNot(contains('s3')));
  });

  test('recently added merges the libraries newest first', () async {
    final repo = repoFor('anime');
    final recent = ids(await repo.recentlyAdded());
    expect(recent, containsAll(['a1', 'a2', 'm1', 'm2']));
    expect(recent.indexOf('a2'), lessThan(recent.indexOf('a1')));
  });

  test('rows are loaded once per visit', () async {
    final repo = repoFor('anime');
    await repo.libraryRow(repo.vault.library('lib-anime')!);
    await repo.libraryRow(repo.vault.library('lib-anime')!);
    await repo.nextUp();
    await repo.nextUp();
    expect(h.server.count('getItems'), 1);
    expect(h.server.count('getNextUp'), 1);
    repo.clear();
    await repo.nextUp();
    expect(h.server.count('getNextUp'), 2);
  });
}
