package com.xbot.xbot

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * 人脸身份识别（MobileFaceNet/ArcFace 128 维 embedding）。
 *
 * 流程：
 *   1. 用 FaceLandmarker 的眼角关键点计算旋转角，把人脸对齐为正立。
 *   2. 裁剪并缩放到 112x112（MobileFaceNet 输入）。
 *   3. TFLite 推理得到 128 维 embedding。
 *
 * 模型未加载或推理失败时返回空数组（Dart 端会优雅降级，身份识别不可用）。
 */
class FaceRecognizer(context: Context) {

    private val appContext = context.applicationContext
    private var interpreter: Interpreter? = null
    private var loadError: String? = null

    /// 模型是否加载成功。
    val isReady: Boolean get() = interpreter != null

    fun warmUp() {
        getInterpreter()
    }

    @Synchronized
    private fun getInterpreter(): Interpreter? {
        interpreter?.let { return it }
        return try {
            val model = loadModelFile(MODEL_FILE)
            val options = Interpreter.Options().apply { setNumThreads(2) }
            val interp = Interpreter(model, options)
            // 打印输入/输出张量信息，便于排查维度不匹配。
            val input = interp.getInputTensor(0)
            val output = interp.getOutputTensor(0)
            Log.i(TAG, "模型加载成功 input=${input.shape().toList()} output=${output.shape().toList()}")
            loadError = null
            interpreter = interp
            interp
        } catch (e: Throwable) {
            loadError = "${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, "模型加载失败: $loadError", e)
            null
        }
    }

    /// 返回最近一次加载错误（供 Dart 查询）。
    fun lastError(): String? = loadError

    /**
     * 对 [bitmap] 中由 [landmarks]（归一化 478 点）标记的人脸做识别。
     * 返回 embedding 向量；不可用时返回空列表。
     */
    fun recognize(bitmap: Bitmap, landmarks: List<NormalizedLandmark>): List<Float> {
        val interp = getInterpreter() ?: return emptyList()
        if (landmarks.size <= LEFT_INNER_EYE) {
            Log.w(TAG, "关键点不足，无法对齐：${landmarks.size}")
            return emptyList()
        }

        val aligned = alignAndCrop(bitmap, landmarks) ?: run {
            Log.w(TAG, "对齐裁剪失败")
            return emptyList()
        }

        // 读取模型实际输入维度，动态适配（部分模型输入非 112x112）。
        val inputShape = interp.getInputTensor(0).shape()
        Log.i(TAG, "推理输入 shape=${inputShape.toList()}")
        val inputH = inputShape.getOrElse(1) { INPUT_SIZE }
        val inputW = inputShape.getOrElse(2) { INPUT_SIZE }
        val inputBytes = if (inputW <= 0 || inputH <= 0) INPUT_SIZE else inputW.coerceAtLeast(1)

        // 构造输入：HxWx3 float32，归一化到 [-1,1]。
        val scaled = if (inputW == INPUT_SIZE && inputH == INPUT_SIZE) aligned
                     else Bitmap.createScaledBitmap(aligned, inputW, inputH, true)
        val inputBuf = ByteBuffer.allocateDirect(inputW * inputH * 3 * 4)
            .order(ByteOrder.nativeOrder())
        val pixels = IntArray(inputW * inputH)
        scaled.getPixels(pixels, 0, inputW, 0, 0, inputW, inputH)
        for (px in pixels) {
            inputBuf.putFloat((((px shr 16) and 0xFF) / 127.5f) - 1f) // R
            inputBuf.putFloat((((px shr 8) and 0xFF) / 127.5f) - 1f)  // G
            inputBuf.putFloat(((px and 0xFF) / 127.5f) - 1f)          // B
        }
        inputBuf.rewind()

        // 读取输出维度，动态分配 buffer。
        val outputShape = interp.getOutputTensor(0).shape()
        val outputDim = outputShape.lastOrNull()?.toInt() ?: EMBEDDING_DIM
        Log.i(TAG, "推理输出 shape=${outputShape.toList()} dim=$outputDim")
        val outputBuf = ByteBuffer.allocateDirect(outputDim * 4)
            .order(ByteOrder.nativeOrder())
        val outputMap = mapOf(0 to outputBuf)
        try {
            interp.runForMultipleInputsOutputs(arrayOf(inputBuf), outputMap)
        } catch (e: Throwable) {
            Log.e(TAG, "TFLite 推理失败: ${e.javaClass.simpleName}: ${e.message}", e)
            return emptyList()
        }

        outputBuf.rewind()
        // L2 归一化。
        var norm = 0.0
        val raw = FloatArray(outputDim)
        for (i in 0 until outputDim) {
            raw[i] = outputBuf.float
            norm += raw[i].toDouble() * raw[i]
        }
        norm = Math.sqrt(norm)
        val n = if (norm < 1e-6) 1.0 else norm
        val embedding = ArrayList<Float>(outputDim)
        for (v in raw) embedding.add((v / n).toFloat())
        Log.i(TAG, "推理成功，embedding 维度=${embedding.size}")
        return embedding
    }

