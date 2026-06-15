package com.xbot.xbot

import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Flutter 入口 Activity。
 *
 * 通过 MethodChannel("xbot/detection") 接收每帧相机图像，运行：
 *   1. FaceLandmarker（人脸框 + 478 关键点 + blendshapes + 身份 embedding）
 *   2. GestureRecognizer（21 关键点 + 手势/惯用手）
 *   3. PoseLandmarker（33 关键点）
 * 一次性把全部结果回传 Dart。
 */
class MainActivity : FlutterActivity() {

    // 在 onCreate 最早期锁定横屏，避免启动时竖屏闪一下。
    // 用固定 landscape 而非 sensorLandscape：后者依赖重力传感器响应，
    // 冷启动时可能未就绪导致先竖屏再转横屏。
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
    }


    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private lateinit var detector: MediaPipeDetector
    private lateinit var recognizer: FaceRecognizer

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        detector = MediaPipeDetector(this)
        recognizer = FaceRecognizer(this)
        executor.execute {
            detector.warmUp()
            recognizer.warmUp()
        }

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "detect" -> handleDetect(call, result)
                "getRecognitionStatus" -> result.success(mapOf(
                    "ready" to recognizer.isReady,
                    "error" to (recognizer.lastError() ?: "")
                ))
                else -> result.notImplemented()
            }
        }
    }

    private fun handleDetect(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        if (arguments == null) {
            result.error("BAD_ARGS", "detect expects a map argument.", null)
            return
        }
        executor.execute {
            try {
                val bitmap = BitmapUtil.bitmapFromCameraImage(arguments)
                val detection = detectAll(bitmap)
                runOnUiThread { result.success(detection) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error("DETECT_ERROR", error.message ?: "Unknown detection error.", null)
                }
            }
        }
    }

    private fun detectAll(bitmap: Bitmap): Map<String, Any> {
        val faces = detector.detectFaces(bitmap, recognizer)
        val hands = detector.detectHands(bitmap)
        val poses = detector.detectPoses(bitmap)
        return mapOf(
            "imageWidth" to bitmap.width,
            "imageHeight" to bitmap.height,
            "faces" to faces,
            "hands" to hands,
            "poses" to poses
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        detector.release()
        recognizer.release()
    }

    companion object {
        private const val CHANNEL_NAME = "xbot/detection"
    }
}
