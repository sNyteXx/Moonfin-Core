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
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_touch_hold.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/widgets/media_card.dart';
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

  group('touch hold on trigger tiles', () {
    late List<String> events;

    Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
      events = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: VaultTouchHold(
              enabled: enabled,
              onHold: () => events.add('hold'),
              onLongPress: () => events.add('menu'),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => events.add('tap'),
                onLongPress: enabled ? null : () => events.add('tile-menu'),
                child: const SizedBox(
                  key: ValueKey('tile'),
                  width: 200,
                  height: 200,
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> hold(WidgetTester tester, Duration duration) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('tile'))),
      );
      await tester.pump(duration);
      await gesture.up();
      await tester.pump();
    }

    testWidgets('a tap opens the library', (tester) async {
      await pump(tester);
      await hold(tester, const Duration(milliseconds: 100));
      expect(events, ['tap']);
    });

    testWidgets('a medium press opens the menu on release', (tester) async {
      await pump(tester);
      await hold(tester, const Duration(seconds: 2));
      expect(events, ['menu']);
    });

    testWidgets('five seconds asks for the PIN, nothing else', (tester) async {
      await pump(tester);
      await hold(tester, const Duration(milliseconds: 5100));
      expect(events, ['hold']);
    });

    testWidgets('the real library card: the hold still wins', (tester) async {
      events = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: VaultTouchHold(
              enabled: true,
              onHold: () => events.add('hold'),
              onLongPress: () => events.add('menu'),
              child: MediaCard(
                key: const ValueKey('tile'),
                title: 'Anime',
                width: 200,
                aspectRatio: 16 / 9,
                externalIsFocused: false,
                onTap: () => events.add('tap'),
              ),
            ),
          ),
        ),
      );
      await hold(tester, const Duration(milliseconds: 5100));
      expect(events, ['hold']);
      await hold(tester, const Duration(seconds: 2));
      expect(events, ['hold', 'menu']);
      await hold(tester, const Duration(milliseconds: 100));
      expect(events, ['hold', 'menu', 'tap']);
    });

    testWidgets('dragging the row is not a hold', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('tile'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump(const Duration(seconds: 6));
      await gesture.up();
      await tester.pump();
      expect(events.where((e) => e == 'hold' || e == 'menu'), isEmpty);
    });

    testWidgets('other tiles keep their own long press', (tester) async {
      await pump(tester, enabled: false);
      await hold(tester, const Duration(seconds: 6));
      expect(events, ['tile-menu']);
    });
  });

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
