import 'dart:convert';

import 'tag_match.dart';

/// One library a vault covers, and the tags that hide an item in it.
///
/// The library id is the identity. [name] and [collectionType] are snapshots
/// for the settings screen and the vault's own rows, so renaming a library on
/// the server changes nothing about what is hidden.
class VaultLibrary {
  final String libraryId;
  final String name;
  final String? collectionType;

  /// The tags as they were picked or typed, kept for display.
  final List<String> tags;

  /// The comparison form of [tags].
  final Set<String> normalizedTags;

  VaultLibrary({
    required this.libraryId,
    required this.name,
    this.collectionType,
    List<String> tags = const [],
  }) : tags = _dedupeTags(tags),
       normalizedTags = normalizeTags(tags);

  static List<String> _dedupeTags(List<String> tags) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(normalizeTag(trimmed))) result.add(trimmed);
    }
    return List.unmodifiable(result);
  }

  bool get hasTags => normalizedTags.isNotEmpty;

  VaultLibrary copyWith({
    String? name,
    String? collectionType,
    List<String>? tags,
  }) => VaultLibrary(
    libraryId: libraryId,
    name: name ?? this.name,
    collectionType: collectionType ?? this.collectionType,
    tags: tags ?? this.tags,
  );

  Map<String, dynamic> toJson() => {
    'libraryId': libraryId,
    'name': name,
    if (collectionType != null) 'collectionType': collectionType,
    'tags': tags,
  };

  static VaultLibrary? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['libraryId']?.toString() ?? '';
    if (id.isEmpty) return null;
    final rawTags = json['tags'];
    return VaultLibrary(
      libraryId: id,
      name: json['name']?.toString() ?? '',
      collectionType: json['collectionType']?.toString(),
      tags: rawTags is List
          ? rawTags.map((e) => e?.toString() ?? '').toList()
          : const [],
    );
  }
}

/// A group of libraries that hide and reveal together, such as Anime plus
/// Anime films.
class VaultDefinition {
  /// Stable id, never shown and never derived from the name.
  final String id;
  final String name;
  final List<VaultLibrary> libraries;

  /// The home library tile whose long hold opens this vault, or null for a
  /// vault reached only through settings.
  final String? triggerLibraryId;

  VaultDefinition({
    required this.id,
    required this.name,
    List<VaultLibrary> libraries = const [],
    this.triggerLibraryId,
  }) : libraries = List.unmodifiable(libraries);

  bool get hasRules => libraries.any((l) => l.hasTags);

  VaultLibrary? library(String libraryId) {
    for (final library in libraries) {
      if (library.libraryId == libraryId) return library;
    }
    return null;
  }

  VaultDefinition copyWith({
    String? name,
    List<VaultLibrary>? libraries,
    String? triggerLibraryId,
    bool clearTrigger = false,
  }) => VaultDefinition(
    id: id,
    name: name ?? this.name,
    libraries: libraries ?? this.libraries,
    triggerLibraryId: clearTrigger
        ? null
        : (triggerLibraryId ?? this.triggerLibraryId),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'libraries': [for (final l in libraries) l.toJson()],
    if (triggerLibraryId != null) 'triggerLibraryId': triggerLibraryId,
  };

  static VaultDefinition? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final libs = json['libraries'];
    final trigger = json['triggerLibraryId']?.toString();
    return VaultDefinition(
      id: id,
      name: json['name']?.toString() ?? '',
      libraries: libs is List
          ? libs.map(VaultLibrary.fromJson).whereType<VaultLibrary>().toList()
          : const [],
      triggerLibraryId: (trigger == null || trigger.isEmpty) ? null : trigger,
    );
  }
}

/// Session behaviour, kept apart from the rules so changing a timeout never
/// throws away a cache.
class VaultSettings {
  static const autoLockChoices = [5, 15, 30, 60];
  static const defaultAutoLockMinutes = 15;

  final int autoLockMinutes;
  final bool lockOnLeave;

  const VaultSettings({
    this.autoLockMinutes = defaultAutoLockMinutes,
    this.lockOnLeave = true,
  });

  Duration get autoLockAfter => Duration(minutes: autoLockMinutes);

  VaultSettings copyWith({int? autoLockMinutes, bool? lockOnLeave}) =>
      VaultSettings(
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        lockOnLeave: lockOnLeave ?? this.lockOnLeave,
      );

  Map<String, dynamic> toJson() => {
    'autoLockMinutes': autoLockMinutes,
    'lockOnLeave': lockOnLeave,
  };

  static VaultSettings fromJson(Object? json) {
    if (json is! Map) return const VaultSettings();
    final minutes = json['autoLockMinutes'];
    return VaultSettings(
      autoLockMinutes: minutes is int && minutes > 0
          ? minutes
          : defaultAutoLockMinutes,
      lockOnLeave: json['lockOnLeave'] is bool
          ? json['lockOnLeave'] as bool
          : true,
    );
  }
}

