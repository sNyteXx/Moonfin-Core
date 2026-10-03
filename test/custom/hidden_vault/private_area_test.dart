import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/session/vault_session.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_access.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_home_screen.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_routes.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_settings_screen.dart';
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_card_metrics.dart';
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_item_card.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/info_area.dart';
import 'package:moonfin/ui/widgets/pin_entry_dialog.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

class _Session extends Fake implements SessionRepository {
  @override
  String? get activeServerId => scope.serverId;

  @override
  String? get activeUserId => scope.userId;
}

/// The way in: tapping "Version" under About asks for the PIN, the private
/// area opens on its vaults, and each one leads to its own home.
void main() {
  late VisibilityMediaServerClient client;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<PreferenceStore>(store);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    GetIt.instance.registerSingleton<SessionRepository>(_Session());
    HiddenContentRegistry.debugReset(store: MemoryVaultStore());
    VaultSessionController.debugReset();
    final harness = Harness()..seedStandard();
    client = VisibilityMediaServerClient(
      FakeMediaServerClient(harness.server),
      serverId: scope.serverId,
      onlineItemsApi: () => harness.server,
    );
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    GetIt.instance.registerSingleton<MediaServerClientFactory>(
      FakeClientFactory(client),
    );
    await client.visibilityService!.saveConfig(standardConfig());
  });

  tearDown(() async {
    VaultSessionController.debugReset();
    await GetIt.instance.reset();
  });

  Future<GoRouter> pumpApp(WidgetTester tester) async {
    // A TV-sized window, as the dialogs are laid out for one.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/',
      redirect: (context, state) =>
          VaultRoutes.redirect(state.uri.path, fallback: '/'),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Builder(
              builder: (context) => ListTile(
                title: const Text('Version'),
                onTap: () => VaultSettingsEntry.open(context),
              ),
            ),
          ),
        ),
        ...VaultRoutes.routes(),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.sendKeyEvent(
        LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(digit)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('Version → PIN → the vault list → the Anime home', (
    tester,
  ) async {
    await VaultAccess.pinFor(scope)!.setPin('1234');
    final router = await pumpApp(tester);

    await tester.tap(find.text('Version'));
    await tester.pumpAndSettle();
    expect(find.byType(PinEntryDialog), findsOneWidget);

    await typePin(tester, '1234');
    expect(find.byType(VaultSettingsScreen), findsOneWidget);
    // The vaults to open come first.
    final anime = find.text('Anime').first;
    expect(find.text('Serien/Filme'), findsWidgets);

    await tester.tap(anime);
    await tester.pumpAndSettle();
    expect(find.byType(VaultHomeScreen), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      VaultRoutes.home('anime'),
    );
    expect(VaultSessionController.instance.isUnlocked(scope, 'anime'), isTrue);
    expect(VaultSessionController.instance.isUnlocked(scope, 'shows'), isFalse);
  });

  testWidgets('the vault home works like the home screen', (tester) async {
    await VaultAccess.pinFor(scope)!.setPin('1234');
    await pumpApp(tester);
    await tester.tap(find.text('Version'));
    await tester.pumpAndSettle();
    await typePin(tester, '1234');
    await tester.tap(find.text('Anime').first);
    await tester.pumpAndSettle();

    AggregatedItem? focused() =>
        tester.widget<InfoArea>(find.byType(InfoArea)).item;

    // Focus starts on the top row, continue watching, and the info area
    // shows that title.
    await tester.pump(const Duration(milliseconds: 200));
    expect(['a2e1', 'm1'], contains(focused()?.id));

    // Down: next up.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(focused()?.id, 'a1e1');

    // Down again: recently added, then right along the row.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    final first = focused()?.id;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(focused()?.id, isNot(first));

    // The rows only ever hold this vault's titles, no ordinary ones.
    for (final id in ['a3', 'a5', 's1', 's2', 'f2']) {
      expect(find.text(id), findsNothing);
    }
  });

  testWidgets('the library grid and search lay out their cards', (
    tester,
  ) async {
    await VaultAccess.pinFor(scope)!.setPin('1234');
    final router = await pumpApp(tester);
    await tester.tap(find.text('Version'));
    await tester.pumpAndSettle();
    await typePin(tester, '1234');
    await tester.tap(find.text('Anime').first);
    await tester.pumpAndSettle();

    unawaited(router.push(VaultRoutes.library('anime', 'lib-anime')));
    await tester.pumpAndSettle();
    expect(find.byType(VaultItemCard), findsNWidgets(2));
    // Room above the first row for a focused card to grow into.
    final grid = tester.widget<GridView>(find.byType(GridView));
    final metrics = VaultCardMetrics.of(landscape: false);
    expect(
      (grid.padding! as EdgeInsets).top,
      greaterThanOrEqualTo(metrics.headroom),
    );

    unawaited(router.push(VaultRoutes.search('anime')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'a');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byType(VaultItemCard), findsWidgets);
  });

  testWidgets('a wrong PIN keeps it all closed', (tester) async {
    await VaultAccess.pinFor(scope)!.setPin('1234');
    await pumpApp(tester);

    await tester.tap(find.text('Version'));
    await tester.pumpAndSettle();
    await typePin(tester, '9999');
    expect(find.byType(VaultSettingsScreen), findsNothing);
    expect(find.byType(VaultHomeScreen), findsNothing);
    expect(VaultSessionController.instance.isUnlocked(scope, 'anime'), isFalse);
  });

  testWidgets('a vault link without the PIN goes nowhere', (tester) async {
    await VaultAccess.pinFor(scope)!.setPin('1234');
    final router = await pumpApp(tester);
    router.go(VaultRoutes.home('anime'));
    await tester.pumpAndSettle();
    expect(find.byType(VaultHomeScreen), findsNothing);
    expect(find.text('Version'), findsOneWidget);
  });
}
