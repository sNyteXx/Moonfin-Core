import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_access.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/widgets/pin_entry_dialog.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_biometrics/vault_biometrics.dart';

import 'harness.dart';

class _Session extends Fake implements SessionRepository {
  @override
  String? get activeServerId => scope.serverId;

  @override
  String? get activeUserId => scope.userId;
}

const _channel = MethodChannel('org.moonfin.vault_biometrics');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('biometric unlock', () {
    late List<MethodCall> calls;
    late String answer;
    late bool available;

    setUp(() async {
      await GetIt.instance.reset();
      SharedPreferences.setMockInitialValues({});
      final store = PreferenceStore();
      await store.init();
      GetIt.instance.registerSingleton<PreferenceStore>(store);
      GetIt.instance.registerSingleton<SessionRepository>(_Session());
      final memory = MemoryVaultStore();
      HiddenContentRegistry.debugReset(store: memory);
      final harness = Harness()..seedStandard();
      final client = VisibilityMediaServerClient(
        FakeMediaServerClient(harness.server),
        serverId: scope.serverId,
        onlineItemsApi: () => harness.server,
      );
      GetIt.instance.registerSingleton<MediaServerClient>(client);
      await client.visibilityService!.saveConfig(standardConfig());
      await VaultAccess.pinFor(scope)!.setPin('1234');

      calls = [];
      answer = 'success';
      available = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'isAvailable' => available,
              'authenticate' => answer,
              _ => null,
            };
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      await GetIt.instance.reset();
    });

    Future<bool?> runVerify(WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await VaultAccess.verify(context, scope),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    Future<void> enableBiometrics() async {
      final service = HiddenContentRegistry.instance.existing(scope)!;
      await service.saveDeviceSettings(
        const VaultDeviceSettings(biometricEnabled: true),
      );
    }

    testWidgets('off by default: the PIN is asked for', (tester) async {
      await runVerify(tester);
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(calls.where((c) => c.method == 'authenticate'), isEmpty);
    });

    testWidgets('a recognised finger unlocks without the PIN', (tester) async {
      await enableBiometrics();
      final result = await runVerify(tester);
      expect(result, isTrue);
      expect(find.byType(PinEntryDialog), findsNothing);
    });

    testWidgets('cancelling falls back to the PIN', (tester) async {
      await enableBiometrics();
      answer = 'cancelled';
      await runVerify(tester);
      expect(find.byType(PinEntryDialog), findsOneWidget);
    });

    testWidgets('a device without biometrics uses the PIN', (tester) async {
      await enableBiometrics();
      available = false;
      await runVerify(tester);
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(calls.where((c) => c.method == 'authenticate'), isEmpty);
    });

    test('a platform without the plugin reads as unavailable', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      expect(await VaultBiometrics.isAvailable(), isFalse);
      expect(
        await VaultBiometrics.authenticate(title: 't', cancelLabel: 'c'),
        BiometricResult.unavailable,
      );
    });
  });
}
