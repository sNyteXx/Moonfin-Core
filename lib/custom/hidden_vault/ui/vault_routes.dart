import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../preference/user_preferences.dart';

import '../hidden_vault.dart';
import '../session/vault_session.dart';
import 'vault_home_screen.dart';
import 'vault_library_screen.dart';
import 'vault_search_screen.dart';

/// The vault's routes. The path names no vault content, and opening one is
/// decided by the in-memory unlock alone: typing or deep linking a vault
/// path while it's locked lands on home.
abstract final class VaultRoutes {
  static const _root = '/vault';

  static String home(String vaultId) => '$_root/${Uri.encodeComponent(vaultId)}';

  static String library(String vaultId, String libraryId) =>
      '${home(vaultId)}/library/${Uri.encodeComponent(libraryId)}';

  static String search(String vaultId) => '${home(vaultId)}/search';

  static bool get kidsModeActive {
    final getIt = GetIt.instance;
    return getIt.isRegistered<UserPreferences>() &&
        getIt<UserPreferences>().get(UserPreferences.kidsModeEnabled);
  }

  static bool isVaultPath(String path) =>
      path == _root || path.startsWith('$_root/');

  /// For the app router's redirect: where a vault path has to go instead, or
  /// null when it may open.
  static String? redirect(String path, {required String fallback}) {
    if (!isVaultPath(path)) return null;
    final segments = Uri.parse(path).pathSegments;
    if (segments.length < 2) return fallback;
    if (kidsModeActive) return fallback;
    final scope = HiddenVault.activeScope;
    if (scope == null) return fallback;
    final vaultId = segments[1];
    return VaultSessionController.instance.isUnlocked(scope, vaultId)
        ? null
        : fallback;
  }

  static List<RouteBase> routes() => [
    GoRoute(
      path: '$_root/:vaultId',
      builder: (context, state) =>
          VaultHomeScreen(vaultId: state.pathParameters['vaultId'] ?? ''),
      routes: [
        GoRoute(
          path: 'library/:libraryId',
          builder: (context, state) => VaultLibraryScreen(
            vaultId: state.pathParameters['vaultId'] ?? '',
            libraryId: state.pathParameters['libraryId'] ?? '',
          ),
        ),
        GoRoute(
          path: 'search',
          builder: (context, state) =>
              VaultSearchScreen(vaultId: state.pathParameters['vaultId'] ?? ''),
        ),
      ],
    ),
  ];
}
