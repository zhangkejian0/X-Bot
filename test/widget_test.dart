import 'package:flutter_test/flutter_test.dart';
import 'package:xbot/detection/expression_rules.dart';

void main() {
  group('ExpressionRules', () {
    test('全零 blendshape 判定为中性', () {
      final b = ArkitBlendshapes.from({});
      final result = ExpressionRules.detect(b);
      expect(result.label, '中性');
    });

    test('微笑系数高判定为快乐', () {
      final b = ArkitBlendshapes.from({
        'mouthSmileLeft': 0.8,
        'mouthSmileRight': 0.8,
        'cheekSquintLeft': 0.6,
        'cheekSquintRight': 0.6,
      });
      final result = ExpressionRules.detect(b);
      expect(result.label, '快乐');
      expect(result.score, greaterThan(ExpressionRules.neutralThreshold));
    });

    test('张嘴睁眼判定为惊讶', () {
      final b = ArkitBlendshapes.from({
        'jawOpen': 0.7,
        'eyeWideLeft': 0.6,
        'eyeWideRight': 0.6,
        'browInnerUp': 0.5,
      });
      final result = ExpressionRules.detect(b);
      expect(result.label, '惊讶');
    });

    test('皱眉眯眼判定为愤怒', () {
      final b = ArkitBlendshapes.from({
        'browDownLeft': 0.9,
        'browDownRight': 0.9,
        'eyeSquintLeft': 0.7,
        'eyeSquintRight': 0.7,
        'mouthPressLeft': 0.5,
        'mouthPressRight': 0.5,
      });
      final result = ExpressionRules.detect(b);
      expect(result.label, '愤怒');
    });
  });
}
