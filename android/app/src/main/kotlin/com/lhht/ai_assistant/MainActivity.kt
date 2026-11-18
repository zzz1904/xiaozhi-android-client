package com.lhht.ai_assistant

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var assistantChannel: MethodChannel? = null
    private var assistantLaunchPending = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        assistantLaunchPending =
            assistantLaunchPending || isAssistantLaunchIntent(intent)
        assistantChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ASSISTANT_CHANNEL
        )
        assistantChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeAssistantLaunch" -> {
                    val pending = assistantLaunchPending
                    assistantLaunchPending = false
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (assistantLaunchPending) {
            assistantChannel?.invokeMethod("assistantLaunch", null)
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isAssistantLaunchIntent(intent)) {
            assistantLaunchPending = true
            assistantChannel?.invokeMethod("assistantLaunch", null)
        }
    }

    private fun isAssistantLaunchIntent(intent: Intent?): Boolean {
        return intent?.getBooleanExtra(EXTRA_ASSISTANT_LAUNCH, false) == true ||
            intent?.action == Intent.ACTION_ASSIST
    }

    companion object {
        const val EXTRA_ASSISTANT_LAUNCH =
            "com.lhht.ai_assistant.EXTRA_ASSISTANT_LAUNCH"
        private const val ASSISTANT_CHANNEL = "xiaozhi/assistant"
    }
}
