import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/vault_store.dart';
import '../model/vault_config.dart';

enum VaultLockReason {
  manual,
  timeout,
  leftVault,
  background,
  appExit,
  accountChanged,
  configChanged,
}

class _Unlock {
  final DateTime unlockedAt;
  DateTime lastActivity;
  int entered = 0;

  _Unlock(this.unlockedAt) : lastActivity = unlockedAt;
}

/// Which vaults are open right now. Memory only, on purpose.
///
/// Nothing here is ever written down, so a restart, a crash or the process
/// being killed always comes back locked. An unlock never changes what the
/// normal app shows; it only lets the vault's own screens open, and item
/// specific calls through while the vault is [isEntered].
class VaultSessionController extends ChangeNotifier {
  static VaultSessionController instance = VaultSessionController();

  final DateTime Function() _now;

  /// The session settings of an account, read on every check so a change in
  /// the settings screen applies at once.
  VaultSettings Function(VaultScope scope) settingsFor;

  /// Whether something from [vaultId] is playing, which counts as activity:
  /// an episode longer than the timeout must not lock mid-way.
  bool Function(VaultScope scope, String vaultId)? isPlaybackActive;

  final Map<String, _Unlock> _unlocks = {};
  final Map<String, VaultScope> _scopes = {};
  final StreamController<(VaultScope, String, VaultLockReason)> _locks =
      StreamController.broadcast();
  Timer? _ticker;
  DateTime? _backgroundedAt;

  VaultSessionController({
    DateTime Function()? now,
    VaultSettings Function(VaultScope scope)? settingsFor,
  }) : _now = now ?? DateTime.now,
       settingsFor = settingsFor ?? ((_) => const VaultSettings());

  @visibleForTesting
  static VaultSessionController debugReset({
    DateTime Function()? now,
    VaultSettings Function(VaultScope scope)? settingsFor,
  }) {
    instance.dispose();
    return instance = VaultSessionController(
      now: now,
      settingsFor: settingsFor,
    );
  }

  /// Fires once per vault that locks, with the reason.
  Stream<(VaultScope, String, VaultLockReason)> get lockEvents =>
      _locks.stream;

  static String _key(VaultScope scope, String vaultId) =>
      '${scope.key}#$vaultId';

  bool get hasUnlocked => _unlocks.isNotEmpty;

  bool isUnlocked(VaultScope scope, String vaultId) =>
      _unlocks.containsKey(_key(scope, vaultId));

  bool isEntered(VaultScope scope, String vaultId) =>
      (_unlocks[_key(scope, vaultId)]?.entered ?? 0) > 0;

  /// The vaults of [scope] that are unlocked and on screen.
  Set<String> enteredVaults(VaultScope scope) {
    if (_unlocks.isEmpty) return const {};
    final prefix = '${scope.key}#';
    return {
      for (final entry in _unlocks.entries)
        if (entry.value.entered > 0 && entry.key.startsWith(prefix))
          entry.key.substring(prefix.length),
    };
  }

  void unlock(VaultScope scope, String vaultId) {
    final key = _key(scope, vaultId);
    _unlocks[key] = _Unlock(_now());
    _scopes[key] = scope;
    _ensureTicker();
    notifyListeners();
  }

  /// Marks the vault's screens as on screen. Pair with [leave].
  void enter(VaultScope scope, String vaultId) {
    final unlock = _unlocks[_key(scope, vaultId)];
    if (unlock == null) return;
    unlock.entered++;
    unlock.lastActivity = _now();
    notifyListeners();
  }

  void leave(VaultScope scope, String vaultId) {
    final key = _key(scope, vaultId);
    final unlock = _unlocks[key];
    if (unlock == null) return;
    if (unlock.entered > 0) unlock.entered--;
    unlock.lastActivity = _now();
    if (unlock.entered == 0 && settingsFor(scope).lockOnLeave) {
      lock(scope, vaultId, VaultLockReason.leftVault);
      return;
    }
    notifyListeners();
  }

  /// Anything done inside the vault keeps it open.
  void touch(VaultScope scope, String vaultId) {
    _unlocks[_key(scope, vaultId)]?.lastActivity = _now();
  }

  void lock(VaultScope scope, String vaultId, VaultLockReason reason) {
    final key = _key(scope, vaultId);
    if (_unlocks.remove(key) == null) return;
    _scopes.remove(key);
    if (_unlocks.isEmpty) _stopTicker();
    _locks.add((scope, vaultId, reason));
    notifyListeners();
  }

  void lockAll(VaultLockReason reason) {
    for (final key in _unlocks.keys.toList()) {
      final scope = _scopes[key];
      if (scope == null) continue;
      lock(scope, key.substring(scope.key.length + 1), reason);
    }
  }

  /// Locks every vault that isn't [active]'s: a sign out, a user switch and
  /// a server switch all land here.
  void onActiveScopeChanged(VaultScope? active) {
    for (final key in _unlocks.keys.toList()) {
      final scope = _scopes[key];
      if (scope == null || scope == active) continue;
      lock(
        scope,
        key.substring(scope.key.length + 1),
        VaultLockReason.accountChanged,
      );
    }
  }

  /// Background longer than the timeout locks, and the engine detaching
  /// locks at once.
  void onAppLifecycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.detached:
        lockAll(VaultLockReason.appExit);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= _now();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since == null) return;
        final away = _now().difference(since);
        for (final key in _unlocks.keys.toList()) {
          final scope = _scopes[key];
          if (scope == null) continue;
          if (away >= settingsFor(scope).autoLockAfter) {
            lock(
              scope,
              key.substring(scope.key.length + 1),
              VaultLockReason.background,
            );
          }
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Applies the inactivity timeout. Runs on a timer while anything is
  /// unlocked; public so tests can drive it.
  void checkTimeouts() {
    final now = _now();
    for (final entry in _unlocks.entries.toList()) {
      final scope = _scopes[entry.key];
      if (scope == null) continue;
      final vaultId = entry.key.substring(scope.key.length + 1);
      if (isPlaybackActive?.call(scope, vaultId) ?? false) {
        entry.value.lastActivity = now;
        continue;
      }
      final idle = now.difference(entry.value.lastActivity);
      if (idle >= settingsFor(scope).autoLockAfter) {
        lock(scope, vaultId, VaultLockReason.timeout);
      }
    }
  }

  void _ensureTicker() {
    _ticker ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => checkTimeouts(),
    );
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopTicker();
    _locks.close();
    super.dispose();
  }
}
