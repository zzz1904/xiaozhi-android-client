package com.lhht.ai_assistant

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private var assistantChannel: MethodChannel? = null
    private var ttsChannel: MethodChannel? = null
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

        ttsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TTS_CHANNEL
        )
        ttsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "synthesizeText" -> synthesizeText(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun synthesizeText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim().orEmpty()
        if (text.isEmpty()) {
            result.error("EMPTY_TEXT", "Текст для озвучивания пуст", null)
            return
        }
        if (text.length > MAX_TTS_TEXT_LENGTH) {
            result.error(
                "TEXT_TOO_LONG",
                "Для отправки голосом разделите текст на части не длиннее $MAX_TTS_TEXT_LENGTH символов.",
                null
            )
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.error("TTS_UNSUPPORTED", "Для этого способа требуется Android 7.0 или новее.", null)
            return
        }

        val outputFile = File(cacheDir, "xiaozhi_tts_${System.currentTimeMillis()}.wav")
        val audioBuffer = ByteArrayOutputStream()
        val completed = AtomicBoolean(false)
        var sampleRate = 0
        var audioFormat = 0
        var channelCount = 0
        var engine: TextToSpeech? = null

        fun finishWithError(code: String, message: String) {
            if (!completed.compareAndSet(false, true)) return
            runOnUiThread {
                result.error(code, message, null)
                engine?.shutdown()
                outputFile.delete()
            }
        }

        try {
            engine = TextToSpeech(this) { status ->
                val tts = engine
                if (status != TextToSpeech.SUCCESS || tts == null) {
                    finishWithError("TTS_INIT_FAILED", "Не удалось запустить системный синтез речи Android.")
                    return@TextToSpeech
                }

                val languageStatus = tts.setLanguage(Locale("ru", "RU"))
                if (languageStatus < TextToSpeech.LANG_AVAILABLE) {
                    finishWithError(
                        "RUSSIAN_VOICE_MISSING",
                        "В Android не установлен поддерживаемый русский голосовой пакет. Установите русский голос в настройках синтеза речи телефона."
                    )
                    return@TextToSpeech
                }

                tts.setSpeechRate(1.0f)
                tts.setPitch(1.0f)
                val utteranceId = "xiaozhi_text_${System.currentTimeMillis()}"

                tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) = Unit

                    override fun onBeginSynthesis(
                        id: String?,
                        rate: Int,
                        format: Int,
                        channels: Int
                    ) {
                        sampleRate = rate
                        audioFormat = format
                        channelCount = channels
                    }

                    override fun onAudioAvailable(id: String?, audio: ByteArray?) {
                        if (audio != null && audio.isNotEmpty()) {
                            synchronized(audioBuffer) {
                                audioBuffer.write(audio, 0, audio.size)
                            }
                        }
                    }

                    override fun onDone(id: String?) {
                        if (!completed.compareAndSet(false, true)) return
                        val audio = synchronized(audioBuffer) { audioBuffer.toByteArray() }
                        runOnUiThread {
                            if (audio.isEmpty() || sampleRate <= 0 || channelCount <= 0) {
                                result.error("TTS_EMPTY_AUDIO", "Android не создал аудиоданные для этого текста.", null)
                            } else {
                                result.success(
                                    hashMapOf(
                                        "audio" to audio,
                                        "sampleRate" to sampleRate,
                                        "audioFormat" to audioFormat,
                                        "channels" to channelCount
                                    )
                                )
                            }
                            tts.shutdown()
                            outputFile.delete()
                        }
                    }

                    override fun onError(id: String?) {
                        finishWithError("TTS_SYNTHESIS_FAILED", "Не удалось озвучить текст средствами Android.")
                    }
                })

                val statusCode = tts.synthesizeToFile(text, Bundle(), outputFile, utteranceId)
                if (statusCode == TextToSpeech.ERROR) {
                    finishWithError("TTS_SYNTHESIS_FAILED", "Android отклонил запрос на синтез речи.")
                }
            }
        } catch (error: Exception) {
            finishWithError("TTS_EXCEPTION", error.message ?: "Ошибка синтеза речи Android.")
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

    /**
     * The voice assistant is a temporary foreground window. When the user
     * leaves it (Home or Recents), close its task completely so the next
     * hardware-key invocation starts a fresh conversation.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        finishAndRemoveTask()
    }

    private fun isAssistantLaunchIntent(intent: Intent?): Boolean {
        return intent?.getBooleanExtra(EXTRA_ASSISTANT_LAUNCH, false) == true ||
            intent?.action == Intent.ACTION_ASSIST
    }

    companion object {
        const val EXTRA_ASSISTANT_LAUNCH =
            "com.lhht.ai_assistant.EXTRA_ASSISTANT_LAUNCH"
        private const val ASSISTANT_CHANNEL = "xiaozhi/assistant"
        private const val TTS_CHANNEL = "xiaozhi/tts"
        private const val MAX_TTS_TEXT_LENGTH = 3500
    }
}
