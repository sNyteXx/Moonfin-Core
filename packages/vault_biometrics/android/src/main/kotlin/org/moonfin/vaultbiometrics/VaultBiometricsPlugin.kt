package org.moonfin.vaultbiometrics

import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Fingerprint / face unlock for the hidden content vault.
 *
 * Uses the framework [BiometricPrompt] (API 29+) rather than the androidx one,
 * so it works with the app's existing activity and doesn't need a
 * FragmentActivity. Television devices always answer "unavailable".
 */
class VaultBiometricsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var pending: CancellationSignal? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        pending?.cancel()
        pending = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "authenticate" -> authenticate(call, result)
            else -> result.notImplemented()
        }
    }

    private fun isTelevision(context: Context): Boolean {
        val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }

    private fun isAvailable(): Boolean {
        val context = appContext ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        if (isTelevision(context)) return false
        val manager = context.getSystemService(BiometricManager::class.java) ?: return false
        val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            manager.canAuthenticate(AUTHENTICATORS)
        } else {
            @Suppress("DEPRECATION")
            manager.canAuthenticate()
        }
        return status == BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun authenticate(call: MethodCall, result: MethodChannel.Result) {
        val host = activity
        if (host == null || !isAvailable() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(RESULT_UNAVAILABLE)
            return
        }
        val title = call.argument<String>("title") ?: ""
        val subtitle = call.argument<String>("subtitle")
        val cancelLabel = call.argument<String>("cancelLabel") ?: "Cancel"
        val answered = AtomicBoolean(false)
        fun reply(value: String) {
            if (answered.compareAndSet(false, true)) {
                pending = null
                result.success(value)
            }
        }

        val executor = host.mainExecutor
        val builder = BiometricPrompt.Builder(host)
            .setTitle(title)
            .setConfirmationRequired(false)
            .setNegativeButton(cancelLabel, executor) { _, _ -> reply(RESULT_CANCELLED) }
        if (!subtitle.isNullOrEmpty()) builder.setSubtitle(subtitle)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(AUTHENTICATORS)
        }

        val cancellation = CancellationSignal()
        pending?.cancel()
        pending = cancellation
        try {
            builder.build().authenticate(
                cancellation,
                executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        authResult: BiometricPrompt.AuthenticationResult?,
                    ) = reply(RESULT_SUCCESS)

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                        val cancelled = errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                        reply(if (cancelled) RESULT_CANCELLED else RESULT_FAILED)
                    }

                    // A single unrecognised touch: the prompt stays up for another try.
                    override fun onAuthenticationFailed() = Unit
                },
            )
        } catch (error: RuntimeException) {
            reply(RESULT_FAILED)
        }
    }

    private companion object {
        const val CHANNEL = "org.moonfin.vault_biometrics"
        const val RESULT_SUCCESS = "success"
        const val RESULT_CANCELLED = "cancelled"
        const val RESULT_FAILED = "failed"
        const val RESULT_UNAVAILABLE = "unavailable"

        // Strong or weak biometrics; the app PIN stays the fallback, so device
        // credentials are not offered here.
        val AUTHENTICATORS: Int
            get() = BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.BIOMETRIC_WEAK
    }
}
