import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';

import 'hidden_content_service.dart';
import 'vault_store.dart';

/// Hands out the [HiddenContentService] of each signed in account.
///
/// One per server and user, created on first use and shared by every client
/// wrapper for that account. Works on the background engines too, since all
/// it needs is the preference store they register as well.
class HiddenContentRegistry {
  static HiddenContentRegistry instance = HiddenContentRegistry._(null);

  VaultKeyValueStore? _store;
  final DateTime Function()? _now;
  final Map<VaultScope, HiddenContentService> _services = {};

  /// Bumps whenever any account's rules or index change, so screens that
  /// show items can recheck what they hold.
  final ValueNotifier<int> changes = ValueNotifier(0);

  HiddenContentRegistry._(this._store, {this._now});

  /// Replaces the shared instance, for tests.
  @visibleForTesting
  static HiddenContentRegistry debugReset({
    VaultKeyValueStore? store,
    DateTime Function()? now,
  }) {
    for (final service in instance._services.values) {
      service.dispose();
    }
    instance = HiddenContentRegistry._(store, now: now);
    return instance;
  }

  VaultKeyValueStore? get _resolvedStore {
    final store = _store;
    if (store != null) return store;
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<PreferenceStore>()) return null;
    return _store = PreferenceVaultStore(getIt<PreferenceStore>());
  }

  /// The service for [scope]. [onlineApi] is the account's unfiltered,
  /// always-online items API, used for the index and tag lookups; the latest
  /// one given wins, since a server's client can be replaced.
  HiddenContentService? serviceFor(
    VaultScope scope, {
    ItemsApi Function()? onlineApi,
  }) {
    if (!scope.isValid) return null;
    final existing = _services[scope];
    if (existing != null) {
      if (onlineApi != null) existing.onlineApi = onlineApi;
      return existing;
    }
    final store = _resolvedStore;
    if (store == null || onlineApi == null) return null;
    final service = HiddenContentService(
      scope: scope,
      store: store,
      onlineApi: onlineApi,
      now: _now,
    );
    service.addListener(() => changes.value++);
    _services[scope] = service;
    return service;
  }

  /// The service for [scope] only if one was already created.
  HiddenContentService? existing(VaultScope scope) => _services[scope];

  Iterable<HiddenContentService> get services => _services.values;
}
