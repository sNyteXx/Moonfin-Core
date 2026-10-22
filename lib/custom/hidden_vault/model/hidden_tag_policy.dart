import 'tag_match.dart';
import 'vault_config.dart';

/// The rule one library contributes: which vault owns it and which tags hide
/// an item inside it.
class LibraryRule {
  final String vaultId;
  final String libraryId;
  final Set<String> tags;

  const LibraryRule({
    required this.vaultId,
    required this.libraryId,
    required this.tags,
  });
}

/// The configured hiding rules in the form a check needs.
///
/// Answers "would these tags hide an item in that library" exactly and
/// ignoring case. Which library an item sits in is not part of a server item,
/// so the scoped answer is what the hidden index is built from; the unscoped
/// [matchesAnyRule] is only a hint that an item deserves a closer look.
class HiddenTagPolicy {
  static final HiddenTagPolicy none = HiddenTagPolicy._(
    const {},
    const {},
    '0',
  );

  final Map<String, LibraryRule> _rulesByLibrary;

  /// Every hidden tag of every library, for the cheap "could this be hidden"
  /// hint.
  final Set<String> allTags;

  /// The config fingerprint this policy was built from.
  final String fingerprint;

  HiddenTagPolicy._(this._rulesByLibrary, this.allTags, this.fingerprint);

  factory HiddenTagPolicy.fromConfig(VaultConfig config) {
    final rules = <String, LibraryRule>{};
    final all = <String>{};
    for (final vault in config.vaults) {
      for (final lib in vault.libraries) {
        if (!lib.hasTags) continue;
        rules[lib.libraryId] = LibraryRule(
          vaultId: vault.id,
          libraryId: lib.libraryId,
          tags: Set.unmodifiable(lib.normalizedTags),
        );
        all.addAll(lib.normalizedTags);
      }
    }
    if (rules.isEmpty) return none;
    return HiddenTagPolicy._(
      Map.unmodifiable(rules),
      Set.unmodifiable(all),
      config.fingerprint,
    );
  }

  bool get isActive => _rulesByLibrary.isNotEmpty;

  Iterable<LibraryRule> get rules => _rulesByLibrary.values;

  LibraryRule? ruleFor(String libraryId) => _rulesByLibrary[libraryId];

  /// Whether an item in [libraryId] carrying [tags] is hidden there.
  bool isHiddenInLibrary(Iterable<String> tags, String libraryId) {
    final rule = _rulesByLibrary[libraryId];
    if (rule == null) return false;
    return matchesAnyTag(tags, rule.tags);
  }

  /// Whether [tags] would hide an item in at least one configured library.
  bool matchesAnyRule(Iterable<String> tags) => matchesAnyTag(tags, allTags);

  /// The hidden tags of [libraryId], or every hidden tag when the library is
  /// unknown or not given. Used to keep hidden tags out of filter pickers.
  Set<String> tagsForScope(String? libraryId) {
    if (libraryId == null) return allTags;
    return _rulesByLibrary[libraryId]?.tags ?? const {};
  }
}
