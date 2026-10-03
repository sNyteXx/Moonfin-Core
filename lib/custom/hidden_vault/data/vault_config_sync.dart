import 'package:server_core/server_core.dart';

import '../model/vault_config.dart';

/// Carries the vault config between a user's devices through the server's
/// own per-user display preferences, so it needs no plugin and reaches every
/// device signed in as that user. The Moonbase settings profile has a fixed
/// schema and drops keys it doesn't know, so it can't carry this.
///
/// Only the rules and session settings travel. The PIN, the hidden index,
/// the unlock state and this device's own choices never leave the device.
class VaultConfigSync {
  static const preferencesId = 'moonfin-hidden-vault';
  static const client = 'moonfin';
  static const key = 'config';

  final DisplayPreferencesApi Function() _api;

  VaultConfigSync(this._api);

  /// The copy on the server, or null when there is none.
  Future<VaultConfig?> pull() async {
    final prefs = await _api().getDisplayPreferences(
      preferencesId,
      client: client,
    );
    final raw = prefs.customPrefs[key];
    if (raw == null || raw.isEmpty) return null;
    final config = VaultConfig.decode(raw);
    return config.updatedAt == 0 && config.vaults.isEmpty ? null : config;
  }

  /// Replaces the server's copy with [config], keeping whatever else is
  /// stored under the same preferences.
  Future<void> push(VaultConfig config) async {
    final api = _api();
    final current = await api.getDisplayPreferences(
      preferencesId,
      client: client,
    );
    await api.saveDisplayPreferences(
      preferencesId,
      DisplayPreferences(
        id: current.id,
        sortBy: current.sortBy,
        sortOrder: current.sortOrder,
        viewType: current.viewType,
        customPrefs: {...current.customPrefs, key: config.encode()},
      ),
      client: client,
    );
  }
}
