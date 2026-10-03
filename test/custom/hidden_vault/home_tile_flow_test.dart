import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_access.dart';
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_touch_hold.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/widgets/focus/hub_focus_memory.dart';
import 'package:moonfin/ui/widgets/focus/locked_focus_row.dart';
import 'package:moonfin/ui/widgets/media_card.dart';
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

/// The whole way in, wired the way the home screen's "My Media" row is: a
/// saved config and PIN, the real trigger check, a [LockedFocusRow] of real
/// [MediaCard]s wrapped in [VaultTouchHold], and the library tiles carrying
/// the client's base URL as their server id, as the home rows do.
void main() {
  late VisibilityMediaServerClient client;
  late List<String> menus;
  late List<String> opened;
  late FocusNode node;

  setUp(() async {
    HubFocusMemory.clearAll();
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<PreferenceStore>(store);
    GetIt.instance.registerSingleton<SessionRepository>(_Session());
    HiddenContentRegistry.debugReset(store: MemoryVaultStore());
    final harness = Harness()..seedStandard();
    client = VisibilityMediaServerClient(
      FakeMediaServerClient(harness.server),
      serverId: scope.serverId,
      onlineItemsApi: () => harness.server,
    );
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    menus = [];
    opened = [];
    node = FocusNode();
  });

  tearDown(() async {
    node.dispose();
    await GetIt.instance.reset();
  });

  AggregatedItem tile(String id, String name) => AggregatedItem(
    id: id,
    serverId: client.baseUrl,
    rawData: {'Id': id, 'Name': name, 'Type': 'CollectionFolder'},
  );

  Future<void> pumpHome(WidgetTester tester) async {
    final items = [
      tile('lib-anime', 'Anime'),
      tile('lib-shows', 'Serien'),
      tile('lib-movies', 'Filme'),
    ];
    void menu(AggregatedItem item) => menus.add(item.name);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => LockedFocusRow<AggregatedItem>(
              items: items,
              hubKey: 'home-my-media',
              itemExtent: 220,
              height: 160,
              focusNode: node,
              onTap: (_, item) => opened.add(item.name),
              onLongPress: (_, item) => menu(item),
              holdSelectEnabled: VaultAccess.isTriggerTile,
              onHoldSelect: (_, item) =>
                  VaultAccess.openFromTile(context, item),
              itemBuilder: (context, item, index, isFocused) {
                final trigger = VaultAccess.isTriggerTile(item);
                return VaultTouchHold(
                  key: ValueKey('tile-${item.id}'),
                  enabled: trigger,
                  onHold: () => VaultAccess.openFromTile(context, item),
                  onLongPress: () => menu(item),
                  child: MediaCard(
                    title: item.name,
                    width: 200,
                    aspectRatio: 16 / 9,
                    externalIsFocused: isFocused,
                    onTap: () => opened.add(item.name),
                    onLongPress: trigger ? null : () => menu(item),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
  }

  Future<void> setUpVault({
    String? trigger = 'lib-anime',
    bool pin = true,
  }) async {
    final config = standardConfig();
    await client.visibilityService!.saveConfig(
      VaultConfig(
        vaults: [
          for (final vault in config.vaults)
            vault.id == 'anime'
                ? VaultDefinition(
                    id: vault.id,
                    name: vault.name,
                    libraries: vault.libraries,
                    triggerLibraryId: trigger,
                  )
                : vault,
        ],
      ),
    );
    if (pin) await VaultAccess.pinFor(scope)!.setPin('1234');
  }

  Future<void> holdKey(WidgetTester tester, Duration duration) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    for (var waited = Duration.zero; waited < duration;) {
      const step = Duration(milliseconds: 250);
      await tester.pump(step);
      waited += step;
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
  }

  Future<void> holdTouch(
    WidgetTester tester,
    String id,
    Duration duration,
  ) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('tile-$id'))),
    );
    await tester.pump(duration);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('TV remote', () {
    testWidgets('5 s on the Anime tile asks for the PIN', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdKey(tester, const Duration(milliseconds: 5250));
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(menus, isEmpty);
      expect(opened, isEmpty);
    });

    testWidgets('a short press still opens the library', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdKey(tester, const Duration(milliseconds: 100));
      expect(opened, ['Anime']);
      expect(find.byType(PinEntryDialog), findsNothing);
    });

    testWidgets('2 s opens the menu, on release', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdKey(tester, const Duration(seconds: 2));
      expect(menus, ['Anime']);
      expect(find.byType(PinEntryDialog), findsNothing);
    });

    testWidgets('a vault saved without a trigger opens from its first '
        'library', (tester) async {
      await setUpVault(trigger: null);
      await pumpHome(tester);
      await holdKey(tester, const Duration(milliseconds: 5250));
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(menus, isEmpty);
    });

    testWidgets('without a PIN the tile keeps its 500 ms menu', (tester) async {
      await setUpVault(pin: false);
      await pumpHome(tester);
      await holdKey(tester, const Duration(milliseconds: 5250));
      expect(menus, ['Anime']);
      expect(find.byType(PinEntryDialog), findsNothing);
    });
  });

  group('touch', () {
    testWidgets('5 s on the Anime tile asks for the PIN', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdTouch(tester, 'lib-anime', const Duration(milliseconds: 5100));
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(menus, isEmpty);
      expect(opened, isEmpty);
    });

    testWidgets('2 s opens the menu, on release', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdTouch(tester, 'lib-anime', const Duration(seconds: 2));
      expect(menus, ['Anime']);
      expect(opened, isEmpty);
    });

    testWidgets('other tiles keep their menu', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdTouch(tester, 'lib-movies', const Duration(milliseconds: 5100));
      expect(menus, ['Filme']);
      expect(find.byType(PinEntryDialog), findsNothing);
    });

    testWidgets('the second vault opens from its own tile', (tester) async {
      await setUpVault();
      await pumpHome(tester);
      await holdTouch(tester, 'lib-shows', const Duration(milliseconds: 5100));
      expect(find.byType(PinEntryDialog), findsOneWidget);
      expect(menus, isEmpty);
    });
  });
}
