import 'package:flutter/material.dart';
import '../detection/models.dart';
import '../utils/coordinate_mapper.dart';

/// 在摄像头预览之上绘制检测结果：人脸框+标签、手势骨架、姿势连线。
class DetectionOverlay extends CustomPainter {
  DetectionOverlay({
    required this.frame,
    required this.canvasSize,
    required this.mirrorHorizontally,
    required this.identityLabels,
  });

  final DetectionFrame frame;

  /// 当前画布尺寸（屏幕），用于构建 [CoordinateMapper]。
  final Size canvasSize;
  final bool mirrorHorizontally;

  /// 与 [frame.faces] 一一对应的身份标签（识别到的名字或「未知」）。
  final List<String> identityLabels;

  /// MediaPipe 21 个手部关键点连接关系。
  static const List<List<int>> _handConnections = [
    [0, 1], [1, 2], [2, 3], [3, 4], // 拇指
    [0, 5], [5, 6], [6, 7], [7, 8], // 食指
    [5, 9], [9, 10], [10, 11], [11, 12], // 中指
    [9, 13], [13, 14], [14, 15], [15, 16], // 无名指
    [13, 17], [17, 18], [18, 19], [19, 20], // 小指
    [0, 17], // 掌根
  ];

  /// MediaPipe 33 个姿势关键点连接关系（ BlazePose 拓扑）。
  static const List<List<int>> _poseConnections = [
    [0, 1], [1, 2], [2, 3], [3, 7], // 左眼
    [0, 4], [4, 5], [5, 6], [6, 8], // 右眼
    [9, 10], // 嘴
    [11, 12], // 肩
    [11, 13], [13, 15], [15, 17], [15, 19], [15, 21], [17, 19], // 左臂
    [12, 14], [14, 16], [16, 18], [16, 20], [16, 22], [18, 20], // 右臂
    [11, 23], [12, 24], [23, 24], // 躯干
    [23, 25], [25, 27], [27, 29], [27, 31], [29, 31], // 左腿
    [24, 26], [26, 28], [28, 30], [28, 32], [30, 32], // 右腿
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.imageSize == Size.zero) return;

    final mapper = CoordinateMapper(
      imageSize: frame.imageSize,
      canvasSize: size,
      mirrorHorizontally: mirrorHorizontally,
    );

    // 姿势（先画，置于底层）。
    for (final pose in frame.poses) {
      _drawPose(canvas, pose, mapper);
    }
    // 手势骨架。
    for (final hand in frame.hands) {
      _drawHand(canvas, hand, mapper);
    }
    // 人脸框 + 标签（最上层）。
    for (var i = 0; i < frame.faces.length; i++) {
      final identity = i < identityLabels.length ? identityLabels[i] : null;
      _drawFace(canvas, frame.faces[i], mapper, identity);
    }
  }

  void _drawFace(Canvas canvas, FaceDetection face, CoordinateMapper mapper, String? identity) {
    final rect = mapper.mapRect(face.boundingBox);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.tealAccent;

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(12)),
      paint,
    );

    // 标签：表情 + 身份。
    final labelParts = <String>[face.expression.label];
    if (identity != null) labelParts.insert(0, identity);
    final label = labelParts.join(' · ');
    _drawLabel(canvas, label, rect.topLeft + const Offset(0, -22));
  }

  void _drawHand(Canvas canvas, HandDetection hand, CoordinateMapper mapper) {
    final points = hand.landmarks.map(mapper.mapPoint).toList();
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.orangeAccent;
    final dotPaint = Paint()..color = Colors.white;

    for (final conn in _handConnections) {
      if (conn.first < points.length && conn.last < points.length) {
        canvas.drawLine(points[conn.first], points[conn.last], linePaint);
      }
    }
    for (final p in points) {
      canvas.drawCircle(p, 4, dotPaint);
    }

    // 顶部标签。
    final minX = points.fold<double>(double.infinity, (a, p) => a < p.dx ? a : p.dx);
    final minY = points.fold<double>(double.infinity, (a, p) => a < p.dy ? a : p.dy);
    _drawLabel(canvas, hand.label, Offset(minX, minY - 22));
  }

  void _drawPose(Canvas canvas, PoseDetection pose, CoordinateMapper mapper) {
    final points = pose.landmarks.map(mapper.mapPoint).toList();
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.greenAccent;
    final dotPaint = Paint()..color = Colors.yellow;

    for (final conn in _poseConnections) {
      if (conn.first < points.length && conn.last < points.length) {
        canvas.drawLine(points[conn.first], points[conn.last], linePaint);
      }
    }
    for (final p in points) {
      canvas.drawCircle(p, 4, dotPaint);
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset topLeft) {
    const style = TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600);
    final span = TextSpan(text: text, style: style);
    final painter = TextPainter(
      text: span,
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
    )..layout();

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(topLeft.dx, topLeft.dy, painter.width + 12, painter.height + 6),
      const Radius.circular(6),
    );
    canvas.drawRRect(
      bgRect,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    painter.paint(canvas, topLeft + const Offset(6, 3));
  }

  @override
  bool shouldRepaint(covariant DetectionOverlay old) {
    return old.frame != frame ||
        old.mirrorHorizontally != mirrorHorizontally ||
        old.identityLabels.length != identityLabels.length;
  }
}
