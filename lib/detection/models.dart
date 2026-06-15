/// 检测结果数据模型。
///
/// 原生端（Android/iOS）通过 MethodChannel 返回的 Map 会被解析为这里的
/// 不可变数据类。所有坐标均为「归一化坐标」（0.0 ~ 1.0），基于检测时
/// 的图像尺寸；叠加层绘制时再由 [CoordinateMapper] 映射到画布像素。
library;

import 'dart:ui';

import 'expression_rules.dart';

/// 头部姿态角（yaw、pitch、roll）。
class HeadPose {
  const HeadPose({
    this.yaw = 0,
    this.pitch = 0,
    this.roll = 0,
  });

  /// 偏航角（绕 Y 轴），正值向右转，负值向左转。
  final double yaw;

  /// 俯仰角（绕 X 轴），正值抬头，负值低头。
  final double pitch;

  /// 翻滚角（绕 Z 轴），正值向右歪头，负值向左歪头。
  final double roll;

  factory HeadPose.fromMap(Map<dynamic, dynamic> map) {
    return HeadPose(
      yaw: ((map['yaw'] as num?) ?? 0).toDouble(),
      pitch: ((map['pitch'] as num?) ?? 0).toDouble(),
      roll: ((map['roll'] as num?) ?? 0).toDouble(),
    );
  }

  @override
  String toString() => 'HeadPose(yaw: ${yaw.toStringAsFixed(1)}°, pitch: ${pitch.toStringAsFixed(1)}°, roll: ${roll.toStringAsFixed(1)}°)';
}

/// 单个人脸的检测结果。
class FaceDetection {
  FaceDetection({
    required this.boundingBox,
    required this.blendshapes,
    required this.expression,
    required this.landmarks,
    this.embedding = const [],
    this.headPose = const HeadPose(),
  });

  /// 归一化人脸框 (x, y, w, h ∈ 0..1)。
  final Rect boundingBox;

  /// 原始 MediaPipe blendshape 系数 (name -> 0..1)。
  final Map<String, double> blendshapes;

  /// 由 [blendshapes] 规则推断出的表情。
  final ExpressionResult expression;

  /// 归一化关键点列表 (478 点)，可为空以节省传输（叠加层主要用 bbox）。
  final List<Offset> landmarks;

  /// 身份识别 128 维特征向量（原生端对齐+TFLite 推理得到）。无模型时为空。
  final List<double> embedding;

  /// 头部姿态角（yaw、pitch、roll）。
  final HeadPose headPose;

  factory FaceDetection.fromMap(Map<dynamic, dynamic> map) {
    final bb = (map['boundingBox'] as Map<dynamic, dynamic>?) ?? const {};
    final rawBlendshapes =
        (map['blendshapes'] as Map<dynamic, dynamic>?) ?? const {};
    final blendshapes = rawBlendshapes.map(
      (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
    );
    final arkit = ArkitBlendshapes.from(blendshapes);
    final expression = ExpressionRules.detect(arkit);

    final rawLandmarks = (map['landmarks'] as List<dynamic>?) ?? const [];
    final landmarks = rawLandmarks
        .whereType<Map<dynamic, dynamic>>()
        .map((p) => Offset(
              ((p['x'] as num?) ?? 0).toDouble(),
              ((p['y'] as num?) ?? 0).toDouble(),
            ))
        .toList(growable: false);

    final rawEmbedding = (map['embedding'] as List<dynamic>?) ?? const [];
    final embedding = rawEmbedding
        .whereType<num>()
        .map((e) => e.toDouble())
        .toList(growable: false);

    final rawHeadPose = (map['headPose'] as Map<dynamic, dynamic>?) ?? const {};
    final headPose = HeadPose.fromMap(rawHeadPose);

    return FaceDetection(
      boundingBox: Rect.fromLTWH(
        ((bb['x'] as num?) ?? 0).toDouble(),
        ((bb['y'] as num?) ?? 0).toDouble(),
        ((bb['width'] as num?) ?? 0).toDouble(),
        ((bb['height'] as num?) ?? 0).toDouble(),
      ),
      blendshapes: blendshapes,
      expression: expression,
      landmarks: landmarks,
      embedding: embedding,
      headPose: headPose,
    );
  }
}

/// 单个手势的检测结果。
class HandDetection {
  HandDetection({
    required this.gesture,
    required this.gestureScore,
    required this.handedness,
    required this.handednessScore,
    required this.landmarks,
  });

