import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'models.dart';

/// 与原生端（Android Kotlin / iOS Swift）通信的 MethodChannel 封装。
///
/// 每帧调用 [detect]，原生端会串行运行：
///   1. FaceLandmarker（人脸框 + 478 关键点 + blendshapes + 身份 embedding）
///   2. GestureRecognizer（21 关键点 + 手势名/惯用手）
///   3. PoseLandmarker（33 关键点）
/// 一次性返回全部结果。
class DetectionBridge {
  DetectionBridge();

  static const MethodChannel _channel = MethodChannel('xbot/detection');

  /// 处理一帧相机图像，返回检测结果。失败时抛 [PlatformException]。
  ///
  /// [mirror] 为 true 时，原生端会在旋转后对图像做水平镜像，使检测图像
  /// 与前置摄像头的镜像预览完全一致，叠加层无需额外镜像变换。
  Future<DetectionFrame> detect(
    CameraImage image, {
    required int rotationDegrees,
    bool mirror = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'detect',
      <String, dynamic>{
        'width': image.width,
        'height': image.height,
        'rotationDegrees': rotationDegrees,
        'mirror': mirror,
        'planes': image.planes
            .map((plane) => <String, dynamic>{
                  'bytes': plane.bytes,
                  'bytesPerRow': plane.bytesPerRow,
                  'bytesPerPixel': plane.bytesPerPixel ?? 1,
                })
            .toList(growable: false),
      },
    );

    if (result == null) {
      return DetectionFrame.empty;
    }

    final faces = (result['faces'] as List<dynamic>? ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(FaceDetection.fromMap)
        .toList(growable: false);
    final hands = (result['hands'] as List<dynamic>? ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(HandDetection.fromMap)
        .toList(growable: false);
    final poses = (result['poses'] as List<dynamic>? ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(PoseDetection.fromMap)
        .toList(growable: false);
    final w = (result['imageWidth'] as num?)?.toDouble() ?? 0;
    final h = (result['imageHeight'] as num?)?.toDouble() ?? 0;

    return DetectionFrame(
      faces: faces,
      hands: hands,
      poses: poses,
      imageSize: Size(w, h),
    );
  }

  /// 查询身份识别模型状态（是否加载成功 + 错误信息）。
  Future<Map<String, dynamic>> getRecognitionStatus() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getRecognitionStatus',
    );
    return result ?? const {'ready': false, 'error': 'unknown'};
  }
}
