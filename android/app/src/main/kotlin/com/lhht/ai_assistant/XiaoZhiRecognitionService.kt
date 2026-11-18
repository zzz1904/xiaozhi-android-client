package com.lhht.ai_assistant

import android.content.Intent
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * Android requires every VoiceInteractionService to declare a RecognitionService.
 * XiaoZhi performs speech recognition through its own voice session, so this
 * fallback reports that standalone Android recognition is not supported.
 */
class XiaoZhiRecognitionService : RecognitionService() {
    override fun onStartListening(intent: Intent?, callback: Callback) {
        callback.error(SpeechRecognizer.ERROR_CLIENT)
    }

    override fun onStopListening(callback: Callback) = Unit

    override fun onCancel(callback: Callback) = Unit
}