  /// MediaPipe 手势英文名，如 "Closed_Fist"。
  final String gesture;

  /// 手势置信度 0..1。
  final double gestureScore;

  /// 惯用手："Left" / "Right"。
  final String handedness;

  final double handednessScore;

  /// 21 个归一化关键点。
  final List<Offset> landmarks;

  String get chineseGesture => gestureLabels[gesture] ?? gesture;

  String get label {
    final hand = handedness == 'Left' ? '右手' : '左手';
    return '$hand $chineseGesture';
  }

  factory HandDetection.fromMap(Map<dynamic, dynamic> map) {
    final gestureMap = (map['gesture'] as Map<dynamic, dynamic>?) ?? const {};
    final handMap =
        (map['handedness'] as Map<dynamic, dynamic>?) ?? const {};
    final rawLandmarks = (map['landmarks'] as List<dynamic>?) ?? const [];
    final landmarks = rawLandmarks
        .whereType<Map<dynamic, dynamic>>()
        .map((p) => Offset(
              ((p['x'] as num?) ?? 0).toDouble(),
              ((p['y'] as num?) ?? 0).toDouble(),
            ))
        .toList(growable: false);
    return HandDetection(
      gesture: (gestureMap['name'] as String?) ?? 'Unknown',
      gestureScore: ((gestureMap['score'] as num?) ?? 0).toDouble(),
      handedness: (handMap['name'] as String?) ?? 'Right',
      handednessScore: ((handMap['score'] as num?) ?? 0).toDouble(),
      landmarks: landmarks,
    );
  }
}

/// MediaPipe → 中文手势名。
const Map<String, String> gestureLabels = {
  'Closed_Fist': '握拳',
  'Open_Palm': '张开手掌',
  'Pointing_Up': '指向上',
  'Thumb_Down': '踩',
  'Thumb_Up': '点赞',
  'Victory': '胜利',
  'ILoveYou': '我爱你',
  'None': '无',
  'Unknown': '未知',
};

/// 单个人体姿势的检测结果（33 个关键点）。
class PoseDetection {
  PoseDetection({
    required this.landmarks,
    required this.score,
  });

  /// 33 个归一化关键点。
  final List<Offset> landmarks;

  /// 整体可见性/置信度。
  final double score;

  factory PoseDetection.fromMap(Map<dynamic, dynamic> map) {
    final rawLandmarks = (map['landmarks'] as List<dynamic>?) ?? const [];
    final landmarks = rawLandmarks
        .whereType<Map<dynamic, dynamic>>()
        .map((p) => Offset(
              ((p['x'] as num?) ?? 0).toDouble(),
              ((p['y'] as num?) ?? 0).toDouble(),
            ))
        .toList(growable: false);
    return PoseDetection(
      landmarks: landmarks,
      score: ((map['score'] as num?) ?? 0).toDouble(),
    );
  }
}

/// 一帧的全部检测结果。
class DetectionFrame {
  const DetectionFrame({
    required this.faces,
    required this.hands,
    required this.poses,
    required this.imageSize,
  });

  final List<FaceDetection> faces;
  final List<HandDetection> hands;
  final List<PoseDetection> poses;

  /// 原生端实际处理的图像尺寸（用于坐标映射）。
  final Size imageSize;

  static DetectionFrame empty =
      DetectionFrame(faces: const [], hands: const [], poses: const [], imageSize: Size.zero);
}