/// Everything one user on one server configured.
class VaultConfig {
  static const empty = VaultConfig._(
    vaults: [],
    settings: VaultSettings(),
    revision: 0,
    updatedAt: 0,
  );

  final List<VaultDefinition> vaults;
  final VaultSettings settings;

  /// Bumped on every save. Lets listeners tell two saves apart even when the
  /// rules came out the same.
  final int revision;

  /// When this config was last saved on any device (ms since epoch, UTC).
  /// Syncing keeps whichever copy is newer.
  final int updatedAt;

  const VaultConfig._({
    required this.vaults,
    required this.settings,
    required this.revision,
    required this.updatedAt,
  });

  /// Drops empty ids and gives each library to the first vault that names it,
  /// since an item can only ever belong to one vault.
  factory VaultConfig({
    required List<VaultDefinition> vaults,
    VaultSettings settings = const VaultSettings(),
    int revision = 0,
    int updatedAt = 0,
  }) {
    final claimed = <String>{};
    final seenVaults = <String>{};
    final cleaned = <VaultDefinition>[];
    for (final vault in vaults) {
      if (vault.id.isEmpty || !seenVaults.add(vault.id)) continue;
      final libs = <VaultLibrary>[];
      for (final lib in vault.libraries) {
        if (claimed.add(lib.libraryId)) libs.add(lib);
      }
      // A vault always opens from one of its own libraries: the one chosen,
      // or else the first. A config saved without one (or with a library that
      // left the vault) still gets a working tile.
      final trigger = vault.triggerLibraryId;
      final triggerValid =
          trigger != null && libs.any((l) => l.libraryId == trigger);
      final effective = triggerValid ? trigger : libs.firstOrNull?.libraryId;
      cleaned.add(
        vault.copyWith(
          libraries: libs,
          triggerLibraryId: effective,
          clearTrigger: effective == null,
        ),
      );
    }
    return VaultConfig._(
      vaults: List.unmodifiable(cleaned),
      settings: settings,
      revision: revision,
      updatedAt: updatedAt,
    );
  }

  bool get hasRules => vaults.any((v) => v.hasRules);

  VaultDefinition? vault(String id) {
    for (final vault in vaults) {
      if (vault.id == id) return vault;
    }
    return null;
  }

  VaultDefinition? vaultForLibrary(String libraryId) {
    for (final vault in vaults) {
      if (vault.library(libraryId) != null) return vault;
    }
    return null;
  }

  VaultDefinition? vaultForTrigger(String libraryId) {
    for (final vault in vaults) {
      if (vault.triggerLibraryId == libraryId) return vault;
    }
    return null;
  }

  VaultConfig copyWith({
    List<VaultDefinition>? vaults,
    VaultSettings? settings,
    int? revision,
    int? updatedAt,
  }) => VaultConfig(
    vaults: vaults ?? this.vaults,
    settings: settings ?? this.settings,
    revision: revision ?? this.revision,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Changes exactly when what is hidden changes: vault ids, library ids and
  /// normalized tags. Names, the trigger tile and session settings are left
  /// out, so editing them keeps every cache.
  String get fingerprint {
    final parts = <String>[];
    final sortedVaults = [...vaults]..sort((a, b) => a.id.compareTo(b.id));
    for (final vault in sortedVaults) {
      final libs = [...vault.libraries]
        ..sort((a, b) => a.libraryId.compareTo(b.libraryId));
      for (final lib in libs) {
        if (!lib.hasTags) continue;
        final tags = lib.normalizedTags.toList()..sort();
        parts.add('${vault.id}/${lib.libraryId}=${tags.join('|')}');
      }
    }
    if (parts.isEmpty) return '0';
    return fnv1a(parts.join(';'));
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'revision': revision,
    'updatedAt': updatedAt,
    'vaults': [for (final v in vaults) v.toJson()],
    'settings': settings.toJson(),
  };

  String encode() => jsonEncode(toJson());

  static VaultConfig decode(String? source) {
    if (source == null || source.isEmpty) return empty;
    try {
      final json = jsonDecode(source);
      if (json is! Map) return empty;
      final vaults = json['vaults'];
      return VaultConfig(
        vaults: vaults is List
            ? vaults
                  .map(VaultDefinition.fromJson)
                  .whereType<VaultDefinition>()
                  .toList()
            : const [],
        settings: VaultSettings.fromJson(json['settings']),
        revision: json['revision'] is int ? json['revision'] as int : 0,
        updatedAt: json['updatedAt'] is int ? json['updatedAt'] as int : 0,
      );
    } catch (_) {
      return empty;
    }
  }
}

/// FNV-1a over the code units, stable across platforms and runs unlike
/// String.hashCode.
String fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16);
}
