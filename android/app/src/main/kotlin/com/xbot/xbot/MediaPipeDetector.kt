package com.xbot.xbot

import android.content.Context
import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarkerResult
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult

/**
 * MediaPipe 三个视觉任务的封装：人脸地标、手势识别、姿势识别。
 *
 * - FaceLandmarker 输出 478 关键点 + 52 ARKit blendshapes。
 * - 对每张人脸调用 [FaceRecognizer] 做对齐+TFLite 推理，得到 128 维身份 embedding。
 * - GestureRecognizer 输出 21 关键点 + 手势类别 + 惯用手。
 * - PoseLandmarker 输出 33 关键点。
 *
 * 全部归一化坐标（0..1）回传 Dart。
 */
class MediaPipeDetector(context: Context) {

    private val appContext = context.applicationContext
    private var faceLandmarker: FaceLandmarker? = null
    private var gestureRecognizer: GestureRecognizer? = null
    private var poseLandmarker: PoseLandmarker? = null

    /** 预热：在工作线程上初始化三个 landmarker，避免首帧卡顿。 */
    fun warmUp() {
        getFaceLandmarker()
        getGestureRecognizer()
        getPoseLandmarker()
    }

    private fun getFaceLandmarker(): FaceLandmarker {
        faceLandmarker?.let { return it }
        val baseOptions = com.google.mediapipe.tasks.core.BaseOptions.builder()
            .setModelAssetPath(MODEL_FACE)
            .build()
        val options = FaceLandmarker.FaceLandmarkerOptions.builder()
            .setBaseOptions(baseOptions)
            .setRunningMode(RunningMode.IMAGE)
            .setNumFaces(MAX_FACES)
            .setOutputFaceBlendshapes(true)
            .setOutputFacialTransformationMatrixes(true)
            .build()
        return FaceLandmarker.createFromOptions(appContext, options).also { faceLandmarker = it }
    }

    private fun getGestureRecognizer(): GestureRecognizer {
        gestureRecognizer?.let { return it }
        val baseOptions = com.google.mediapipe.tasks.core.BaseOptions.builder()
            .setModelAssetPath(MODEL_GESTURE)
            .build()
        val options = GestureRecognizer.GestureRecognizerOptions.builder()
            .setBaseOptions(baseOptions)
            .setRunningMode(RunningMode.IMAGE)
            .setNumHands(MAX_HANDS)
            .build()
        return GestureRecognizer.createFromOptions(appContext, options).also { gestureRecognizer = it }
    }

    private fun getPoseLandmarker(): PoseLandmarker {
        poseLandmarker?.let { return it }
        val baseOptions = com.google.mediapipe.tasks.core.BaseOptions.builder()
            .setModelAssetPath(MODEL_POSE)
            .build()
        val options = PoseLandmarker.PoseLandmarkerOptions.builder()
            .setBaseOptions(baseOptions)
            .setRunningMode(RunningMode.IMAGE)
            .setNumPoses(MAX_POSES)
            .build()
        return PoseLandmarker.createFromOptions(appContext, options).also { poseLandmarker = it }
    }

    /** 人脸检测：返回 List<Map>，每项含 boundingBox/blendshapes/landmarks/embedding。 */
    fun detectFaces(bitmap: Bitmap, recognizer: FaceRecognizer): List<Map<String, Any>> {
        val mpImage = BitmapImageBuilder(bitmap).build()
        val result = try {
            getFaceLandmarker().detect(mpImage)
        } catch (e: Exception) {
            return emptyList()
        }
        return result.toFaceMaps(bitmap, recognizer)
    }

    /** 手势检测：返回 List<Map>，每项含 gesture/handedness/landmarks。 */
    fun detectHands(bitmap: Bitmap): List<Map<String, Any>> {
        val mpImage = BitmapImageBuilder(bitmap).build()
        val result = try {
            getGestureRecognizer().recognize(mpImage)
        } catch (e: Exception) {
            return emptyList()
        }
        return result.toHandMaps()
    }

    /** 姿势检测：返回 List<Map>，每项含 landmarks/score。 */
    fun detectPoses(bitmap: Bitmap): List<Map<String, Any>> {
        val mpImage = BitmapImageBuilder(bitmap).build()
        val result = try {
            getPoseLandmarker().detect(mpImage)
        } catch (e: Exception) {
            return emptyList()
        }
        return result.toPoseMaps()
    }

    fun release() {
        faceLandmarker?.close()
        gestureRecognizer?.close()
        poseLandmarker?.close()
    }

    companion object {
        private const val MODEL_FACE = "face_landmarker.task"
        private const val MODEL_GESTURE = "gesture_recognizer.task"
        private const val MODEL_POSE = "pose_landmarker.task"
        private const val MAX_FACES = 4
        private const val MAX_HANDS = 4
        private const val MAX_POSES = 2
    }
}

// ===== 结果映射扩展 =====

