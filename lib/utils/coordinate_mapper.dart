import 'package:flutter/painting.dart';

/// 归一化检测坐标 → 横屏画布像素坐标映射器。
///
/// 设计原则：**预览渲染与叠加层绘制必须使用完全相同的几何变换**，否则
/// 人脸框/关键点会与画面错位。本类提供统一的 [layout]（cover 填充矩形）
/// 供两端共用。
///
/// 几何关系：
/// - 原生端已按 sensorOrientation 把图像旋转为「正立」（横屏比例，宽>高），
///   因此 [imageSize] 是旋转后的尺寸。
/// - 预览与叠加层都用 BoxFit.cover 填满横屏画布，会裁掉超出部分。
/// - 前置摄像头水平镜像（用户照镜子效果）。
class CoordinateMapper {
  CoordinateMapper({
    required this.imageSize,
    required this.canvasSize,
    required this.mirrorHorizontally,
  });

  /// 原生端处理后返回的图像尺寸（已旋转为正立）。
  final Size imageSize;

  /// 画布（屏幕）尺寸，通常是横屏物理像素。
  final Size canvasSize;

  /// 是否水平镜像（前置摄像头为 true）。
  final bool mirrorHorizontally;

  /// cover 填充的计算结果：source=源图被裁剪后的有效区域，
  /// destination=在画布上的填充矩形（对 cover 而言通常正好等于画布，
  /// 但 source 的偏移决定了归一化坐标的裁剪关系）。
  late final FittedSizes layout = applyBoxFit(
    BoxFit.cover,
    imageSize,
    canvasSize,
  );

  /// 源图被 cover 裁剪后保留的尺寸（像素）。
  Size get sourceCrop => layout.source;

  /// 把归一化点 (0..1, 0..1，基于完整源图) 映射为画布像素坐标。
  ///
  /// cover 会裁掉源图两侧。归一化坐标是基于完整源图的，所以要先换算回
  /// 源图像素，减去裁剪偏移，再按缩放比映射到画布。
  Offset mapPoint(Offset normalized) {
    final src = sourceCrop;
    final dst = layout.destination;
    if (imageSize.width <= 0 || imageSize.height <= 0) return Offset.zero;

    // 完整源图中的像素位置。
    double px = normalized.dx * imageSize.width;
    double py = normalized.dy * imageSize.height;

    // cover 在源图上的裁剪：当 imageSize 比例比画布「更宽」时裁左右，
    // 「更高」时裁上下。applyBoxFit 返回的 source 是裁剪后保留的尺寸，
    // 裁剪偏移 = (完整尺寸 - 保留尺寸) / 2。
    final offsetX = (imageSize.width - src.width) / 2;
    final offsetY = (imageSize.height - src.height) / 2;

    double dx = (px - offsetX) / src.width * dst.width;
    double dy = (py - offsetY) / src.height * dst.height;

    if (mirrorHorizontally) {
      dx = dst.width - dx;
    }
    return Offset(dx, dy);
  }

  /// 把归一化矩形映射为画布像素矩形。
  Rect mapRect(Rect normalized) {
    final tl = mapPoint(normalized.topLeft);
    final br = mapPoint(normalized.bottomRight);
    return Rect.fromLTRB(tl.dx, tl.dy, br.dx, br.dy);
  }
}
