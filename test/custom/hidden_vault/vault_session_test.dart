import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';
import 'package:moonfin/custom/hidden_vault/session/vault_session.dart';

void main() {
  const scope = VaultScope('server-1', 'user-1');
  const otherUser = VaultScope('server-1', 'user-2');
  const otherServer = VaultScope('server-2', 'user-1');

  late DateTime now;
  late VaultSettings settings;
  late VaultSessionController session;
  late List<(VaultScope, String, VaultLockReason)> locks;

  setUp(() {
    now = DateTime(2026, 10, 2, 20);
    settings = const VaultSettings(autoLockMinutes: 15, lockOnLeave: true);
    session = VaultSessionController(
      now: () => now,
      settingsFor: (_) => settings,
    );
    locks = [];
    session.lockEvents.listen(locks.add);
  });

  tearDown(() => session.dispose());

  test('starts locked; nothing survives a new controller (app restart)', () {
    expect(session.isUnlocked(scope, 'anime'), isFalse);
    session.unlock(scope, 'anime');
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    final restarted = VaultSessionController(now: () => now);
    expect(restarted.isUnlocked(scope, 'anime'), isFalse);
    restarted.dispose();
  });

  test('unlocked is not entered: item calls stay closed until the vault '
      'screens are on screen', () {
    session.unlock(scope, 'anime');
    expect(session.enteredVaults(scope), isEmpty);
    session.enter(scope, 'anime');
    expect(session.enteredVaults(scope), {'anime'});
    expect(session.enteredVaults(otherUser), isEmpty);
  });

  test('vaults are separate', () {
    session.unlock(scope, 'anime');
    expect(session.isUnlocked(scope, 'shows'), isFalse);
  });

  test('leaving the vault locks it by default', () async {
    session.unlock(scope, 'anime');
    session.enter(scope, 'anime');
    session.enter(scope, 'anime'); // vault home + library screen
    session.leave(scope, 'anime');
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    session.leave(scope, 'anime');
    expect(session.isUnlocked(scope, 'anime'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(locks.single.$3, VaultLockReason.leftVault);
  });

  test('with lock-on-leave off, the timeout still applies', () {
    settings = const VaultSettings(autoLockMinutes: 5, lockOnLeave: false);
    session.unlock(scope, 'anime');
    session.enter(scope, 'anime');
    session.leave(scope, 'anime');
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    expect(session.enteredVaults(scope), isEmpty);
    now = now.add(const Duration(minutes: 4));
    session.checkTimeouts();
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    now = now.add(const Duration(minutes: 2));
    session.checkTimeouts();
    expect(session.isUnlocked(scope, 'anime'), isFalse);
  });

  test('activity keeps it open, inactivity locks it', () {
    session.unlock(scope, 'anime');
    session.enter(scope, 'anime');
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(minutes: 10));
      session.touch(scope, 'anime');
      session.checkTimeouts();
    }
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    now = now.add(const Duration(minutes: 16));
    session.checkTimeouts();
    expect(session.isUnlocked(scope, 'anime'), isFalse);
  });

  test('playing vault content counts as activity', () {
    var playing = true;
    session.isPlaybackActive = (_, _) => playing;
    session.unlock(scope, 'anime');
    session.enter(scope, 'anime');
    now = now.add(const Duration(minutes: 40));
    session.checkTimeouts();
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    playing = false;
    now = now.add(const Duration(minutes: 16));
    session.checkTimeouts();
    expect(session.isUnlocked(scope, 'anime'), isFalse);
  });

  test('user switch, server switch and sign out lock', () {
    session.unlock(scope, 'anime');
    session.unlock(scope, 'shows');
    session.onActiveScopeChanged(scope);
    expect(session.isUnlocked(scope, 'anime'), isTrue);
    session.onActiveScopeChanged(otherUser);
    expect(session.hasUnlocked, isFalse);

    session.unlock(scope, 'anime');
    session.onActiveScopeChanged(otherServer);
    expect(session.hasUnlocked, isFalse);

    session.unlock(scope, 'anime');
    session.onActiveScopeChanged(null);
    expect(session.hasUnlocked, isFalse);
  });

  test('app exit locks; a short trip to the background does not', () {
    session.unlock(scope, 'anime');
    session.onAppLifecycleChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 2));
    session.onAppLifecycleChanged(AppLifecycleState.resumed);
    expect(session.isUnlocked(scope, 'anime'), isTrue);

    session.onAppLifecycleChanged(AppLifecycleState.hidden);
    now = now.add(const Duration(minutes: 20));
    session.onAppLifecycleChanged(AppLifecycleState.resumed);
    expect(session.isUnlocked(scope, 'anime'), isFalse);

    session.unlock(scope, 'anime');
    session.onAppLifecycleChanged(AppLifecycleState.detached);
    expect(session.isUnlocked(scope, 'anime'), isFalse);
  });

  test('every lock is announced so open vault screens can leave', () async {
    session.unlock(scope, 'anime');
    session.lock(scope, 'anime', VaultLockReason.manual);
    session.lock(scope, 'anime', VaultLockReason.manual);
    await Future<void>.delayed(Duration.zero);
    expect(locks, hasLength(1));
    expect(locks.single.$2, 'anime');
  });
}
