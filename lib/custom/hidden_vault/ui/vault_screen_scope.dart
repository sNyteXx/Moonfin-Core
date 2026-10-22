import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:server_core/server_core.dart';

import '../../../data/services/background_service.dart';
import '../../../ui/navigation/destinations.dart';
import '../data/hidden_content_service.dart';
import '../data/vault_repository.dart';
import '../data/vault_store.dart';
import '../hidden_vault.dart';
import '../model/vault_config.dart';
import '../session/vault_session.dart';

/// What a vault screen works with.
class VaultContext {
  final VaultScope scope;
  final VaultDefinition vault;
  final HiddenContentService service;
  final VaultRepository repository;
  final MediaServerClient client;

  const VaultContext({
    required this.scope,
    required this.vault,
    required this.service,
    required this.repository,
    required this.client,
  });
}

/// Wraps every vault screen.
///
/// Marks the vault as open while the screen is mounted, and the moment the
/// vault locks (timeout, sign out, app in the background, leaving it) sends
/// the whole stack home so nothing of it stays on screen. The screens of one
/// visit share a repository, which goes away with the last of them.
class VaultScreenScope extends StatefulWidget {
  final String vaultId;
  final Widget Function(BuildContext context, VaultContext vault) builder;

  const VaultScreenScope({
    super.key,
    required this.vaultId,
    required this.builder,
  });

  static final Map<String, VaultRepository> _repositories = {};
  static final Map<String, int> _mounted = {};

  @override
  State<VaultScreenScope> createState() => _VaultScreenScopeState();
}

class _VaultScreenScopeState extends State<VaultScreenScope> {
  VaultContext? _vault;
  StreamSubscription<(VaultScope, String, VaultLockReason)>? _locks;
  GoRouter? _router;
  bool _entered = false;
  static bool _leaving = false;

  String get _key => '${_vault?.scope.key}#${widget.vaultId}';

  @override
  void initState() {
    super.initState();
    final session = VaultSessionController.instance;
    final scope = HiddenVault.activeScope;
    final service = HiddenVault.activeService;
    final client = HiddenVault.activeUnfilteredClient;
    final vault = service?.config.vault(widget.vaultId);
    if (scope == null ||
        service == null ||
        client == null ||
        vault == null ||
        !session.isUnlocked(scope, widget.vaultId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }
    final key = '${scope.key}#${widget.vaultId}';
    final repository = VaultScreenScope._repositories.putIfAbsent(
      key,
      () => VaultRepository(
        service: service,
        vault: vault,
        api: client.itemsApi,
        serverId: scope.serverId,
      ),
    );
    VaultScreenScope._mounted[key] = (VaultScreenScope._mounted[key] ?? 0) + 1;
    _vault = VaultContext(
      scope: scope,
      vault: vault,
      service: service,
      repository: repository,
      client: client,
    );
    session.enter(scope, widget.vaultId);
    _entered = true;
    _leaving = false;
    _locks = session.lockEvents.listen((event) {
      if (event.$1 == scope && event.$2 == widget.vaultId) _goHome();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _router = GoRouter.maybeOf(context);
  }

  void _goHome() {
    if (_leaving) return;
    _leaving = true;
    _clearBackdrop();
    final router = _router ?? (mounted ? GoRouter.maybeOf(context) : null);
    router?.go(Destinations.home);
  }

  static void _clearBackdrop() {
    final getIt = GetIt.instance;
    if (getIt.isRegistered<BackgroundService>()) {
      getIt<BackgroundService>().clearBackgrounds();
    }
  }

  @override
  void dispose() {
    _locks?.cancel();
    final vault = _vault;
    if (vault != null && _entered) {
      final key = _key;
      final left = (VaultScreenScope._mounted[key] ?? 1) - 1;
      if (left <= 0) {
        VaultScreenScope._mounted.remove(key);
        VaultScreenScope._repositories.remove(key)?.clear();
        // Nothing of the vault may stay behind as the backdrop of the
        // screen underneath.
        _clearBackdrop();
      } else {
        VaultScreenScope._mounted[key] = left;
      }
      VaultSessionController.instance.leave(vault.scope, widget.vaultId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = _vault;
    if (vault == null) {
      return const ColoredBox(color: Colors.black, child: SizedBox.expand());
    }
    return widget.builder(context, vault);
  }
}
