package com.lhht.ai_assistant

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

class XiaoZhiVoiceInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return XiaoZhiVoiceInteractionSession(this)
    }
}

private class XiaoZhiVoiceInteractionSession(context: Context) :
    VoiceInteractionSession(context) {

    override fun onPrepareShow(args: Bundle?, showFlags: Int) {
        super.onPrepareShow(args, showFlags)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setUiEnabled(false)
        }
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_ASSISTANT_LAUNCH, true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startAssistantActivity(launchIntent)
        } else {
            startVoiceActivity(launchIntent)
        }
    }
}
