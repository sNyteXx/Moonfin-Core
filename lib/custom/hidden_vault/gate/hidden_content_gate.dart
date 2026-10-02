import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/services/media_server_client_factory.dart';
import '../data/hidden_content_service.dart';
import '../data/visibility_media_server_client.dart';
import '../session/vault_session.dart';

/// Decides whether an item may be opened or played right now.
///
/// The list filter already keeps hidden items off every screen. This is the
/// backstop for everything that arrives by id instead: deep links, launcher
/// rows, a restored queue, a remote control command. A hidden item passes
/// only while its own vault is unlocked and open.
abstract final class HiddenContentGate {
  static VisibilityMediaServerClient? _clientFor(String serverId) {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<MediaServerClientFactory>()) return null;
    MediaServerClient? client;
    try {
      client = getIt<MediaServerClientFactory>().clientForServerOrActive(
        serverId,
      );
    } catch (_) {
      return null;
    }
    return client is VisibilityMediaServerClient ? client : null;
  }

  static bool _allowedInOpenVault(
    VisibilityMediaServerClient client,
    ItemVerdict verdict,
  ) {
    final vaultId = verdict.vaultId;
    if (vaultId == null) return false;
    final session = VaultSessionController.instance;
    if (!session.isEntered(client.scope, vaultId)) return false;
    session.touch(client.scope, vaultId);
    return true;
  }

  /// From what is in hand, without network. Cheap enough to run over a whole
  /// queue. Something not known yet reads as allowed here and is caught by
  /// [isRefused] for the one item about to play.
  static bool isRefusedNow(Object? item) {
    if (item is! AggregatedItem) return false;
    final client = _clientFor(item.serverId);
    final service = client?.visibilityService;
    if (client == null || service == null || !service.isActive) return false;
    final verdict = service.verdictOf(item.rawData);
    if (!verdict.isHidden) return false;
    return !_allowedInOpenVault(client, verdict);
  }

  /// The authoritative answer for the one item about to open or play.
  static Future<bool> isRefused(Object? item) async {
    if (item is! AggregatedItem) return false;
    final client = _clientFor(item.serverId);
    final service = client?.visibilityService;
    if (client == null || service == null || !service.isActive) return false;
    final verdict = await service.settledVerdict(item.rawData);
    if (!verdict.isHidden) return false;
    return !_allowedInOpenVault(client, verdict);
  }
}
