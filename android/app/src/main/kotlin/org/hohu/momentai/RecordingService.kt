package org.hohu.momentai

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class RecordingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var displayedState = ""
    private val runtime get() = RecordingRuntime.get(this)

    // Recording duration is user-controlled; release on pause, interruption, or destruction.
    @SuppressLint("WakelockTimeout")
    override fun onCreate() {
        super.onCreate()
        NativeStrings.initialize(this)
        running = this
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(
                NotificationManager::class.java
            ).createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    NativeStrings.text(R.string.native_recording_status_43),
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val notification = notification("preparing")
        if (Build.VERSION.SDK_INT >=
            30
        ) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(ID, notification)
        }
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:recording").apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            START -> runtime.serviceStarted(
                this,
                intent.getStringExtra("title")
                    ?: NativeStrings.text(R.string.native_new_recording_44)
            )
            STOP -> runtime.stop { result -> if (result.isSuccess) finishRecording() }
            else -> finishRecording()
        }
        return START_NOT_STICKY
    }

    // Resuming restores the lifecycle-owned lock until pause, interruption, or destruction.
    @SuppressLint("WakelockTimeout")
    fun updateRecordingState(state: String) {
        if (displayedState == state) return
        displayedState = state
        postNotification(notification(state))
        if (state in setOf("paused", "interrupted")) {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } else if (state == "recording" && wakeLock?.isHeld == false) {
            wakeLock?.acquire()
        }
    }

    private fun postNotification(value: Notification) {
        // Starting a foreground service is allowed without notification permission;
        // additional notification updates must respect the user's system setting.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        getSystemService(NotificationManager::class.java).notify(ID, value)
    }

    private fun notification(state: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, RecordingService::class.java).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // API 24–25 have no channel-aware Notification.Builder constructor.
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >=
            26
        ) {
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        return builder.setSmallIcon(
            android.R.drawable.ic_btn_speak_now
        ).setContentTitle(NativeStrings.text(R.string.native_momentai_45))
            .setContentText(
                when (state) {
                    "paused" -> NativeStrings.text(R.string.native_recording_paused_38)
                    "interrupted" -> NativeStrings.text(
                        R.string.native_recording_interrupted_return_to_check_and_save_46
                    )
                    "preparing" -> NativeStrings.text(R.string.native_preparing_to_record_47)
                    else -> NativeStrings.text(
                        R.string.native_recording_audio_is_saved_on_this_device_48
                    )
                }
            )
            .setContentIntent(
                open
            ).setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    null,
                    NativeStrings.text(R.string.native_stop_and_save_49),
                    stop
                ).build()
            ).build()
    }

    fun finishRecording() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (running === this) running = null
        runtime.serviceDestroyed(this)
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun refreshLocalizedNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    NativeStrings.text(R.string.native_recording_status_43),
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        postNotification(notification(displayedState.ifEmpty { "preparing" }))
    }

    companion object {
        private var running: RecordingService? = null
        fun refreshLanguage() {
            running?.refreshLocalizedNotification()
        }
        const val START = "momentai.capture.START"
        const val STOP = "momentai.capture.STOP"
        private const val CHANNEL = "momentai_recording"
        private const val ID = 1401
    }
}
