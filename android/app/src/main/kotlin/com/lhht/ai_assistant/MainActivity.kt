package com.lhht.ai_assistant

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    /**
     * Close the whole app task when the user leaves the app (Home / app switcher).
     *
     * The app is launched as a temporary voice-assistant window from a hardware
     * shortcut, so keeping the previous Flutter screen and microphone session
     * alive in the background is undesirable.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        finishAndRemoveTask()
    }
}
