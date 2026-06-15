import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../detection/detection_bridge.dart';
import '../detection/models.dart';

/// 摄像头管理服务：权限、初始化、取流、节流、调用原生检测。
///
/// 设计要点：
/// - 优先前置摄像头（自拍体验，便于人脸/手势交互）。
/// - 图像格式 YUV420（与原生端 YUV→Bitmap 管线匹配）。
/// - 140ms 节流 + [_isDetecting] 互斥锁，避免积压帧。
/// - 检测结果通过回调实时上报给 UI 层。
class CameraControllerService {
  CameraControllerService({DetectionBridge? bridge})
      : _bridge = bridge ?? DetectionBridge();

  final DetectionBridge _bridge;

  CameraController? _controller;
  CameraController? get controller => _controller;

  CameraDescription? _description;
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  /// 是否使用前置摄像头（决定叠加层是否镜像）。
  bool get isFrontCamera =>
      _description?.lensDirection == CameraLensDirection.front;

  /// 最小检测间隔。低于此间隔的帧直接丢弃。
  static const Duration _minInterval = Duration(milliseconds: 140);

  bool _isDetecting = false;
  DateTime _lastDetectionTime = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<CameraImage>? _streamSub;

  /// 最新一帧检测结果，供 UI 读取。
  DetectionFrame latest = DetectionFrame.empty;

  /// 外部设置的帧回调，用于在不重新初始化的情况下切换回调。
  void Function()? onFrameCallback;

  /// 请求相机权限，返回是否获得授权。
  Future<bool> requestPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  /// 初始化摄像头并开始取流。[onFrame] 每次成功检测后回调。
  Future<void> initialize({
    required void Function() onFrame,
    required void Function(String) onError,
  }) async {
    final granted = await requestPermission();
    if (!granted) {
      onError('未获得相机权限');
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      onError('设备没有可用的摄像头');
      return;
    }

    _description = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      _description!,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    await _controller!.startImageStream(
      (image) => _process(image, onFrame: onFrame, onError: onError),
    );

    // 运行期间保持屏幕常亮。
    WakelockPlus.enable();
  }

  Future<void> _process(
    CameraImage image, {
    required void Function() onFrame,
    required void Function(String) onError,
  }) async {
    final now = DateTime.now();
    if (_isDetecting || now.difference(_lastDetectionTime) < _minInterval) {
      return;
    }
    _isDetecting = true;
    _lastDetectionTime = now;

    try {
      // App 固定锁定 landscapeLeft，因此设备方向恒为 90°，无需依赖动态
      // deviceOrientation（它在摄像头刚启动时可能还未稳定，导致首帧旋转角算错）。
      const deviceDeg = 90;
      final sensorOrient = _description?.sensorOrientation ?? 0;
      final isFront = isFrontCamera;
      // 后摄：rotation = (sensorOrient - deviceDeg + 360) % 360
      // 前摄：镜像导致方向相反，rotation = (sensorOrient + deviceDeg) % 360
      final rotationDegrees = isFront
          ? (sensorOrient + deviceDeg) % 360
          : (sensorOrient - deviceDeg + 360) % 360;
      latest = await _bridge.detect(
        image,
        rotationDegrees: rotationDegrees,
        mirror: isFront, // 前摄镜像，使检测图像与预览一致。
      );
      onFrame();
      onFrameCallback?.call();
    } catch (error) {
      debugPrint('检测失败: $error');
      onError('检测失败：$error');
    } finally {
      _isDetecting = false;
    }
  }

  /// 切换前后摄像头（第一版保留接口，UI 可选实现）。
  Future<void> switchCamera({
    required void Function() onFrame,
    required void Function(String) onError,
  }) async {
    await dispose();
    final cameras = await availableCameras();
    if (cameras.length < 2) return;
    final currentDir = _description?.lensDirection;
    _description = cameras.firstWhere(
      (c) => c.lensDirection != currentDir,
      orElse: () => cameras.first,
    );
    _controller = CameraController(
      _description!,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    await _controller!.startImageStream(
      (image) => _process(image, onFrame: onFrame, onError: onError),
    );
  }

  Future<void> dispose() async {
    await _streamSub?.cancel();
    _streamSub = null;
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _controller = null;
    // 释放屏幕常亮。
    WakelockPlus.disable();
  }
}
