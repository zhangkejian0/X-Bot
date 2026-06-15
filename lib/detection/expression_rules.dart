/// 基于 ARKit Blendshape 系数的表情规则引擎。
///
/// 输入：MediaPipe FaceLandmarker 输出的 52 个 ARKit blendshape 系数。
/// 输出：7 种表情之一 —— 中性/快乐/悲伤/惊讶/愤怒/恐惧/厌恶。
///
/// 设计与 FaceReader 项目验证过的方案一致：对每种情绪按 blendshape
/// 名称计算加权平均分，排序后取最高分；若最高分 < [neutralThreshold]
/// 则判定为「中性」。这种方式无需额外模型，延迟低且与 blendshapes 同步。
library;

/// 表情识别结果。
class ExpressionResult {
  const ExpressionResult(this.label, this.score);

  /// 表情中文名：中性/快乐/悲伤/惊讶/愤怒/恐惧/厌恶。
  final String label;

  /// 置信度 0.0 ~ 1.0（规则引擎加权得分；中性为 0）。
  final double score;

  @override
  String toString() => '$label ${(score * 100).round()}%';
}

/// ARKit 标准 52 个 blendshape 名称的便捷访问器。
///
/// MediaPipe FaceLandmarker 输出的 blendshape 名称遵循 ARKit 规范，
/// 此类对「成对的左/右系数」做平均/取大，简化表情规则编写。
class ArkitBlendshapes {
  ArkitBlendshapes.from(this._raw);

  final Map<String, double> _raw;

  double score(String name) => (_raw[name] ?? 0).clamp(0.0, 1.0);

  /// 多个系数的平均值。
  double average(List<String> names) {
    if (names.isEmpty) return 0;
    var sum = 0.0;
    for (final n in names) {
      sum += score(n);
    }
    return (sum / names.length).clamp(0.0, 1.0);
  }

  /// 多个系数的最大值。
  double maxOf(List<String> names) {
    if (names.isEmpty) return 0;
    var m = 0.0;
    for (final n in names) {
      final v = score(n);
      if (v > m) m = v;
    }
    return m.clamp(0.0, 1.0);
  }
}

class ExpressionRules {
  ExpressionRules._();

  /// 低于此分数判定为中性。
  static const double neutralThreshold = 0.45;

  static ExpressionResult detect(ArkitBlendshapes b) {
    final candidates = <ExpressionResult>[
      _surprise(b),
      _happy(b),
      _fear(b),
      _disgust(b),
      _anger(b),
      _sad(b),
    ];

    candidates.sort((a, c) => c.score.compareTo(a.score));
    final best = candidates.first;
    if (best.score < neutralThreshold) {
      return const ExpressionResult('中性', 0);
    }
    return best;
  }

  /// 惊讶：张嘴 + 睁大眼 + 抬眉。
  static ExpressionResult _surprise(ArkitBlendshapes b) {
    final score = b.score('jawOpen') * 0.45 +
        b.average(['eyeWideLeft', 'eyeWideRight']) * 0.25 +
        b.score('browInnerUp') * 0.20 +
        b.score('mouthFunnel') * 0.10;
    return ExpressionResult('惊讶', score.clamp(0.0, 1.0));
  }

  /// 快乐：微笑 + 鼓颊。
  static ExpressionResult _happy(ArkitBlendshapes b) {
    final score = b.average(['mouthSmileLeft', 'mouthSmileRight']) * 0.65 +
        b.average(['cheekSquintLeft', 'cheekSquintRight']) * 0.25 +
        (1 - b.score('jawOpen').clamp(0.0, 1.0)) * 0.10;
    return ExpressionResult('快乐', score.clamp(0.0, 1.0));
  }

  /// 恐惧：睁眼 + 抬眉 + 张嘴。
  static ExpressionResult _fear(ArkitBlendshapes b) {
    final score = b.average(['eyeWideLeft', 'eyeWideRight']) * 0.30 +
        b.score('browInnerUp') * 0.22 +
        b.average(['browOuterUpLeft', 'browOuterUpRight']) * 0.18 +
        b.score('jawOpen') * 0.15 +
        b.average(['mouthStretchLeft', 'mouthStretchRight']) * 0.15;
    return ExpressionResult('恐惧', score.clamp(0.0, 1.0));
  }

  /// 厌恶：皱鼻 + 抬上唇 + 皱眉 + 眯眼。
  static ExpressionResult _disgust(ArkitBlendshapes b) {
    final score = b.average(['noseSneerLeft', 'noseSneerRight']) * 0.35 +
        b.average(['mouthUpperUpLeft', 'mouthUpperUpRight']) * 0.25 +
        b.average(['browDownLeft', 'browDownRight']) * 0.20 +
        b.average(['eyeSquintLeft', 'eyeSquintRight']) * 0.20;
    return ExpressionResult('厌恶', score.clamp(0.0, 1.0));
  }

  /// 愤怒：皱眉 + 眯眼 + 抿嘴 + 嘴角下垂。
  static ExpressionResult _anger(ArkitBlendshapes b) {
    final score = b.average(['browDownLeft', 'browDownRight']) * 0.45 +
        b.average(['eyeSquintLeft', 'eyeSquintRight']) * 0.25 +
        b.average(['mouthPressLeft', 'mouthPressRight']) * 0.15 +
        b.average(['mouthFrownLeft', 'mouthFrownRight']) * 0.15;
    return ExpressionResult('愤怒', score.clamp(0.0, 1.0));
  }

  /// 悲伤：嘴角下垂 + 内眉上扬 + 下嘴唇耸。
  static ExpressionResult _sad(ArkitBlendshapes b) {
    final score = b.average(['mouthFrownLeft', 'mouthFrownRight']) * 0.55 +
        b.score('browInnerUp') * 0.25 +
        b.score('mouthShrugLower') * 0.20;
    return ExpressionResult('悲伤', score.clamp(0.0, 1.0));
  }
}
