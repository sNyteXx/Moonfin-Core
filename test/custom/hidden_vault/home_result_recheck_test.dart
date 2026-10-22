import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/custom/hidden_vault/hidden_vault.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:server_core/server_core.dart';

import 'fake_server.dart';
import 'harness.dart' show standardConfig;

class _MockClient extends Mock implements MediaServerClient {}

void main() {
  setUp(() => HiddenContentRegistry.debugReset(store: MemoryVaultStore()));
  tearDown(HiddenContentRegistry.debugReset);

  AggregatedItem item(String serverId) => AggregatedItem(
    id: 'same-item-id',
    serverId: serverId,
    rawData: {'Id': 'same-item-id', 'Type': 'Movie', 'Tags': <String>[]},
  );

  Future<MediaServerClient> client(
    String serverId, {
    required bool hidden,
  }) async {
    final server = FakeJellyfin();
    server.movie('lib-shows', 'same-item-id', tags: hidden ? ['private'] : []);
    final inner = _MockClient();
    when(() => inner.userId).thenReturn('user');
    final service = HiddenContentRegistry.instance.serviceFor(
      VaultScope(serverId, 'user'),
      onlineApi: () => server,
    )!;
    await service.saveConfig(standardConfig());
    return VisibilityMediaServerClient(
      inner,
      serverId: serverId,
      onlineItemsApi: () => server,
    );
  }

  test('late aggregated items use the policy of their own server', () async {
    final clients = {
      'hidden-server': await client('hidden-server', hidden: true),
      'visible-server': await client('visible-server', hidden: false),
    };

    final result = HiddenVault.recheckVisibleItems([
      item('hidden-server'),
      item('visible-server'),
    ], clients);

    expect(result.map((item) => item.serverId), ['visible-server']);
  });

  test('an item whose original client is no longer known remains hidden', () {
    expect(
      HiddenVault.recheckVisibleItems([item('missing-server')], {}),
      isEmpty,
    );
  });

  test('a visibility client without a valid account remains closed', () {
    final inner = _MockClient();
    when(() => inner.userId).thenReturn(null);
    final guarded = VisibilityMediaServerClient(inner, serverId: 'signed-out');

    expect(
      HiddenVault.recheckVisibleItems(
        [item('signed-out')],
        {'signed-out': guarded},
      ),
      isEmpty,
    );
  });
}
