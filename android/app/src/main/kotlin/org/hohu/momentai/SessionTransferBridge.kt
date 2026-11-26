package org.hohu.momentai

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** SAF opens user-selected documents; only generated exports receive temporary URI grants. */
internal class SessionTransferBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val runtime = RecordingRuntime.get(activity.applicationContext)
    private val queue = Executors.newSingleThreadExecutor { Thread(it, "momentai-transfer") }
    private val main = Handler(Looper.getMainLooper())
    private val archive = SessionArchive(activity.applicationContext)
    private val channel = MethodChannel(messenger, "org.hohu.momentai.product/transfer")
    private var picker: MethodChannel.Result? = null
    private var sharing: MethodChannel.Result? = null
    private var disposed = false

    @Volatile var busy = false
        private set
    init {
        channel.setMethodCallHandler(::handle)
    }

    @Suppress("DEPRECATION")
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed ||
            busy
        ) {
            result.error(
                "transfer_busy",
                NativeStrings.text(R.string.native_a_share_or_import_is_already_in_progress_50),
                null
            )
            return
        }
        if (call.method == "cancelImport") {
            work(result) {
                archive.cancel()
                null
            }
            return
        }
        if (runtime.active) {
            result.error(
                "recording_active",
                NativeStrings.text(
                    R.string.native_finish_the_current_recording_safely_before_sharing_or_importing_51
                ),
                null
            )
            return
        }
        when (call.method) {
            "pickImport" -> {
                busy = true
                picker = result
                try {
                    // Providers may report custom extensions as octet-stream.
                    // The reader validates the selected name and every archive byte.
                    activity.startActivityForResult(
                        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        },
                        PICK
                    )
                } catch (failure: Exception) {
                    picker = null
                    fail(result, failure)
                }
            }
            "commitImport" -> work(result) {
                archive.commit(
                    call.argument<String>("token") ?: "",
                    call.argument<Boolean>("asCopy") == true
                )
            }
            "readSessionText" -> work(result) {
                archive.readText(
                    call.argument<String>("sessionId") ?: "",
                    call.argument<String>("readingText")
                )
            }
            "shareSession" -> work(result, share = true) {
                archive.share(
                    call.argument<String>("sessionId") ?: "",
                    call.argument<String>("format") ?: "",
                    call.argument<String>("readingText")
                )
            }
            "exportSession" -> work(result) {
                archive.export(call.argument<String>("directory") ?: "")
            }
            "shareExport" -> {
                try {
                    val file = File(call.argument<String>("archivePath") ?: "").canonicalFile
                    require(
                        file.parentFile == File(
                            activity.cacheDir,
                            "MomentAIExports"
                        ).canonicalFile &&
                            file.isFile && file.extension == "momentai"
                    ) {
                        NativeStrings.text(
                            R.string.native_the_export_is_no_longer_available_export_it_again_52
                        )
                    }
                    busy = true
                    present(file, result)
                } catch (failure: Exception) {
                    fail(result, failure)
                }
            }
            else -> result.notImplemented()
        }
    }
    private fun work(result: MethodChannel.Result, share: Boolean = false, action: () -> Any?) {
        busy = true
        queue.execute {
            val outcome = runCatching(action)
            main.post {
                if (disposed) return@post
                outcome.fold({ value ->
                    if (share) {
                        present(value as File, result)
                    } else {
                        busy = false
                        result.success(value)
                    }
                }, { fail(result, it) })
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun present(file: File, result: MethodChannel.Result) {
        try {
            val uri = FileProvider.getUriForFile(activity, activity.packageName + ".exports", file)
            val mime = when (file.extension) {
                "txt" -> "text/plain"
                "md" -> "text/markdown"
                "wav" -> "audio/wav"
                else -> "application/octet-stream"
            }
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri(file.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            sharing = result
            activity.startActivityForResult(
                Intent.createChooser(
                    send,
                    NativeStrings.text(R.string.native_share_recording_53)
                ).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
                SHARE
            )
            // Receivers can read asynchronously after chooser completion. Keep files.
        } catch (failure: Exception) {
            sharing = null
            fail(result, failure)
        }
    }
    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request == SHARE) {
            sharing?.success(null)
            sharing = null
            busy = false
            return true
        }
        if (request != PICK) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            queue.execute {
                archive.cancel()
                main.post {
                    if (!disposed) {
                        busy = false
                        result.success(null)
                    }
                }
            }
            return true
        }
        work(result) {
            require(uri.scheme == "content") {
                NativeStrings.text(
                    R.string.native_select_a_recording_from_a_system_file_provider_54
                )
            }
            val resolver = activity.contentResolver
            val name =
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                } ?: error(NativeStrings.text(R.string.native_could_not_read_the_filename_55))
            resolver.openInputStream(uri)?.use { archive.prepare(it, name) }
                ?: error(
                    NativeStrings.text(R.string.native_the_file_provider_returned_no_content_56)
                )
        }
        return true
    }
    private fun fail(result: MethodChannel.Result, failure: Throwable) {
        busy = false
        result.error(
            "session_transfer_failed",
            failure.message
                ?: NativeStrings.text(
                    R.string.native_the_operation_failed_existing_recordings_are_unchanged_57
                ),
            null
        )
    }
    fun close() {
        disposed = true
        channel.setMethodCallHandler(null)
        picker?.error(
            "transfer_closed",
            NativeStrings.text(
                R.string.native_file_selection_was_cancelled_select_the_file_again_58
            ),
            null
        )
        picker =
            null
        sharing?.success(null)
        sharing = null
        queue.execute { archive.cancel() }
        queue.shutdown()
    }
    companion object {
        private const val PICK = 7310
        private const val SHARE = 7311
    }
}
