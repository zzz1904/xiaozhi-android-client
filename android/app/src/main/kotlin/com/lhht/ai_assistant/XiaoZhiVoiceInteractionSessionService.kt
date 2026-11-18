package com.lhht.ai_assistant

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

class XiaoZhiVoiceInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return XiaoZhiVoiceInteractionSession(this)
    }
}

private class XiaoZhiVoiceInteractionSession(context: Context) :
    VoiceInteractionSession(context) {

    private val appContext = context

    override fun onPrepareShow(args: Bundle?, showFlags: Int) {
        super.onPrepareShow(args, showFlags)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setUiEnabled(false)
        }
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Log.i(TAG, "XiaoZhi assistant invoked by system")
        val launchIntent = Intent(appContext, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            putExtra(MainActivity.EXTRA_ASSISTANT_LAUNCH, true)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startAssistantActivity(launchIntent)
            } else {
                startVoiceActivity(launchIntent)
            }
        } catch (error: Exception) {
            Log.e(TAG, "Could not open XiaoZhi assistant activity", error)
            try {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(launchIntent)
            } catch (fallbackError: Exception) {
                Log.e(TAG, "Fallback launch of XiaoZhi failed", fallbackError)
            }
        }
    }

    companion object {
        private const val TAG = "XiaoZhiAssistant"
    }
    }
}
