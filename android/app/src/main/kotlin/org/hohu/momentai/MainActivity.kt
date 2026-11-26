package org.hohu.momentai

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.edit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var pendingPermission: String? = null
    private val permissionRequestCode = 7301
    private var productBridge: ProductPlatformBridge? = null
    private var transferBridge: SessionTransferBridge? = null
    private var cameraResult: MethodChannel.Result? = null
    private val cameraRequestCode = 7302

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativeStrings.initialize(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.hohu.momentai.localization")
            .setMethodCallHandler { call, result ->
                if (call.method == "setLanguage") {
                    NativeStrings.select(call.argument<String>("language") ?: "system")
                    RecordingService.refreshLanguage()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        if (packageName == "org.hohu.momentai.refinementbench") {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        val transfer = SessionTransferBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        transferBridge = transfer
        productBridge =
            ProductPlatformBridge(
                applicationContext,
                flutterEngine.dartExecutor.binaryMessenger,
                ::openProductCamera,
                transfer
            )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.hohu.momentai.product/session_repository"
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "systemOverview" -> result.success(systemOverview())
                    "requestPermission" -> requestProductPermission(
                        call.argument<String>("permission"),
                        result
                    )
                    "openSystemSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            )
                        )
                        result.success(null)
                    }
                    else -> if (productBridge?.sessionCall(call, result) !=
                        true
                    ) {
                        result.notImplemented()
                    }
                }
            } catch (error: Exception) {
                result.error("system_failed", "Unable to access system settings.", error.toString())
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "momentai/model_center"
        ).setMethodCallHandler { call, result ->
            if (call.method != "availableStorageBytes" && call.method != "prepareModelStorage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error("invalid_path", "A model storage path is required.", null)
                return@setMethodCallHandler
            }
            if (call.method == "prepareModelStorage") {
                result.success(null)
                return@setMethodCallHandler
            }
            try {
                result.success(StatFs(path).availableBytes)
            } catch (error: Exception) {
                result.error(
                    "storage_failed",
                    "Unable to read available storage.",
                    error.toString()
                )
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun systemOverview(): Map<String, String> {
        val info = packageManager.getPackageInfo(packageName, 0)
        val buildNumber = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode.toString()
        } else {
            info.versionCode.toString()
        }
        return mapOf(
            "microphonePermission" to permissionStatus(
                Manifest.permission.RECORD_AUDIO,
                PackageManager.FEATURE_MICROPHONE
            ),
            "cameraPermission" to permissionStatus(
                Manifest.permission.CAMERA,
                PackageManager.FEATURE_CAMERA_ANY
            ),
            "appVersion" to (info.versionName ?: ""),
            "buildNumber" to buildNumber,
            "modelId" to ""
        )
    }

    private fun permissionStatus(permission: String, feature: String): String {
        if (!packageManager.hasSystemFeature(feature)) return "unavailable"
        if (checkSelfPermission(permission) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return "authorized"
        }
        if (getPreferences(MODE_PRIVATE).getBoolean("blocked:$permission", false) &&
            !shouldShowRequestPermissionRationale(permission)
        ) {
            return "denied"
        }
        return "not_granted"
    }

    private fun requestProductPermission(name: String?, result: MethodChannel.Result) {
        val (permission, feature) = when (name) {
            "microphone" -> Manifest.permission.RECORD_AUDIO to PackageManager.FEATURE_MICROPHONE
            "camera" -> Manifest.permission.CAMERA to PackageManager.FEATURE_CAMERA_ANY
            else -> {
                result.error("invalid_permission", "Unknown permission.", null)
                return
            }
        }
        if (permissionResult != null) {
            result.error("permission_busy", "A permission request is already active.", null)
            return
        }
        if (permissionStatus(permission, feature) != "not_granted") {
            result.success(null)
            return
        }
        permissionResult = result
        pendingPermission = permission
        try {
            requestPermissions(arrayOf(permission), permissionRequestCode)
        } catch (error: Exception) {
            permissionResult = null
            pendingPermission = null
            result.error("permission_failed", "Unable to request permission.", error.toString())
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return
        val result = permissionResult ?: return
        val permission = pendingPermission
        permissionResult = null
        pendingPermission = null
        val index = permissions.indexOf(permission)
        // An empty result means interruption, not a permanent denial.
        if (permission != null && index >= 0 && index < grantResults.size) {
            val blocked = grantResults[index] != PackageManager.PERMISSION_GRANTED &&
                !shouldShowRequestPermissionRationale(permission)
            getPreferences(MODE_PRIVATE).edit { putBoolean("blocked:$permission", blocked) }
        }
        result.success(null)
    }

    @Suppress("DEPRECATION")
    private fun openProductCamera(result: MethodChannel.Result) {
        if (cameraResult !=
            null
        ) {
            result.error(
                "camera_busy",
                NativeStrings.text(R.string.native_the_camera_is_already_open_14),
                null
            )
            return
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            result.error(
                "camera_permission",
                NativeStrings.text(R.string.native_allow_camera_access_first_15),
                null
            )
            return
        }
        if (!RecordingRuntime.get(this).active) {
            result.error(
                "camera_inactive",
                NativeStrings.text(R.string.native_start_a_recording_first_16),
                null
            )
            return
        }
        cameraResult = result
        try {
            startActivityForResult(
                Intent(this, PhotoCaptureActivity::class.java),
                cameraRequestCode
            )
        } catch (
            failure: Exception
        ) {
            cameraResult = null
            result.error("camera_failed", failure.message, null)
        }
    }

    @Deprecated("Uses the same native Activity result contract as FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (transferBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode != cameraRequestCode) return
        val result = cameraResult ?: return
        cameraResult = null
        val count = data?.getIntExtra("photoCount", 0) ?: 0
        val error = data?.getStringExtra("error")
        if (error != null && count == 0) {
            result.error("camera_failed", error, null)
        } else {
            result.success(mapOf("photoCount" to count, "cancelled" to (count == 0)))
        }
    }

    override fun onDestroy() {
        transferBridge?.close()
        transferBridge = null
        cameraResult?.error(
            "camera_closed",
            NativeStrings.text(
                R.string.native_the_app_screen_was_closed_saved_photos_are_still_available_17
            ),
            null
        )
        cameraResult = null
        productBridge?.detach()
        productBridge = null
        permissionResult?.error(
            "permission_cancelled",
            "Activity was closed during authorization.",
            null
        )
        permissionResult = null
        pendingPermission = null
        super.onDestroy()
    }
}
