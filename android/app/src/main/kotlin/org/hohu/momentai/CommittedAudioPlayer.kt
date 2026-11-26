package org.hohu.momentai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.core.content.ContextCompat
import java.io.File
import java.io.RandomAccessFile

internal data class PreparedPlaybackSource(
    val chunks: List<Map<String, Any?>>,
    val duration: Long,
    val sessionId: String,
    val compensationGain: Float
)

/** Reuse only the current immutable, committed source; stop and failures release it. */
internal class PlaybackPreparationCache {
    private var directory: String? = null
    private var source: PreparedPlaybackSource? = null

    fun prepare(path: String, load: () -> PreparedPlaybackSource): PreparedPlaybackSource {
        if (directory == path) source?.let { return it }
        clear()
        return load().also {
            directory = path
            source = it
        }
    }

    fun clear() {
        directory = null
        source = null
    }
}

/** Bounded streaming from committed PCM; never buffers a whole recording. */
class CommittedAudioPlayer(private val context: Context) {
    private val worker = Handler(HandlerThread("momentai-playback").apply { start() }.looper)
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var focus: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change < 0) pause { }
    }
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) pause { }
        }
    }

    init {
        ContextCompat.registerReceiver(
            context,
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    private val soundPreferences = context.getSharedPreferences("playback_sound", Context.MODE_PRIVATE)
    private val signalProcessor = PlaybackSignalProcessor().apply {
        val saved = soundPreferences.getFloat("volume", 1f)
        configure(if (saved.isFinite()) saved.coerceIn(0f, 1f) else 1f, soundPreferences.getBoolean("automatic_level", true))
    }
    private var track: AudioTrack? = null

    fun soundSettings(reply: NativeReply) = operation(reply) { soundSettings() }

    fun setSound(volume: Float, enhanced: Boolean, reply: NativeReply) {
        if (!volume.isFinite() || volume !in 0f..1f) {
            reply(Result.failure(IllegalArgumentException("Invalid playback volume.")))
            return
        }
        operation(reply) {
            signalProcessor.configure(volume, enhanced)
            soundPreferences.edit().putFloat("volume", volume).putBoolean("automatic_level", enhanced).apply()
            soundSettings()
        }
    }

    private fun soundSettings(): Map<String, Any> = mapOf("volume" to signalProcessor.volume, "enhanced" to signalProcessor.enhanced)

    private val preparation = PlaybackPreparationCache()
    private var chunks = emptyList<Map<String, Any?>>()
    private var directory = ""
    private var sessionId = ""
    private var duration = 0L
    private var base = 0L
    private var cursor = 0L
    private var chunkIndex = 0
    private var state = "idle"
    private var anchorId = ""
    private var anchorType = ""
    private var pending = ByteArray(0)
    private var pendingOffset = 0
    private var position = 0L
    private var tick = 0
    private var peakBufferedBytes = 0
    var events: ((Map<String, Any?>) -> Unit)? = null

    @Volatile var latest: Map<String, Any?> = mapOf("state" to "idle")
        private set

    fun play(path: String, sample: Long, id: String, type: String, reply: NativeReply) = operation(reply) {
        closeTrack()
        val file = SessionStore.resolve(SessionStore.root(context), path)
        val source = preparation.prepare(file.path) {
            SessionStore(file).use { store ->
                check(store.status() in SessionStore.terminalStates) { "Stop recording before playback." }
                store.verifyChunks()
                val committedChunks = store.chunks()
                val committedDuration = store.highWater()
                check(committedDuration > 0) { "No committed audio to play." }
                PreparedPlaybackSource(
                    committedChunks,
                    committedDuration,
                    store.id,
                    analyzeLoudness(committedChunks, committedDuration)
                )
            }
        }
        chunks = source.chunks
        duration = source.duration
        sessionId = source.sessionId
        directory = file.path
        signalProcessor.compensationGain = source.compensationGain
        anchorId = id
        anchorType = type
        prepare(sample.coerceIn(0, duration - 1), true)
        snapshot()
    }

    fun pause(reply: NativeReply) = operation(reply) {
        if (state == "playing") {
            track?.pause()
            updatePosition()
            state = "paused"
            worker.removeCallbacks(pump)
            abandonFocus()
        }
        snapshot()
    }

    fun resume(reply: NativeReply) = operation(reply) {
        check(state == "paused" || state == "completed") { "No paused playback." }
        if (state == "completed" || track == null) {
            prepare(if (state == "completed") 0 else position, true)
        } else {
            acquireFocus()
            track!!.play()
            state = "playing"
            worker.post(pump)
        }
        snapshot()
    }

    fun seek(sample: Long, reply: NativeReply) = operation(reply) {
        check(state != "idle" && duration > 0)
        prepare(sample.coerceIn(0, duration - 1), state == "playing")
        snapshot()
    }

    fun stop(reply: NativeReply) = operation(reply) {
        closeTrack()
        abandonFocus()
        state = "idle"
        position = 0
        directory = ""
        sessionId = ""
        duration = 0
        chunks = emptyList()
        preparation.clear()
        snapshot()
    }

    private fun analyzeLoudness(chunks: List<Map<String, Any?>>, duration: Long): Float {
        val profile = PlaybackLoudnessProfile()
        val count = ((duration + 15999) / 16000).coerceIn(1, 60).toInt()
        var index = 0
        repeat(count) { sampleIndex ->
            val target = if (count == 1) 0L else sampleIndex.toLong() * (duration - 16000).coerceAtLeast(0) / (count - 1)
            while (index < chunks.lastIndex && target >= (chunks[index]["endSample"] as Number).toLong()) index++
            val chunk = chunks[index]
            val start = (chunk["startSample"] as Number).toLong()
            val frames = minOf(16000L, (chunk["endSample"] as Number).toLong() - target).toInt()
            val bytes = ByteArray(frames * 2)
            RandomAccessFile(File(chunk["path"].toString()), "r").use {
                it.seek((target - start) * 2)
                it.readFully(bytes)
            }
            profile.addPCM16(bytes)
        }
        return profile.gain()
    }

    private fun prepare(sample: Long, playing: Boolean) {
        closeTrack()
        chunkIndex =
            chunks.indexOfFirst { sample < (it["endSample"] as Number).toLong() }.coerceAtLeast(0)
        base = sample
        cursor = sample
        position = sample
        pending = ByteArray(0)
        pendingOffset = 0
        signalProcessor.reset()
        val minimum = AudioTrack.getMinBufferSize(
            16000,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        check(minimum > 0)
        track = AudioTrack.Builder().setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(
                    16000
                ).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
            )
            .setBufferSizeInBytes(
                maxOf(minimum, 6400)
            ).setTransferMode(AudioTrack.MODE_STREAM).build()
        check(track!!.state == AudioTrack.STATE_INITIALIZED)
        peakBufferedBytes = maxOf(peakBufferedBytes, track!!.bufferSizeInFrames * 2 + 3200)
        state = if (playing) "playing" else "paused"
        if (playing) {
            acquireFocus()
            track!!.play()
            worker.post(pump)
        }
    }

    private val pump = object : Runnable {
        override fun run() {
            if (state != "playing") return
            try {
                if (pendingOffset == pending.size && cursor < duration) {
                    while (chunkIndex < chunks.lastIndex &&
                        cursor >= (chunks[chunkIndex]["endSample"] as Number).toLong()
                    ) {
                        chunkIndex++
                    }
                    val chunk = chunks[chunkIndex]
                    val start = (chunk["startSample"] as Number).toLong()
                    val end = (chunk["endSample"] as Number).toLong()
                    val count = minOf(1600L, end - cursor).toInt()
                    pending = ByteArray(count * 2)
                    pendingOffset = 0
                    RandomAccessFile(File(chunk["path"].toString()), "r").use {
                        it.seek((cursor - start) * 2)
                        it.readFully(pending)
                    }
                    signalProcessor.processPCM16(pending)
                    cursor += count
                }
                if (pendingOffset < pending.size) {
                    val written = track!!.write(
                        pending,
                        pendingOffset,
                        pending.size - pendingOffset,
                        AudioTrack.WRITE_NON_BLOCKING
                    )
                    check(written >= 0) { "AudioTrack write failed: $written" }
                    pendingOffset += written
                }
                updatePosition()
                if (position >= duration) {
                    state = "completed"
                    position = duration
                    closeTrack()
                    abandonFocus()
                    snapshot()
                } else {
                    if (++tick % 10 == 0) snapshot()
                    worker.postDelayed(this, 20)
                }
            } catch (failure: Exception) {
                closeTrack()
                abandonFocus()
                state = "paused"
                preparation.clear()
                snapshot(failure.message)
            }
        }
    }

    private fun updatePosition() {
        track?.let {
            position =
                minOf(duration, base + (it.playbackHeadPosition.toLong() and 0xffffffffL))
        }
    }

    private fun closeTrack() {
        worker.removeCallbacks(pump)
        track?.let {
            runCatching {
                it.pause()
                it.flush()
            }
            it.release()
        }
        track = null
    }

    @Suppress("DEPRECATION")
    private fun acquireFocus() {
        val result = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN
            ).setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(focusListener, main).build()
            focus = request
            audioManager.requestAudioFocus(request)
        } else {
            audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
        check(result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            "Playback audio focus was denied."
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= 26) {
            focus?.let(audioManager::abandonAudioFocusRequest)
        } else {
            audioManager.abandonAudioFocus(focusListener)
        }
        focus = null
    }

    private fun snapshot(error: String? = null): Map<String, Any?> {
        val value = mapOf(
            "state" to state, "sessionId" to sessionId, "directory" to directory,
            "sampleRate" to 16000, "positionSample" to position, "durationSamples" to duration,
            "positionMs" to position / 16, "durationMs" to duration / 16, "anchorId" to anchorId,
            "signalGainDb" to if (signalProcessor.enhanced) 20 * kotlin.math.log10(signalProcessor.compensationGain.toDouble()) else 0,
            "anchorType" to anchorType, "peakBufferedBytes" to peakBufferedBytes, "error" to error
        )
        latest = value
        main.post { events?.invoke(value) }
        return value
    }

    private fun operation(reply: NativeReply, action: () -> Any?) {
        worker.post {
            try {
                val value = action()
                main.post { reply(Result.success(value)) }
            } catch (
                failure: Exception
            ) {
                closeTrack()
                abandonFocus()
                state = "idle"
                preparation.clear()
                snapshot(failure.message)
                main.post { reply(Result.failure(failure)) }
            }
        }
    }

    fun close() {
        events = null
        context.unregisterReceiver(noisyReceiver)
        stop { worker.looper.quitSafely() }
    }
}
