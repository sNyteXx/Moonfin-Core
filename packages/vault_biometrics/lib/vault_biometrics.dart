/// Fingerprint / face unlock for the hidden content vault on phones and
/// tablets. Every platform without an implementation, and every TV, answers
/// "unavailable", so callers can always fall back to the PIN.
library;

import 'package:flutter/services.dart';

enum BiometricResult { success, cancelled, failed, unavailable }

abstract final class VaultBiometrics {
  static const _channel = MethodChannel('org.moonfin.vault_biometrics');

  /// Whether this device can unlock with an enrolled fingerprint or face.
  static Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Shows the system prompt. [cancelLabel] is the button that falls back to
  /// the PIN.
  static Future<BiometricResult> authenticate({
    required String title,
    String? subtitle,
    required String cancelLabel,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('authenticate', {
        'title': title,
        'subtitle': ?subtitle,
        'cancelLabel': cancelLabel,
      });
      return switch (result) {
        'success' => BiometricResult.success,
        'cancelled' => BiometricResult.cancelled,
        'unavailable' => BiometricResult.unavailable,
        _ => BiometricResult.failed,
      };
    } on MissingPluginException {
      return BiometricResult.unavailable;
    } on PlatformException {
      return BiometricResult.failed;
    }
  }
}
