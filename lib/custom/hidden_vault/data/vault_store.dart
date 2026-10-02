import 'package:jellyfin_preference/jellyfin_preference.dart';

/// Which signed in account a piece of vault state belongs to.
///
/// The library ids in a config only mean something on their own server, and
/// two people on one device must never share a vault, so everything is kept
/// per server and user.
class VaultScope {
  final String serverId;
  final String userId;

  const VaultScope(this.serverId, this.userId);

  bool get isValid => serverId.isNotEmpty && userId.isNotEmpty;

  /// Stable storage form. Server ids can hold a URL, so it is reduced to
  /// characters every store accepts.
  String get key => '${_safe(serverId)}.${_safe(userId)}';

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  @override
  bool operator ==(Object other) =>
      other is VaultScope &&
      other.serverId == serverId &&
      other.userId == userId;

  @override
  int get hashCode => Object.hash(serverId, userId);

  @override
  String toString() => 'VaultScope($serverId, $userId)';
}

/// The few string operations the vault persists through. Kept this small so
/// tests can hand in a map and the app hands in its [PreferenceStore].
abstract class VaultKeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class PreferenceVaultStore implements VaultKeyValueStore {
  final PreferenceStore _store;

  PreferenceVaultStore(this._store);

  @override
  String? getString(String key) => _store.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _store.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _store.remove(key);
  }
}

class MemoryVaultStore implements VaultKeyValueStore {
  final Map<String, String> values = {};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// Storage keys. Versioned so a later format can move without misreading the
/// old one.
abstract final class VaultStorageKeys {
  static String config(VaultScope scope) => 'hidden_vault.v1.config.${scope.key}';
  static String index(VaultScope scope) => 'hidden_vault.v1.index.${scope.key}';
  static String checks(VaultScope scope) => 'hidden_vault.v1.checks.${scope.key}';
}
