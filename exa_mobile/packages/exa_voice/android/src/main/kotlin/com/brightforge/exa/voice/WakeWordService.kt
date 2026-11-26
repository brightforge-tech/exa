package com.brightforge.exa.voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.KeywordSpotterConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig

/**
 * Listens for "Hey Exa" and opens the voice session when it hears it.
 *
 * Detection runs entirely on the phone with sherpa-onnx's keyword spotter:
 * 100 ms of audio at a time goes through a 3 MB model in memory, and is
 * never stored or sent. The microphone stays open while this service runs,
 * which is why it is a foreground service with its own ongoing
 * notification - Android requires it, and the user should always be able to
 * see that Exa is listening.
 *
 * The keywords are word pieces of the model's vocabulary, prepared by the
 * app from the user's phrase (see wake_phrase.dart): the phrase in a few
 * pronunciations, plus decoys - "Hey Alexa", "extra" - that sound close.
 * Only a `WAKE_` keyword opens the session; a decoy match is the spotter
 * hearing something else, and is ignored.
 *
 * The microphone is handed over, not shared: the moment the wake word is
 * heard - or the voice session opens some other way - detection stops so
 * the speech recogniser gets the mic, and it resumes when the session ends.
 * A session that never reports back is not allowed to leave Exa deaf: the
 * service resumes on its own after [RESUME_FALLBACK_MS].
 */
class WakeWordService : Service() {

    companion object {
        private const val TAG = "ExaWakeWord"
        const val PREFS = "exa_voice"
        const val KEY_ENABLED = "wake_enabled"
        const val KEY_PHRASE = "wake_phrase"
        const val KEY_KEYWORDS = "wake_keywords"
        const val KEY_THRESHOLD = "wake_threshold"
        const val KEY_LAST_ERROR = "wake_last_error"
        const val KEY_DETECTIONS = "wake_detections"
        const val KEY_LAST_DETECTION = "wake_last_detection"

        const val ACTION_START = "com.brightforge.exa.voice.WAKE_START"
        const val ACTION_STOP = "com.brightforge.exa.voice.WAKE_STOP"
        const val ACTION_PAUSE = "com.brightforge.exa.voice.WAKE_PAUSE"
        const val ACTION_RESUME = "com.brightforge.exa.voice.WAKE_RESUME"
        const val ACTION_RELOAD = "com.brightforge.exa.voice.WAKE_RELOAD"

        const val DEFAULT_PHRASE = "Hey Exa"

        /**
         * "Hey Exa" before the app has set anything: the phrase in four
         * pronunciations, and decoys for the words it is most often confused
         * with. Measured on synthetic speech: no decoy-free false alarm at
         * any threshold from 0.1 to 0.25. Mirrors WakePhrase.forPhrase in
         * Dart, which is what the settings screen writes.
         */
        const val DEFAULT_KEYWORDS =
            "▁HE Y ▁EX A @WAKE_HEY_EXA/" +
                "▁HE Y ▁E K S A @WAKE_HEY_EKSA/" +
                "▁HE Y ▁E CK S A @WAKE_HEY_ECKSA/" +
                "▁HI ▁EX A @WAKE_HI_EXA/" +
                "▁HE Y ▁A LE X A @DECOY_HEY_ALEXA/" +
                "▁A LE X A @DECOY_ALEXA/" +
                "▁EX T RA @DECOY_EXTRA/" +
                "▁EX A M @DECOY_EXAM"

        const val DEFAULT_THRESHOLD = 0.15f

        private const val CHANNEL_ID = "exa_wake_word"
        private const val NOTIFICATION_ID = 7410
        private const val RESUME_FALLBACK_MS = 5 * 60_000L
        private const val SAMPLE_RATE = 16_000
        private const val CHUNK_SAMPLES = SAMPLE_RATE / 10

        private const val MODEL_DIR = "kws"

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var isListening = false
            private set

        fun prefs(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** The model ships with the app; only the native library can be missing. */
        fun isConfigured(context: Context): Boolean = nativeAvailable

        private val nativeAvailable: Boolean by lazy {
            try {
                Class.forName("com.k2fsa.sherpa.onnx.KeywordSpotter")
                true
            } catch (e: Throwable) {
                false
            }
        }

        fun send(context: Context, action: String) {
            val intent = Intent(context, WakeWordService::class.java).setAction(action)
            try {
                if (action == ACTION_START) {
                    context.startForegroundService(intent)
                } else if (isRunning) {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 14+ refuses a microphone service started from the
                // background (after a reboot, say); the settings screen and
                // the app's next launch start it again.
                Log.w(TAG, "Could not $action the wake word service", e)
                prefs(context).edit()
                    .putString(KEY_LAST_ERROR, "Could not start listening: ${e.message}")
                    .apply()
            }
        }
    }

    private var spotter: KeywordSpotter? = null
    private var worker: Thread? = null

    @Volatile
    private var detecting = false
    private val handler = Handler(Looper.getMainLooper())
    private val resumeFallback = Runnable { startDetection() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // From the notification's "Stop listening" as well as from
                // Settings: either way the user means off until turned on.
                prefs(this).edit().putBoolean(KEY_ENABLED, false).apply()
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                handler.removeCallbacks(resumeFallback)
                stopDetection()
                handler.postDelayed(resumeFallback, RESUME_FALLBACK_MS)
                updateNotification()
                return START_STICKY
            }
            ACTION_RESUME -> {
                handler.removeCallbacks(resumeFallback)
                startDetection()
                return START_STICKY
            }
            ACTION_RELOAD -> {
                // Only while listening: a paused service picks the new
                // settings up when it resumes, from a rebuilt spotter.
                val wasListening = detecting
                stopDetection()
                spotter?.release()
                spotter = null
                if (wasListening) startDetection()
                return START_STICKY
            }
        }
        // ACTION_START, or the system restarting a sticky service.
        if (!prefs(this).getBoolean(KEY_ENABLED, false) || !isConfigured(this)) {
            stopEverything()
            return START_NOT_STICKY
        }
        goForeground()
        isRunning = true
        startDetection()
        return START_STICKY
    }

