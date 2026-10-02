/// Entry points the rest of the app calls into for the hidden content vault.
///
/// Upstream files only ever touch this file (each such line is marked
/// `hidden-vault:`), so a merge conflict is resolved by putting those few
/// calls back. See docs/custom/hidden-content-vault.md.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

import '../../auth/repositories/session_repository.dart';
import '../../auth/repositories/user_repository.dart';
import '../../data/database/offline_database.dart';
import '../../data/models/aggregated_item.dart';
import '../../data/models/home_row.dart';
import '../../data/services/row_data_source.dart';
import '../../data/viewmodels/media_bar_view_model.dart';
import '../../ui/navigation/home_refresh_bus.dart';
import 'data/hidden_content_registry.dart';
import 'data/hidden_content_service.dart';
import 'data/vault_store.dart';
import 'data/visibility_items_api.dart' as items_api;
import 'data/visibility_media_server_client.dart';
import 'gate/hidden_content_gate.dart';
import 'model/vault_config.dart';
import 'session/vault_session.dart';

export 'gate/hidden_content_gate.dart' show HiddenContentGate;

abstract final class HiddenVault {
  static bool _foregroundReady = false;
  static StreamSubscription<Object?>? _userSub;
  static AppLifecycleListener? _lifecycle;

  // ---------------------------------------------------------------------------
  // Client wrapping
  // ---------------------------------------------------------------------------

  /// Puts the visibility filter around [client]. [onlineItemsApi] must be the
  /// always-online, unfiltered API of the same server; the hidden index is
  /// built from it and must never be built from the offline catalog.
  static MediaServerClient wrapClient(
    MediaServerClient client, {
    required String serverId,
    required ItemsApi Function() onlineItemsApi,
  }) {
    if (client is VisibilityMediaServerClient) return client;
    return VisibilityMediaServerClient(
      client,
      serverId: serverId,
      onlineItemsApi: onlineItemsApi,
    );
  }

  /// [client] without the visibility filter.
  static MediaServerClient unwrapClient(MediaServerClient client) =>
      client is VisibilityMediaServerClient ? client.unfilteredClient : client;

  // ---------------------------------------------------------------------------
  // Active account
  // ---------------------------------------------------------------------------

