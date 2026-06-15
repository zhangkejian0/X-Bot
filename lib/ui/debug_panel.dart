import 'package:flutter/material.dart';
import '../detection/models.dart';
import '../recognition/face_recognizer.dart';

/// 角落半透明调试面板，实时列出各项检测数值。
class DebugPanel extends StatelessWidget {
  const DebugPanel({
    super.key,
    required this.frame,
    required this.identities,
    required this.fps,
    required this.onRegister,
    required this.galleryCount,
    this.previewSize,
    this.recognitionReady = false,
    this.recognitionError = '',
  });

  final DetectionFrame frame;
  final List<RecognitionResult> identities;
  final double fps;
  final int galleryCount;
  final VoidCallback onRegister;
  final Size? previewSize;
  final bool recognitionReady;
  final String recognitionError;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.4)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          height: 1.35,
          fontFamily: 'monospace',
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const Divider(color: Colors.white24, height: 10),
            _section('尺寸', _sizeLines()),
            _section('身份模型', _recognitionLines()),
            _section('人脸 (${frame.faces.length})', _faceLines()),
            _section('手势 (${frame.hands.length})', _handLines()),
            _section('姿势 (${frame.poses.length})', _poseLines()),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onRegister,
                icon: const Icon(Icons.person_add_alt, size: 16),
                label: Text('注册当前人脸 (库 $galleryCount)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: const Size(0, 30),
                  textStyle: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Icon(Icons.bug_report, size: 14, color: Colors.tealAccent),
        const SizedBox(width: 4),
        const Text('X-Bot 调试', style: TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        Text('${fps.toStringAsFixed(1)} FPS', style: const TextStyle(color: Colors.amberAccent)),
      ],
    );
  }

  /// 尺寸对比：用于调试横屏坐标对齐问题。
  List<Widget> _sizeLines() {
    final img = frame.imageSize;
    return [
      Text('  img: ${img.width.toStringAsFixed(0)}x${img.height.toStringAsFixed(0)}'),
      if (previewSize != null)
        Text('  prv: ${previewSize!.width.toStringAsFixed(0)}x${previewSize!.height.toStringAsFixed(0)}'),
    ];
  }

  /// 身份模型状态：显示是否加载成功及失败原因。
  List<Widget> _recognitionLines() {
    if (recognitionReady) {
      return const [Text('  ✓ 已加载', style: TextStyle(color: Colors.lightGreenAccent))];
    }
    final err = recognitionError.isEmpty ? '未加载' : recognitionError;
    return [
      Text('  ✗ $err', style: const TextStyle(color: Colors.redAccent), maxLines: 3),
    ];
  }

  Widget _section(String title, List<Widget> lines) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
          ...lines,
        ],
      ),
    );
  }

  List<Widget> _faceLines() {
    if (frame.faces.isEmpty) return const [Text('  无')];
    return [
      for (var i = 0; i < frame.faces.length; i++)
        Text(() {
          final f = frame.faces[i];
          final id = i < identities.length && identities[i].isKnown
              ? identities[i].name
              : '未知';
          return '  #$i $id · ${f.expression.label} ${(f.expression.score * 100).round()}%';
        }()),
    ];
  }

  List<Widget> _handLines() {
    if (frame.hands.isEmpty) return const [Text('  无')];
    return [
      for (final h in frame.hands)
        Text('  ${h.label} ${(h.gestureScore * 100).round()}%'),
    ];
  }

  List<Widget> _poseLines() {
    if (frame.poses.isEmpty) return const [Text('  无')];
    return [
      for (var i = 0; i < frame.poses.length; i++)
        Text('  #$i 关键点 ${frame.poses[i].landmarks.length} · ${(frame.poses[i].score * 100).round()}%'),
    ];
  }
}
