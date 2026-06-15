import 'face_recognition_store.dart';

/// 基于 128 维 embedding 欧氏距离的人脸身份比对。
///
/// 第一版采用单 embedding 简单比对：
/// - 计算 query embedding 与每个注册人脸的欧氏距离。
/// - 最近距离 < [threshold] 且大于 [minDistanceMargin] 优于次近，则判定为该身份。
/// - 否则返回「未知」。
class FaceRecognizer {
  FaceRecognizer({this.threshold = 0.9});

  /// 判定为同一身份的距离上限。MobileFaceNet 典型值 0.8~1.0，留宽松一些便于现场调试。
  double threshold;

  /// 最近与次近距离的最小差值（防误识多人相似场景）。
  static const double minDistanceMargin = 0.05;

  RecognitionResult recognize(List<double> embedding, List<RegisteredFace> gallery) {
    if (embedding.isEmpty || gallery.isEmpty) {
      return const RecognitionResult.unknown();
    }

    RegisteredFace? best;
    RegisteredFace? second;
    double bestDist = double.infinity;
    double secondDist = double.infinity;

    for (final face in gallery) {
      final d = _euclidean(embedding, face.embedding);
      if (d < bestDist) {
        second = best;
        secondDist = bestDist;
        best = face;
        bestDist = d;
      } else if (d < secondDist) {
        second = face;
        secondDist = d;
      }
    }

    if (best == null || bestDist > threshold) {
      return const RecognitionResult.unknown();
    }
    // 第二身份存在且距离过近时，视为不可区分。
    if (second != null && (secondDist - bestDist) < minDistanceMargin) {
      return const RecognitionResult.unknown();
    }

    final confidence = (1.0 - (bestDist / threshold)).clamp(0.0, 1.0);
    return RecognitionResult(
      name: best.name,
      distance: bestDist,
      confidence: confidence,
      isKnown: true,
    );
  }

  double _euclidean(List<double> a, List<double> b) {
    final n = a.length < b.length ? a.length : b.length;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sum; // 不开方，相对比较等价且更快。
  }
}

class RecognitionResult {
  const RecognitionResult({
    required this.name,
    required this.distance,
    required this.confidence,
    required this.isKnown,
  });

  const RecognitionResult.unknown()
      : name = '未知',
        distance = double.infinity,
        confidence = 0,
        isKnown = false;

  final String name;
  final double distance;
  final double confidence;
  final bool isKnown;
}
