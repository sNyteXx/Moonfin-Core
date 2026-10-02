import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:vault_biometrics/vault_biometrics.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../ui/widgets/pin_entry_dialog.dart';
import '../../../util/pin_code_util.dart';
import '../../../util/platform_detection.dart';
import '../data/hidden_content_service.dart';
import '../data/vault_store.dart';
import '../hidden_vault.dart';
import '../model/vault_config.dart';
import '../session/vault_session.dart';
import 'vault_routes.dart';
import 'vault_strings.dart';

/// PIN checks and the way into a vault.
abstract final class VaultAccess {
  /// The vault PIN of [scope], never the sign in or Kids Mode PIN.
  static PinCodeUtil? pinFor(VaultScope scope) {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<PreferenceStore>()) return null;
    return PinCodeUtil.vault(getIt<PreferenceStore>(), scope.key);
  }

  static bool hasPin(VaultScope scope) => pinFor(scope)?.isPinEnabled ?? false;

  /// Asks for the PIN with the shared lockout. True when it checked out.
  static Future<bool> verifyPin(BuildContext context, VaultScope scope) async {
    final pin = pinFor(scope);
    if (pin == null || !pin.isPinEnabled) return false;
    final ok = await PinEntryDialog.show(
      context,
      mode: PinEntryMode.verify,
      onVerify: pin.verifyPin,
      onFailedAttempt: pin.registerFailedAttempt,
      lockoutRemaining: () => pin.lockoutRemaining,
    );
    if (ok) await pin.clearFailedAttempts();
    return ok;
  }

  /// Whether this device may offer a fingerprint or face instead of the PIN.
  /// Never on a TV.
  static Future<bool> biometricsAvailable() async {
    if (PlatformDetection.isTV) return false;
    return VaultBiometrics.isAvailable();
  }

  /// Fingerprint or face first when this device opted in, the PIN when that
  /// is off, unavailable, cancelled or fails.
  static Future<bool> verify(BuildContext context, VaultScope scope) async {
    final service = HiddenVault.activeService;
    final useBiometrics =
        service != null &&
        service.deviceSettings.biometricEnabled &&
        await biometricsAvailable();
    if (!context.mounted) return false;
    if (useBiometrics) {
      final s = VaultStrings.of(context);
      final result = await VaultBiometrics.authenticate(
        title: s.biometricPrompt,
        cancelLabel: s.usePin,
      );
      if (result == BiometricResult.success) return true;
      if (!context.mounted) return false;
    }
    return verifyPin(context, scope);
  }

  /// Picks a new PIN (entered twice).
  static Future<bool> setPin(BuildContext context, VaultScope scope) async {
    final pin = pinFor(scope);
    if (pin == null) return false;
    return PinEntryDialog.show(
      context,
      mode: PinEntryMode.set,
      onPinSet: pin.setPin,
    );
  }

  /// The vault whose trigger tile [item] is, when one is set up completely:
  /// rules, a trigger on this library and a PIN. Anything less and the tile
  /// behaves exactly like every other one.
  static VaultDefinition? vaultForTile(AggregatedItem item) {
    final scope = HiddenVault.activeScope;
    if (scope == null || VaultRoutes.kidsModeActive) return null;
    final HiddenContentService? service = HiddenVault.activeService;
    if (service == null) return null;
    if (item.serverId != scope.serverId &&
        item.serverId != HiddenVault.activeUnfilteredClient?.baseUrl) {
      return null;
    }
    final vault = service.config.vaultForTrigger(item.id);
    if (vault == null || !vault.hasRules) return null;
    if (!hasPin(scope)) return null;
    return vault;
  }

  static bool isTriggerTile(AggregatedItem item) => vaultForTile(item) != null;

  /// The long hold on a trigger tile: PIN, then the vault.
  static Future<void> openFromTile(
    BuildContext context,
    AggregatedItem item,
  ) async {
    final vault = vaultForTile(item);
    final scope = HiddenVault.activeScope;
    if (vault == null || scope == null) return;
    await open(context, scope, vault.id);
  }

  /// Opens [vaultId], asking for the PIN unless it is still unlocked.
  static Future<void> open(
    BuildContext context,
    VaultScope scope,
    String vaultId,
  ) async {
    final session = VaultSessionController.instance;
    if (!session.isUnlocked(scope, vaultId)) {
      final ok = await verify(context, scope);
      if (!ok || !context.mounted) return;
      session.unlock(scope, vaultId);
    }
    if (!context.mounted) return;
    await GoRouter.of(context).push(VaultRoutes.home(vaultId));
  }
}
