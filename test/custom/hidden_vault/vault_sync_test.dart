import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_service.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_config_sync.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';
import 'package:server_core/server_core.dart';

import 'fake_server.dart';
import 'harness.dart';

/// The server's per-user display preferences, shared by every device.
class FakeDisplayPreferences implements DisplayPreferencesApi {
  final Map<String, Map<String, String>> store = {};
  bool offline = false;
  Completer<void>? hold;
  int gets = 0;
  int saves = 0;

  @override
  Future<DisplayPreferences> getDisplayPreferences(
    String id, {
    String? client,
  }) async {
    gets++;
    if (hold != null) await hold!.future;
    if (offline) throw StateError('offline');
    return DisplayPreferences(
      id: id,
      customPrefs: Map.of(store['$client/$id'] ?? const {}),
    );
  }

  @override
  Future<void> saveDisplayPreferences(
    String id,
    DisplayPreferences prefs, {
    String? client,
  }) async {
    if (offline) throw StateError('offline');
    saves++;
    store['$client/$id'] = Map.of(prefs.customPrefs);
  }
}

class Device {
  final FakeJellyfin server;
  final FakeDisplayPreferences prefs;
  final MemoryVaultStore store = MemoryVaultStore();
  late HiddenContentService service;
  DateTime now;

  Device(this.server, this.prefs, this.now) {
    start();
  }

  void start() {
    service = HiddenContentService(
      scope: scope,
      store: store,
      onlineApi: () => server,
      syncApi: () => prefs,
      now: () => now,
    );
  }
}

void main() {
  late FakeJellyfin server;
  late FakeDisplayPreferences prefs;

  setUp(() {
    server = FakeJellyfin();
    Harness(catalog: server).seedStandard();
    prefs = FakeDisplayPreferences();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'a config saved on the TV hides the same content on the phone',
    () async {
      final tv = Device(server, prefs, DateTime(2026, 10, 2, 20));
      await tv.service.saveConfig(standardConfig());
      await settle();
      expect(prefs.saves, 1);

      final phone = Device(server, prefs, DateTime(2026, 10, 2, 21));
      expect(phone.service.isActive, isFalse);
      await phone.service.ensureReady();
      expect(phone.service.isActive, isTrue);
      expect(phone.service.config.fingerprint, tv.service.config.fingerprint);
      expect(phone.service.index!.contains('a1'), isTrue);
    },
  );

  test(
    'only the rules travel: no PIN, no index, no unlock, no device choices',
    () async {
      final tv = Device(server, prefs, DateTime(2026, 10, 2, 20));
      await tv.service.saveDeviceSettings(
        const VaultDeviceSettings(biometricEnabled: true),
      );
      await tv.service.saveConfig(standardConfig());
      await settle();
      final stored =
          prefs.store['${VaultConfigSync.client}/'
              '${VaultConfigSync.preferencesId}']!;
      expect(stored.keys, [VaultConfigSync.key]);
      final json = jsonDecode(stored[VaultConfigSync.key]!) as Map;
      expect(json.keys.toSet(), {
        'v',
        'revision',
        'updatedAt',
        'vaults',
        'settings',
      });
      expect(stored.values.single, isNot(contains('pin')));
      expect(stored.values.single, isNot(contains('biometric')));
    },
  );

  test('the newer copy wins, in both directions', () async {
    final tv = Device(server, prefs, DateTime(2026, 10, 2, 20));
    await tv.service.saveConfig(standardConfig());
    await settle();

    final phone = Device(server, prefs, DateTime(2026, 10, 2, 21));
    await phone.service.ensureReady();
    // The phone narrows the anime vault later than the TV saved.
    await phone.service.saveConfig(
      VaultConfig(
        vaults: [
          VaultDefinition(
            id: 'anime',
            name: 'Anime',
            libraries: [
              VaultLibrary(
                libraryId: 'lib-anime',
                name: 'Anime',
                tags: ['Action'],
              ),
            ],
          ),
        ],
      ),
    );
    await settle();

    // The TV picks that up on its next start.
    tv.now = DateTime(2026, 10, 2, 22);
    tv.start();
    await tv.service.ensureReady();
    expect(tv.service.index!.contains('a5'), isTrue);
    expect(tv.service.index!.contains('a1'), isFalse);

    // An older copy on the server never overwrites a newer local one.
    expect(await phone.service.syncNow(), isFalse);
  });

  test('a save made offline reaches the server on the next sync', () async {
    final tv = Device(server, prefs, DateTime(2026, 10, 2, 20));
    prefs.offline = true;
    await tv.service.saveConfig(standardConfig());
    await settle();
    expect(prefs.saves, 0);
    prefs.offline = false;
    await tv.service.syncNow();
    expect(prefs.saves, 1);
    final phone = Device(server, prefs, DateTime(2026, 10, 2, 21));
    await phone.service.ensureReady();
    expect(phone.service.isActive, isTrue);
  });

  test('sync off: nothing read, nothing written', () async {
    final tv = Device(server, prefs, DateTime(2026, 10, 2, 20));
    await tv.service.saveConfig(standardConfig());
    await settle();

    final phone = Device(server, prefs, DateTime(2026, 10, 2, 21));
    await phone.service.saveDeviceSettings(
      const VaultDeviceSettings(syncEnabled: false),
    );
    phone.start();
    prefs.gets = 0;
    await phone.service.ensureReady();
    expect(prefs.gets, 0);
    expect(phone.service.isActive, isFalse);

    // Turning it back on pulls straight away.
    await phone.service.saveDeviceSettings(const VaultDeviceSettings());
    expect(phone.service.isActive, isTrue);
  });

  test('a slow server holds the first lists back only briefly', () async {
    final tv = Device(server, prefs, DateTime(2026, 10, 2, 20));
    await tv.service.saveConfig(standardConfig());
    await settle();

    prefs.hold = Completer<void>();
    final phone = Device(server, prefs, DateTime(2026, 10, 2, 21));
    final watch = Stopwatch()..start();
    await phone.service.ensureReady();
    watch.stop();
    expect(watch.elapsed, lessThan(HiddenContentService.syncWait * 2));
    expect(phone.service.isActive, isFalse);
    // The newer config still applies the moment it arrives.
    prefs.hold!.complete();
    prefs.hold = null;
    for (var i = 0; i < 50 && !phone.service.isActive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(phone.service.isActive, isTrue);
  });
}