  /// The signed in account, or null while signed out.
  static VaultScope? get activeScope {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<SessionRepository>()) return null;
    final session = getIt<SessionRepository>();
    final scope = VaultScope(
      session.activeServerId ?? '',
      session.activeUserId ?? '',
    );
    return scope.isValid ? scope : null;
  }

  /// The rules of the signed in account, when it has a filtered client.
  static HiddenContentService? get activeService {
    final scope = activeScope;
    if (scope == null) return null;
    final existing = HiddenContentRegistry.instance.existing(scope);
    if (existing != null) return existing;
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<MediaServerClient>()) return null;
    final client = getIt<MediaServerClient>();
    if (client is! VisibilityMediaServerClient) return null;
    return client.visibilityService;
  }

  /// The unfiltered client of the signed in account, for the vault's own
  /// screens and the settings screen.
  static MediaServerClient? get activeUnfilteredClient {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<MediaServerClient>()) return null;
    final client = getIt<MediaServerClient>();
    return client is VisibilityMediaServerClient
        ? client.unfilteredClient
        : client;
  }

  // ---------------------------------------------------------------------------
  // Caches
  // ---------------------------------------------------------------------------

  /// Goes into the home cache key, so rows saved under other rules are never
  /// painted.
  static String get cacheToken => activeService?.fingerprint ?? '0';

  /// [rows] read back from the home cache, minus anything the rules hide
  /// now. The index can have grown since they were saved.
  static List<HomeRow> filterCachedRows(List<HomeRow> rows) {
    final service = activeService;
    if (service == null || !service.isActive) return rows;
    return [
      for (final row in rows)
        row.copyWith(
          items: [
            for (final item in row.items)
              if (!service.isHiddenNow(item.rawData)) item,
          ],
        ),
    ];
  }

  /// [items] minus what the rules hide, from what is in hand. For lists that
  /// never touch the network, such as downloads.
  static List<AggregatedItem> withoutHiddenNow(List<AggregatedItem> items) {
    final service = activeService;
    if (service == null || !service.isActive) return items;
    return [
      for (final item in items)
        if (!service.isHiddenNow(item.rawData)) item,
    ];
  }

  /// Downloaded rows minus hidden content. Saved copies stay on disk; they
  /// just never show up in the normal lists.
  static List<DownloadedItem> withoutHiddenDownloads(List<DownloadedItem> rows) {
    final service = activeService;
    if (service == null || !service.isActive) return rows;
    return [
      for (final row in rows)
        if (!service.isHiddenNow({
          'Id': row.itemId,
          'SeriesId': row.seriesId,
          'SeasonId': row.seasonId,
          'Type': row.type,
        }))
          row,
    ];
  }

  // ---------------------------------------------------------------------------
  // Gates
  // ---------------------------------------------------------------------------

  static bool isRefusal(Object? error) => items_api.isHiddenContentRefusal(error);

  static bool refusePlaybackNow(Object? item) =>
      HiddenContentGate.isRefusedNow(item);

  static Future<bool> refusePlayback(Object? item) =>
      HiddenContentGate.isRefused(item);

  // ---------------------------------------------------------------------------
  // Foreground wiring
  // ---------------------------------------------------------------------------

  /// Hooks the unlock session up to the app: auto-lock on sign out, user and
  /// server switches, app exit and long stays in the background, and keeps
  /// the screens in step when the hidden set grows. Foreground engine only.
  static void initForeground() {
    if (_foregroundReady) return;
    _foregroundReady = true;
    final session = VaultSessionController.instance;
    session.settingsFor = (scope) =>
        HiddenContentRegistry.instance.existing(scope)?.config.settings ??
        const VaultSettings();
    session.isPlaybackActive = _isVaultPlaybackActive;

    _lifecycle = AppLifecycleListener(
      onStateChange: session.onAppLifecycleChanged,
    );
    scheduleMicrotask(_listenForAccountChanges);
    HiddenContentRegistry.instance.changes.addListener(_onRulesChanged);
  }

  static void _listenForAccountChanges() {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<UserRepository>()) return;
    _userSub ??= getIt<UserRepository>().currentUserStream.listen((_) {
      VaultSessionController.instance.onActiveScopeChanged(activeScope);
    });
  }

  static bool _isVaultPlaybackActive(VaultScope scope, String vaultId) {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<PlaybackManager>()) return false;
    final manager = getIt<PlaybackManager>();
    if (!manager.state.isPlaying) return false;
    final current = manager.queueService.currentItem;
    if (current is! AggregatedItem) return false;
    final service = HiddenContentRegistry.instance.existing(scope);
    return service?.belongsToVault(current.rawData, vaultId) ?? false;
  }

  static int _lastSeenGeneration = -1;

  /// When a rebuild found newly hidden items, the rows on screen may hold
  /// them. Reloading them through the filter is enough; nothing is cleared
  /// wholesale.
  static void _onRulesChanged() {
    final service = activeService;
    if (service == null) return;
    if (service.generation == _lastSeenGeneration) return;
    _lastSeenGeneration = service.generation;
    if (service.lastAddedIds.isEmpty) return;
    service.lastAddedIds = const {};
    refreshNormalScreens();
  }

  /// Reloads what the normal app has on screen through the filter. Used after
  /// the rules changed and when a rebuild hid something new.
  static void refreshNormalScreens({bool force = false}) {
    RowDataSource.clearRecommendationCache();
    final getIt = GetIt.instance;
    if (getIt.isRegistered<MediaBarViewModel>()) {
      unawaited(getIt<MediaBarViewModel>().load(force: true));
    }
    homeRefreshBus.requestNowOrAfterNavigation();
  }

  @visibleForTesting
  static void debugResetForeground() {
    _foregroundReady = false;
    _userSub?.cancel();
    _userSub = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _lastSeenGeneration = -1;
  }
}