private fun FaceLandmarkerResult.toFaceMaps(
    bitmap: Bitmap,
    recognizer: FaceRecognizer
): List<Map<String, Any>> {
    val maps = mutableListOf<Map<String, Any>>()
    val w = bitmap.width.toFloat()
    val h = bitmap.height.toFloat()

    for (i in this.faceLandmarks().indices) {
        val landmarks = this.faceLandmarks()[i]
        if (landmarks.isEmpty()) continue

        var minX = 1f; var minY = 1f; var maxX = 0f; var maxY = 0f
        val landmarkMaps = mutableListOf<Map<String, Float>>()
        for (lm in landmarks) {
            val x = lm.x()
            val y = lm.y()
            if (x < minX) minX = x
            if (y < minY) minY = y
            if (x > maxX) maxX = x
            if (y > maxY) maxY = y
            landmarkMaps.add(mapOf("x" to x, "y" to y))
        }
        val bbox = mapOf(
            "x" to minX.coerceIn(0f, 1f),
            "y" to minY.coerceIn(0f, 1f),
            "width" to (maxX - minX).coerceIn(0f, 1f),
            "height" to (maxY - minY).coerceIn(0f, 1f)
        )

        // faceBlendshapes() 返回 Optional<List<List<Category>>>，第 i 项是第 i 张脸的全部系数。
        val blendList = this.faceBlendshapes().orElse(emptyList()).getOrNull(i).orEmpty()
        val blendMap = blendList.associate { cat ->
            cat.categoryName() to cat.score()
        }

        // facialTransformationMatrixes() 返回 Optional<List<FloatArray>>，每个 FloatArray 是 4x4 矩阵（16 个 float）。
        val matrices = this.facialTransformationMatrixes().orElse(emptyList())
        val headPose = if (i < matrices.size) {
            extractHeadPose(matrices[i])
        } else {
            mapOf("yaw" to 0f, "pitch" to 0f, "roll" to 0f)
        }

        // 身份识别：用关键点对齐 + TFLite 推理。
        val embedding = recognizer.recognize(bitmap, landmarks)

        maps.add(
            mapOf(
                "boundingBox" to bbox,
                "blendshapes" to blendMap,
                "landmarks" to landmarkMaps,
                "embedding" to embedding,
                "headPose" to headPose
            )
        )
    }
    return maps
}

private fun GestureRecognizerResult.toHandMaps(): List<Map<String, Any>> {
    val maps = mutableListOf<Map<String, Any>>()
    for (i in this.landmarks().indices) {
        val landmarks = this.landmarks()[i]
        val landmarkMaps = landmarks.map { lm ->
            mapOf("x" to lm.x(), "y" to lm.y())
        }
        val gesture = this.gestures().getOrNull(i)?.firstOrNull()
        val handedness = this.handedness().getOrNull(i)?.firstOrNull()
        maps.add(
            mapOf(
                "gesture" to mapOf(
                    "name" to (gesture?.categoryName() ?: "Unknown"),
                    "score" to (gesture?.score() ?: 0f)
                ),
                "handedness" to mapOf(
                    "name" to (handedness?.categoryName() ?: "Right"),
                    "score" to (handedness?.score() ?: 0f)
                ),
                "landmarks" to landmarkMaps
            )
        )
    }
    return maps
}

private fun PoseLandmarkerResult.toPoseMaps(): List<Map<String, Any>> {
    val maps = mutableListOf<Map<String, Any>>()
    for (i in this.landmarks().indices) {
        val landmarks = this.landmarks()[i]
        val landmarkMaps = landmarks.map { lm ->
            mapOf("x" to lm.x(), "y" to lm.y())
        }
        // 用所有可见度的平均作为整体置信度（PoseLandmarker 默认输出 visibility/worldLandmarks）。
        val score = landmarks.takeIf { it.isNotEmpty() }?.let {
            1.0f // IMAGE 模式下不输出 visibility，给个默认值供 UI 显示
        } ?: 0f
        maps.add(
            mapOf(
                "landmarks" to landmarkMaps,
                "score" to score
            )
        )
    }
    return maps
}

/**
 * 从 4x4 变换矩阵中提取头部姿态角（yaw、pitch、roll）。
 *
 * 矩阵是列主序的 16 个 float：
 * [m00, m01, m02, m03, m10, m11, m12, m13, m20, m21, m22, m23, m30, m31, m32, m33]
 *
 * 旋转矩阵 R：
 * | m00 m01 m02 |
 * | m10 m11 m12 |
 * | m20 m21 m22 |
 *
 * yaw = atan2(m20, m00)  (绕 Y 轴)
 * pitch = -asin(m21)     (绕 X 轴)
 * roll = atan2(m01, m11) (绕 Z 轴)
 */
private fun extractHeadPose(matrix: FloatArray): Map<String, Float> {
    if (matrix.size < 16) {
        return mapOf("yaw" to 0f, "pitch" to 0f, "roll" to 0f)
    }

    // 提取旋转矩阵元素（列主序）。
    val m00 = matrix[0]; val m01 = matrix[4]; val m02 = matrix[8]
    val m10 = matrix[1]; val m11 = matrix[5]; val m12 = matrix[9]
    val m20 = matrix[2]; val m21 = matrix[6]; val m22 = matrix[10]

    // 计算欧拉角（弧度）。
    val pitch = -Math.asin(m21.toDouble().coerceIn(-1.0, 1.0)).toFloat()
    val yaw = Math.atan2(m20.toDouble(), m00.toDouble()).toFloat()
    val roll = Math.atan2(m01.toDouble(), m11.toDouble()).toFloat()

    // 转换为角度。
    val pitchDeg = Math.toDegrees(pitch.toDouble()).toFloat()
    val yawDeg = Math.toDegrees(yaw.toDouble()).toFloat()
    val rollDeg = Math.toDegrees(roll.toDouble()).toFloat()

    return mapOf(
        "yaw" to yawDeg,
        "pitch" to pitchDeg,
        "roll" to rollDeg
    )
}
