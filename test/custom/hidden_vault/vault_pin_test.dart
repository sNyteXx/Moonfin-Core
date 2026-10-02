import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/util/pin_code_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferenceStore store;
  const scope = VaultScope('server-1', 'user-1');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = PreferenceStore();
    await store.init();
  });

  test(
    'the vault PIN is its own, never the sign in or Kids Mode PIN',
    () async {
      final vault = PinCodeUtil.vault(store, scope.key);
      final kids = PinCodeUtil.kidsMode(store, scope.userId);
      final login = PinCodeUtil(store, scope.userId);
      await vault.setPin('1234');
      expect(vault.isPinEnabled, isTrue);
      expect(kids.isPinEnabled, isFalse);
      expect(login.isPinEnabled, isFalse);

      await kids.setPin('1234');
      expect(kids.verifyPin('1234'), isTrue);
      expect(vault.verifyPin('1234'), isTrue);
      await kids.removePin();
      expect(vault.verifyPin('1234'), isTrue);
    },
  );

  test('stored hashed and salted, never in clear', () async {
    final vault = PinCodeUtil.vault(store, scope.key);
    await vault.setPin('4711');
    final prefs = await SharedPreferences.getInstance();
    final keys = store.keys;
    for (final key in keys) {
      expect(prefs.get(key)?.toString(), isNot(contains('4711')));
    }
    expect(keys.where((k) => k.startsWith('vault_pin_hash_')), hasLength(1));
    // Same digits, other namespace: a different hash.
    final kids = PinCodeUtil.kidsMode(store, scope.key);
    await kids.setPin('4711');
    expect(
      store.getString('vault_pin_hash_${scope.key}'),
      isNot(store.getString('kids_pin_hash_${scope.key}')),
    );
  });

  test('scoped per server and user', () async {
    await PinCodeUtil.vault(store, scope.key).setPin('1111');
    final otherUser = PinCodeUtil.vault(
      store,
      const VaultScope('server-1', 'user-2').key,
    );
    final otherServer = PinCodeUtil.vault(
      store,
      const VaultScope('server-2', 'user-1').key,
    );
    expect(otherUser.isPinEnabled, isFalse);
    expect(otherServer.isPinEnabled, isFalse);
    expect(otherUser.verifyPin('1111'), isFalse);
  });

  test('wrong guesses lock out like Kids Mode', () async {
    final vault = PinCodeUtil.vault(store, scope.key);
    await vault.setPin('2468');
    for (var i = 0; i < 5; i++) {
      expect(vault.verifyPin('0000'), isFalse);
      expect(await vault.registerFailedAttempt(), Duration.zero);
    }
    expect(await vault.registerFailedAttempt(), const Duration(seconds: 30));
    expect(vault.isLockedOut, isTrue);
    expect(vault.verifyPin('2468'), isFalse, reason: 'refused while locked');
    await vault.clearFailedAttempts();
    expect(vault.verifyPin('2468'), isTrue);
  });
}
