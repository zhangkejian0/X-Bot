package com.xbot.xbot

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage

/**
 * 相机图像处理工具。
 *
 * 把 Flutter [CameraImage]（YUV420 三平面）转成旋转正立的 [Bitmap]，
 * 与 FaceReader 项目验证过的管线一致：YUV420 → NV21 → JPEG → Bitmap → 旋转。
 */
object BitmapUtil {

    fun bitmapFromCameraImage(arguments: Map<*, *>): Bitmap {
        val width = (arguments["width"] as Number).toInt()
        val height = (arguments["height"] as Number).toInt()
        val rotationDegrees = (arguments["rotationDegrees"] as? Number)?.toInt() ?: 0
        val mirror = (arguments["mirror"] as? Boolean) ?: false
        @Suppress("UNCHECKED_CAST")
        val planes = arguments["planes"] as List<Map<*, *>>

        val yBytes = (planes[0]["bytes"] as ByteArray)
        val uBytes = (planes[1]["bytes"] as ByteArray)
        val vBytes = (planes[2]["bytes"] as ByteArray)
        val yRowStride = (planes[0]["bytesPerRow"] as Number).toInt()
        val uvRowStride = (planes[1]["bytesPerRow"] as Number).toInt()
        val uvPixelStride = (planes[1]["bytesPerPixel"] as Number).toInt()

        val nv21 = yuv420ToNv21(
            yBytes, uBytes, vBytes,
            width, height,
            yRowStride, uvRowStride, uvPixelStride
        )

        val yuvImage = YuvImage(nv21, android.graphics.ImageFormat.NV21, width, height, null)
        val out = java.io.ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, width, height), 80, out)
        var bitmap = BitmapFactory.decodeByteArray(out.toByteArray(), 0, out.size())
        bitmap = bitmap.rotate(rotationDegrees)
        // 前置摄像头：旋转后做水平镜像，使检测图像与预览（照镜子效果）一致。
        if (mirror) {
            bitmap = bitmap.flipHorizontal()
        }
        return bitmap
    }

    /** YUV420 planar → NV21（VU 交错）。 */
    private fun yuv420ToNv21(
        y: ByteArray, u: ByteArray, v: ByteArray,
        width: Int, height: Int,
        yRowStride: Int, uvRowStride: Int, uvPixelStride: Int
    ): ByteArray {
        val nv21 = ByteArray(height * width * 3 / 2)
        // Y 平面。
        var dst = 0
        for (row in 0 until height) {
            System.arraycopy(y, row * yRowStride, nv21, dst, width)
            dst += width
        }
        // V、U 交错。
        val uvHeight = height / 2
        val uvWidth = (width + 1) / 2
        for (row in 0 until uvHeight) {
            for (col in 0 until uvWidth) {
                val vIdx = row * uvRowStride + col * uvPixelStride
                val uIdx = row * uvRowStride + col * uvPixelStride
                if (vIdx < v.size) nv21[dst++] = v[vIdx]
                if (uIdx < u.size) nv21[dst++] = u[uIdx]
            }
        }
        return nv21
    }

    private fun Bitmap.rotate(rotationDegrees: Int): Bitmap {
        val normalized = ((rotationDegrees % 360) + 360) % 360
        if (normalized == 0) return this
        val matrix = Matrix().apply { postRotate(normalized.toFloat()) }
        return Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
    }

    /** 水平镜像翻转（前置摄像头用）。 */
    private fun Bitmap.flipHorizontal(): Bitmap {
        val matrix = Matrix().apply { preScale(-1f, 1f) }
        return Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
    }
}
