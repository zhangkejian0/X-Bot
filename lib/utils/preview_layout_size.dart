import 'package:flutter/painting.dart';

/// 预览 FittedBox 的布局尺寸，需与 [detectionImageSize]（img）坐标系一致，
/// 叠加层 [CoordinateMapper] 才能与 CameraPreview 对齐。
///
/// 横屏 App 下 [cameraPreviewSize] 常为传感器竖屏尺寸（宽<高），
/// 而原生检测管线旋转后返回的 img 为横屏尺寸（宽>高）。
Size previewLayoutSize({
  required Size? cameraPreviewSize,
  required Size detectionImageSize,
}) {
  if (detectionImageSize != Size.zero) return detectionImageSize;
  if (cameraPreviewSize == null) return Size.zero;
  if (cameraPreviewSize.width < cameraPreviewSize.height) {
    return Size(cameraPreviewSize.height, cameraPreviewSize.width);
  }
  return cameraPreviewSize;
}
