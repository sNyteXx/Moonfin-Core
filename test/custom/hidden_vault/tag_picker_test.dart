import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/ui/vault_settings_screen.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'harness.dart';

class _Session extends Fake implements SessionRepository {
  @override
  String? get activeServerId => scope.serverId;

  @override
  String? get activeUserId => scope.userId;
}

/// The tag picker with a library carrying hundreds of tags, as on a real
/// server: it has to stay quick on a TV box.
void main() {
  late VisibilityMediaServerClient client;
  late FakeJellyfin server;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<PreferenceStore>(store);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    GetIt.instance.registerSingleton<SessionRepository>(_Session());
    HiddenContentRegistry.debugReset(store: MemoryVaultStore());
    server = FakeJellyfin();
    Harness(catalog: server).seedStandard();
    // 600 more tags in the anime library.
    for (var i = 0; i < 600; i++) {
      server.series(
        'lib-anime',
        'extra-$i',
        tags: ['Genre ${i.toString().padLeft(3, '0')}'],
      );
    }
    client = VisibilityMediaServerClient(
      FakeMediaServerClient(server),
      serverId: scope.serverId,
      onlineItemsApi: () => server,
    );
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    await client.visibilityService!.saveConfig(standardConfig());
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  Future<void> openPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const VaultSettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    // The Anime vault in the list of areas, below the ones to open.
    await tester.tap(find.text('Anime').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden tags in Anime'));
    await tester.pumpAndSettle();
  }

  int rowsBuilt(WidgetTester tester) =>
      find.textContaining(RegExp(r'^Genre \d{3}$')).evaluate().length;

  testWidgets('only the rows on screen are built', (tester) async {
    await openPicker(tester);
    expect(rowsBuilt(tester), greaterThan(0));
    expect(rowsBuilt(tester), lessThan(60));
  });

  testWidgets('the filter narrows the list once typing pauses', (tester) async {
    await openPicker(tester);
    await tester.enterText(find.byType(TextField), 'genre 12');
    await tester.pump(const Duration(milliseconds: 50));
    // Not yet: typing hasn't paused.
    expect(find.text('Genre 005'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Genre 005'), findsNothing);
    expect(find.text('Genre 120'), findsOneWidget);
    expect(find.text('Genre 129'), findsOneWidget);
  });

  testWidgets('ticking a tag keeps it in place and saves the choice', (
    tester,
  ) async {
    await openPicker(tester);
    final before = tester.getTopLeft(find.text('Genre 003'));
    await tester.tap(find.text('Genre 003'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Genre 003')), before);
    expect(find.text('2 selected'), findsOneWidget);

    // Back in the editor the library now hides both tags.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('ecchi, Genre 003'), findsOneWidget);
  });
}