    private fun goForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun loadSpotter(): KeywordSpotter {
        spotter?.let { return it }
        val p = prefs(this)
        val config = KeywordSpotterConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = "$MODEL_DIR/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                    decoder = "$MODEL_DIR/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                    joiner = "$MODEL_DIR/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                ),
                tokens = "$MODEL_DIR/tokens.txt",
                modelType = "zipformer2",
                numThreads = 1,
            ),
            maxActivePaths = 4,
            keywordsFile = "$MODEL_DIR/keywords.txt",
            keywordsScore = 1.0f,
            keywordsThreshold = p.getFloat(KEY_THRESHOLD, DEFAULT_THRESHOLD),
            numTrailingBlanks = 1,
        )
        return KeywordSpotter(assets, config).also { spotter = it }
    }

    @SuppressLint("MissingPermission")
    private fun startDetection() {
        if (detecting) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            fail("Exa does not have microphone permission.")
            return
        }
        val kws = try {
            loadSpotter()
        } catch (e: Throwable) {
            Log.w(TAG, "Could not load the keyword spotter", e)
            fail("Could not load the wake word model: ${e.message}")
            return
        }
        val keywords = prefs(this).getString(KEY_KEYWORDS, null)
            ?.takeIf { it.isNotBlank() } ?: DEFAULT_KEYWORDS
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, CHUNK_SAMPLES * 2 * 2),
            )
        } catch (e: Exception) {
            fail("Could not open the microphone: ${e.message}")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            fail("The microphone is busy.")
            return
        }
        detecting = true
        isListening = true
        prefs(this).edit().remove(KEY_LAST_ERROR).apply()
        updateNotification()
        worker = Thread({ listen(kws, keywords, record) }, "exa-wake-word").apply { start() }
    }

    /** The detection loop, on its own thread. */
    private fun listen(kws: KeywordSpotter, keywords: String, record: AudioRecord) {
        val stream = try {
            kws.createStream(keywords)
        } catch (e: Throwable) {
            // A phrase the model cannot spell: fall back to "Hey Exa" rather
            // than listen for nothing.
            Log.w(TAG, "Keywords rejected, using the default", e)
            kws.createStream(DEFAULT_KEYWORDS)
        }
        val buffer = ShortArray(CHUNK_SAMPLES)
        val samples = FloatArray(CHUNK_SAMPLES)
        var heard = false
        try {
            record.startRecording()
            while (detecting && !heard) {
                val n = record.read(buffer, 0, buffer.size)
                if (n <= 0) continue
                for (i in 0 until n) samples[i] = buffer[i] / 32768f
                stream.acceptWaveform(if (n == samples.size) samples else samples.copyOf(n), SAMPLE_RATE)
                while (kws.isReady(stream)) {
                    kws.decode(stream)
                    val keyword = kws.getResult(stream).keyword
                    if (keyword.isEmpty()) continue
                    kws.reset(stream)
                    if (keyword.startsWith("WAKE")) {
                        heard = true
                        break
                    }
                    // A decoy: the spotter heard something close, not the name.
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Wake word loop stopped", e)
            prefs(this).edit().putString(KEY_LAST_ERROR, e.message ?: "$e").apply()
        } finally {
            try {
                record.stop()
            } catch (_: Exception) {
            }
            record.release()
            stream.release()
        }
        if (heard) handler.post { onWakeWord() }
    }

    private fun stopDetection() {
        detecting = false
        worker?.let {
            if (it != Thread.currentThread()) it.join(1500)
        }
        worker = null
        isListening = false
    }

    private fun fail(message: String) {
        prefs(this).edit().putString(KEY_LAST_ERROR, message).apply()
        detecting = false
        isListening = false
        updateNotification()
    }

    /** Heard "Hey Exa": the loop has already let go of the microphone. */
    private fun onWakeWord() {
        // Heard, said at once: the session takes a few seconds to appear,
        // and silence in that time reads as Exa not having heard.
        try {
            ToneGenerator(AudioManager.STREAM_MUSIC, 70).apply {
                startTone(ToneGenerator.TONE_PROP_ACK, 150)
                handler.postDelayed({ release() }, 400)
            }
        } catch (_: Exception) {
        }
        val p = prefs(this)
        p.edit()
            .putInt(KEY_DETECTIONS, p.getInt(KEY_DETECTIONS, 0) + 1)
            .putLong(KEY_LAST_DETECTION, System.currentTimeMillis())
            .apply()
        stopDetection()
        handler.removeCallbacks(resumeFallback)
        handler.postDelayed(resumeFallback, RESUME_FALLBACK_MS)
        updateNotification()
        if (!VoiceLauncher.open(this, VoiceLauncher.MODE_LISTEN)) {
            // Could not open over whatever is on screen: resume rather
            // than leave the user talking to nothing.
            startDetection()
        }
    }

    private fun stopEverything() {
        handler.removeCallbacks(resumeFallback)
        stopDetection()
        spotter?.release()
        spotter = null
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacks(resumeFallback)
        stopDetection()
        spotter?.release()
        spotter = null
        isRunning = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager?.getNotificationChannel(CHANNEL_ID) == null) {
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "\"Hey Exa\" listening",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while Exa listens for its wake word."
                    setShowBadge(false)
                },
            )
        }
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, WakeWordService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val talk = PendingIntent.getActivity(
            this,
            2,
            VoiceLauncher.sessionIntent(this, VoiceLauncher.MODE_LISTEN),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val phrase = prefs(this).getString(KEY_PHRASE, null) ?: DEFAULT_PHRASE
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(
                if (isListening) "Listening for \"$phrase\"" else "\"$phrase\" paused",
            )
            .setContentText(
                if (isListening) "Detection runs on the phone; nothing is recorded."
                else prefs(this).getString(KEY_LAST_ERROR, null)
                    ?: "Exa has the microphone right now.",
            )
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(talk)
            .addAction(Notification.Action.Builder(null, "Talk now", talk).build())
            .addAction(Notification.Action.Builder(null, "Stop listening", stop).build())
            .build()
    }

    private fun updateNotification() {
        if (!isRunning) return
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification())
    }
}
