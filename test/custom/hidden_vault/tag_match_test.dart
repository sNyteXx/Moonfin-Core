import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/model/hidden_tag_policy.dart';
import 'package:moonfin/custom/hidden_vault/model/tag_match.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';

void main() {
  group('exact, case-insensitive tag matching', () {
    final ecchi = normalizeTags(['ecchi']);

    test('matches regardless of case', () {
      expect(matchesAnyTag(['ecchi'], ecchi), isTrue);
      expect(matchesAnyTag(['Ecchi'], ecchi), isTrue);
      expect(matchesAnyTag(['ECCHI'], ecchi), isTrue);
      expect(matchesAnyTag(['  Ecchi  '], ecchi), isTrue);
    });

    test('never matches a substring or a longer tag', () {
      expect(matchesAnyTag(['ecchi comedy'], ecchi), isFalse);
      expect(matchesAnyTag(['super-ecchi'], ecchi), isFalse);
      expect(matchesAnyTag(['ecchi-ish'], ecchi), isFalse);
      expect(matchesAnyTag(['ecch'], ecchi), isFalse);
    });

    test('adult does not match adult animation', () {
      final adult = normalizeTags(['adult']);
      expect(matchesAnyTag(['adult animation'], adult), isFalse);
      expect(matchesAnyTag(['Adult Animation', 'nudity'], adult), isFalse);
      expect(matchesAnyTag(['Adult'], adult), isTrue);
    });

    test('hidden does not match hidden gem', () {
      final hidden = normalizeTags(['hidden']);
      expect(matchesAnyTag(['hidden gem'], hidden), isFalse);
      expect(matchesAnyTag(['Hidden'], hidden), isTrue);
    });

    test('several hidden tags hide on any of them', () {
      final tags = normalizeTags(['ecchi', 'private']);
      expect(matchesAnyTag(['romance', 'Private'], tags), isTrue);
      expect(matchesAnyTag(['ecchi'], tags), isTrue);
      expect(matchesAnyTag(['romance', 'anime'], tags), isFalse);
    });

    test('empty and blank tags are ignored', () {
      expect(normalizeTags(['', '  ', 'a']), {'a'});
      expect(matchesAnyTag(['', ' '], normalizeTags(['a'])), isFalse);
    });
  });

  group('extractTags', () {
    test('reads Jellyfin Tags', () {
      expect(
        extractTags({
          'Tags': ['a', 'B'],
        }),
        ['a', 'B'],
      );
    });

    test('reads Emby TagItems', () {
      expect(
        extractTags({
          'TagItems': [
            {'Name': 'ecchi', 'Id': 1},
          ],
        }),
        ['ecchi'],
      );
    });

    test('tells a missing field from an empty one', () {
      expect(extractTags({'Name': 'x'}), isNull);
      expect(extractTags({'Tags': null}), isNull);
      expect(extractTags({'Tags': []}), isEmpty);
    });
  });

  group('library scope', () {
    final config = VaultConfig(
      vaults: [
        VaultDefinition(
          id: 'anime',
          name: 'Anime',
          libraries: [
            VaultLibrary(
              libraryId: 'lib-anime',
              name: 'Anime',
              tags: ['ecchi'],
            ),
            VaultLibrary(
              libraryId: 'lib-anime-movies',
              name: 'Filme (Anime)',
              tags: ['ecchi', 'Private'],
            ),
          ],
          triggerLibraryId: 'lib-anime',
        ),
        VaultDefinition(
          id: 'shows',
          name: 'Serien',
          libraries: [
            VaultLibrary(
              libraryId: 'lib-shows',
              name: 'Serien',
              tags: ['private'],
            ),
          ],
        ),
      ],
    );
    final policy = HiddenTagPolicy.fromConfig(config);

    test('anime tags never apply to the shows library', () {
      expect(policy.isHiddenInLibrary(['ecchi'], 'lib-anime'), isTrue);
      expect(policy.isHiddenInLibrary(['ecchi'], 'lib-shows'), isFalse);
      expect(policy.isHiddenInLibrary(['ecchi'], 'lib-unconfigured'), isFalse);
    });

    test('each library keeps its own tags', () {
      expect(policy.isHiddenInLibrary(['private'], 'lib-anime'), isFalse);
      expect(policy.isHiddenInLibrary(['PRIVATE'], 'lib-anime-movies'), isTrue);
      expect(policy.isHiddenInLibrary(['private'], 'lib-shows'), isTrue);
    });

    test('a library belongs to one vault only', () {
      final clash = VaultConfig(
        vaults: [
          VaultDefinition(
            id: 'a',
            name: 'A',
            libraries: [
              VaultLibrary(libraryId: 'lib', name: 'L', tags: ['x']),
            ],
          ),
          VaultDefinition(
            id: 'b',
            name: 'B',
            libraries: [
              VaultLibrary(libraryId: 'lib', name: 'L', tags: ['y']),
            ],
          ),
        ],
      );
      expect(clash.vaults[1].libraries, isEmpty);
      expect(HiddenTagPolicy.fromConfig(clash).ruleFor('lib')!.vaultId, 'a');
    });

    test('fingerprint follows the rules, not names or session settings', () {
      final renamed = VaultConfig(
        vaults: [for (final v in config.vaults) v.copyWith(name: '${v.name}!')],
        settings: const VaultSettings(autoLockMinutes: 60, lockOnLeave: false),
      );
      expect(renamed.fingerprint, config.fingerprint);
      final retagged = VaultConfig(
        vaults: [
          config.vaults.first.copyWith(
            libraries: [
              config.vaults.first.libraries.first.copyWith(tags: ['ECCHI']),
              config.vaults.first.libraries.last,
            ],
          ),
          config.vaults.last,
        ],
      );
      // Case only: same rules.
      expect(retagged.fingerprint, config.fingerprint);
      final changed = VaultConfig(
        vaults: [
          config.vaults.first.copyWith(
            libraries: [
              config.vaults.first.libraries.first.copyWith(tags: ['nudity']),
            ],
          ),
        ],
      );
      expect(changed.fingerprint, isNot(config.fingerprint));
    });

    test('config survives a save and load', () {
      final decoded = VaultConfig.decode(config.encode());
      expect(decoded.fingerprint, config.fingerprint);
      expect(decoded.vaults.first.triggerLibraryId, 'lib-anime');
      expect(decoded.vaults.first.libraries.last.tags, ['ecchi', 'Private']);
    });

    test('no hard coded defaults', () {
      expect(VaultConfig.empty.vaults, isEmpty);
      expect(HiddenTagPolicy.fromConfig(VaultConfig.empty).isActive, isFalse);
    });
  });

  group('trigger tile', () {
    VaultDefinition anime({String? trigger}) => VaultDefinition(
      id: 'anime',
      name: 'Anime',
      libraries: [
        VaultLibrary(libraryId: 'lib-anime', name: 'Anime', tags: ['ecchi']),
        VaultLibrary(libraryId: 'lib-am', name: 'Filme (Anime)', tags: ['x']),
      ],
      triggerLibraryId: trigger,
    );

    test('the chosen library stays the trigger', () {
      final config = VaultConfig(vaults: [anime(trigger: 'lib-am')]);
      expect(config.vaultForTrigger('lib-am')?.id, 'anime');
      expect(config.vaultForTrigger('lib-anime'), isNull);
    });

    test('a vault saved without a trigger opens from its first library', () {
      final config = VaultConfig(vaults: [anime()]);
      expect(config.vaultForTrigger('lib-anime')?.id, 'anime');
      // Also after a round trip through storage or the server.
      final decoded = VaultConfig.decode(
        '{"v":1,"vaults":[{"id":"anime","name":"Anime","libraries":'
        '[{"libraryId":"lib-anime","name":"Anime","tags":["ecchi"]}]}]}',
      );
      expect(decoded.vaultForTrigger('lib-anime')?.id, 'anime');
    });

    test('a trigger outside the vault falls back to its first library', () {
      final config = VaultConfig(vaults: [anime(trigger: 'lib-gone')]);
      expect(config.vaultForTrigger('lib-anime')?.id, 'anime');
      expect(config.vaultForTrigger('lib-gone'), isNull);
    });

    test('a vault without libraries has no trigger', () {
      final config = VaultConfig(
        vaults: [VaultDefinition(id: 'empty', name: 'Empty', libraries: [])],
      );
      expect(config.vaults.single.triggerLibraryId, isNull);
    });
  });
}