    /** 用左右眼内眼角计算旋转角，正立对齐后裁剪正方形人脸。 */
    private fun alignAndCrop(bitmap: Bitmap, landmarks: List<NormalizedLandmark>): Bitmap? {
        val w = bitmap.width
        val h = bitmap.height
        // 眼角关键点（归一化坐标 → 像素坐标）。
        val rightInner = landmarks[RIGHT_INNER_EYE]
        val leftInner = landmarks[LEFT_INNER_EYE]
        val rxEye = rightInner.x() * w
        val ryEye = rightInner.y() * h
        val lxEye = leftInner.x() * w
        val lyEye = leftInner.y() * h

        val angle = Math.toDegrees(
            atan2((lyEye - ryEye).toDouble(), (lxEye - rxEye).toDouble())
        ).toFloat()

        // 旋转整张图使眼睛水平。
        val matrix = Matrix().apply { postRotate(angle) }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, w, h, matrix, true)

        // 旋转后重新计算两眼中心。
        val cosA = cos(Math.toRadians(-angle.toDouble())).toFloat()
        val sinA = sin(Math.toRadians(-angle.toDouble())).toFloat()
        val eyeMidX = (rxEye + lxEye) / 2f
        val eyeMidY = (ryEye + lyEye) / 2f
        val cx = cosA * eyeMidX - sinA * eyeMidY
        val cy = sinA * eyeMidX + cosA * eyeMidY

        // 用两眼距离估算正方形边长。
        val eyeDist = Math.hypot((lxEye - rxEye).toDouble(), (lyEye - ryEye).toDouble()).toFloat()
        val faceSize = eyeDist * 2.6f
        val half = faceSize / 2f
        val left = (cx - half).toInt().coerceAtLeast(0)
        val top = (cy - half * 0.85f).toInt().coerceAtLeast(0)
        val cropW = min(faceSize.toInt(), rotated.width - left).coerceAtLeast(1)
        val cropH = min(faceSize.toInt(), rotated.height - top).coerceAtLeast(1)
        val cropSize = min(cropW, cropH)
        if (cropSize < 32) return null
        val cropped = Bitmap.createBitmap(rotated, left, top, cropSize, cropSize)
        return Bitmap.createScaledBitmap(cropped, INPUT_SIZE, INPUT_SIZE, true)
    }

    private fun loadModelFile(assetName: String): MappedByteBuffer {
        val fd = appContext.assets.openFd(assetName)
        val inputStream = FileInputStream(fd.fileDescriptor)
        return inputStream.channel.map(
            FileChannel.MapMode.READ_ONLY,
            fd.startOffset,
            fd.declaredLength
        )
    }

    fun release() {
        interpreter?.close()
    }

    companion object {
        private const val TAG = "FaceRecognizer"
        private const val MODEL_FILE = "mobilefacenet.tflite"
        private const val INPUT_SIZE = 112
        private const val EMBEDDING_DIM = 128

        // MediaPipe FaceLandmarker 关键点索引（ARKit 规范）。
        private const val RIGHT_INNER_EYE = 133
        private const val LEFT_INNER_EYE = 362
    }
}
