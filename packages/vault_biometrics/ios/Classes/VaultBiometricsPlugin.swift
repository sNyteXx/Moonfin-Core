import Flutter
import LocalAuthentication
import UIKit

/// Face ID / Touch ID unlock for the hidden content vault.
public class VaultBiometricsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "org.moonfin.vault_biometrics",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VaultBiometricsPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      var error: NSError?
      result(LAContext().canEvaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics, error: &error))
    case "authenticate":
      authenticate(arguments: call.arguments as? [String: Any], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authenticate(arguments: [String: Any]?, result: @escaping FlutterResult) {
    let context = LAContext()
    // The app PIN is the fallback, so the system's own password button stays hidden.
    context.localizedFallbackTitle = ""
    if let cancel = arguments?["cancelLabel"] as? String {
      context.localizedCancelTitle = cancel
    }
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    else {
      result("unavailable")
      return
    }
    let reason = (arguments?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unlock"
    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics, localizedReason: reason
    ) { success, evaluationError in
      DispatchQueue.main.async {
        if success {
          result("success")
          return
        }
        switch (evaluationError as? LAError)?.code {
        case .userCancel?, .appCancel?, .systemCancel?, .userFallback?:
          result("cancelled")
        default:
          result("failed")
        }
      }
    }
  }
}
