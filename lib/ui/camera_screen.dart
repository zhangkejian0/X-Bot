import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../camera/camera_controller_service.dart';
import '../detection/detection_bridge.dart';
import '../detection/expression_rules.dart';
import '../detection/models.dart';
import '../recognition/face_recognition_store.dart';
import '../recognition/face_recognizer.dart';
import 'debug_panel.dart';
import 'loading_screen.dart';
import 'overlay_painter.dart';
import 'settings_screen.dart';

/// 主屏幕：加载页 → 横屏全屏摄像头预览 + 检测叠加层 + 角落调试面板。
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  final CameraControllerService _cameraService = CameraControllerService();
  final FaceRecognizer _recognizer = FaceRecognizer();
  FaceRecognitionStore? _store;

  DetectionFrame _frame = DetectionFrame.empty;
  List<RecognitionResult> _identities = const [];
  String? _errorMessage;

  /// App 是否完成加载（摄像头+模型就绪）。false 时显示加载页。
  bool _appReady = false;

  /// 预览是否已稳定（previewSize 连续多次不变），稳定后才渲染 CameraPreview，
  /// 避免加载完成后首帧画面变形。
  bool _previewStable = false;

  // 身份识别模型状态（供调试面板显示失败原因）。
  bool _recognitionReady = false;
  String _recognitionError = '';

  // 调试面板开关。
  bool _showDebugPanel = false;

  // FPS 统计。
  int _frameCount = 0;
  DateTime _fpsTimestamp = DateTime.now();
  double _fps = 0;

  // 时序平滑相关状态。
  static const int _smoothWindowSize = 5;
  final Map<int, List<RecognitionResult>> _identityHistory = {};
  final Map<int, List<ExpressionResult>> _expressionHistory = {};
  List<RecognitionResult> _smoothedIdentities = const [];

  /// 用于「等待首帧检测数据」的 Completer。
  Completer<void>? _firstFrameCompleter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _cameraService.dispose();
    } else if (state == AppLifecycleState.resumed && _appReady) {
      // 从后台恢复时重新走加载流程。
      setState(() {
        _appReady = false;
        _previewStable = false;
      });
    }
  }

  /// 加载页的有序任务：摄像头 → 等待首帧 → 查询身份模型。
  List<LoadingTask> get _loadingTasks => [
    LoadingTask(
      label: '初始化摄像头...',
      action: () async {
        final dir = await getApplicationDocumentsDirectory();
        _store = FaceRecognitionStore(File('${dir.path}/face_db.json'));
        await _store!.load();
        _firstFrameCompleter = Completer<void>();
        await _cameraService.initialize(
          onFrame: _onDetectionFrame,
          onError: (msg) {
            if (mounted) setState(() => _errorMessage = msg);
          },
        );
      },
    ),
    LoadingTask(
      label: '加载检测模型...',
      action: () async {
        // 等待原生端跑完第一帧检测（MediaPipe 模型已加载），最多等 8 秒。
        await _firstFrameCompleter?.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () {},
        );
      },
    ),
    LoadingTask(
      label: '稳定摄像头预览...',
      action: () async {
        // 轮询 previewSize，连续 3 次相同才算稳定，避免渲染方向未稳定
        // 时显示变形画面。最多等待 3 秒。
        await _waitForPreviewStable();
      },
    ),
    LoadingTask(
      label: '加载身份模型...',
      action: () async {
        try {
          final status = await DetectionBridge().getRecognitionStatus().timeout(
            const Duration(seconds: 5),
            onTimeout: () => const {'ready': false, 'error': 'timeout'},
          );
          _recognitionReady = status['ready'] as bool? ?? false;
          _recognitionError = status['error'] as String? ?? '';
        } catch (_) {
          /* 忽略 */
        }
      },
    ),
    LoadingTask(label: '即将就绪', action: () async {}),
  ];

  /// 轮询 previewSize，连续 3 次（每次间隔 150ms）读取到相同的值才认为预览稳定，
  /// 稳定后再额外等待 2 秒，确保渲染方向完全就绪，避免加载完成后画面变形。
  /// 最多等待 5 秒，超时后也认为稳定（避免无限等待）。
  Future<void> _waitForPreviewStable() async {
    Size? lastSize;
    var stableCount = 0;
    const interval = Duration(milliseconds: 150);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(interval);
      final current = _cameraService.controller?.value.previewSize;
      if (current != null && current == lastSize) {
        stableCount++;
        if (stableCount >= 3) break;
      } else {
        stableCount = 0;
      }
      lastSize = current;
    }
    // 额外等待 2 秒，确保 CameraPreview 渲染方向彻底稳定。
    await Future.delayed(const Duration(seconds: 2));
    _previewStable = true;
  }

  void _onLoadingComplete() {
    if (mounted) setState(() => _appReady = true);
  }

  void _onDetectionFrame() {
    final frame = _cameraService.latest;
    // 首帧完成时通知加载页。
    if (!(_firstFrameCompleter?.isCompleted ?? true) &&
        frame.imageSize != Size.zero) {
      _firstFrameCompleter?.complete();
    }
    // 逐帧识别。
    final rawIdentities = <RecognitionResult>[];
    for (var i = 0; i < frame.faces.length; i++) {
      rawIdentities.add(
        _recognizer.recognize(
          frame.faces[i].embedding,
          _store?.faces ?? const [],
        ),
      );
    }
    // 滑动窗口投票。
    _pruneHistory(frame.faces.length);
    for (var i = 0; i < rawIdentities.length; i++) {
      _identityHistory.putIfAbsent(i, () => []);
      final history = _identityHistory[i]!;
      history.add(rawIdentities[i]);
      if (history.length > _smoothWindowSize) history.removeAt(0);
    }
    // 表情也做平滑。
    for (var i = 0; i < frame.faces.length; i++) {
      _expressionHistory.putIfAbsent(i, () => []);
      final history = _expressionHistory[i]!;
      history.add(frame.faces[i].expression);
      if (history.length > _smoothWindowSize) history.removeAt(0);
    }
    // 投票决定最终身份。
    _smoothedIdentities = List.generate(frame.faces.length, (i) {
      return _voteIdentity(_identityHistory[i] ?? const []);
    });
    // FPS。
    _frameCount++;
    final now = DateTime.now();
    if (now.difference(_fpsTimestamp) >= const Duration(seconds: 1)) {
      _fps = _frameCount / now.difference(_fpsTimestamp).inSeconds;
      _frameCount = 0;
      _fpsTimestamp = now;
    }
    if (mounted) {
      setState(() {
        _frame = frame;
        _identities = _smoothedIdentities;
        _errorMessage = null;
      });
    }
  }

  /// 多数投票：窗口内出现次数最多的身份胜出，票数不足半数则判定「未知」。
  RecognitionResult _voteIdentity(List<RecognitionResult> history) {
    if (history.isEmpty) return const RecognitionResult.unknown();
    // 统计各身份出现次数及对应的最佳距离。
    final counts = <String, int>{};
    final bestDists = <String, double>{};
    final bestConfs = <String, double>{};
    for (final r in history) {
      final key = r.isKnown ? r.name : '未知';
      counts[key] = (counts[key] ?? 0) + 1;
      if (r.isKnown) {
        bestDists[key] = bestDists[key] != null
            ? (bestDists[key]! < r.distance ? bestDists[key]! : r.distance)
            : r.distance;
        bestConfs[key] = bestConfs[key] != null
            ? (bestConfs[key]! > r.confidence ? bestConfs[key]! : r.confidence)
            : r.confidence;
      }
    }
    // 找票数最高的。
    String winner = '未知';
    int maxVotes = 0;
    counts.forEach((name, count) {
      if (count > maxVotes) {
        maxVotes = count;
        winner = name;
      }
    });
    // 不足半数 → 未知。
    final threshold = (history.length * 0.6).ceil();
    if (maxVotes < threshold || winner == '未知') {
      return const RecognitionResult.unknown();
    }
    return RecognitionResult(
      name: winner,
      distance: bestDists[winner] ?? 0,
      confidence: bestConfs[winner] ?? 0,
      isKnown: true,
    );
  }

  /// 清除已消失人脸的历史。
  void _pruneHistory(int currentFaceCount) {
    _identityHistory.removeWhere((key, _) => key >= currentFaceCount);
    _expressionHistory.removeWhere((key, _) => key >= currentFaceCount);
  }

  Future<void> _registerCurrentFace() async {
    if (_store == null) return;
    if (_frame.faces.isEmpty) {
      _toast('没有检测到人脸，请正对摄像头');
      return;
    }
    final face = _frame.faces.first;
    if (face.embedding.isEmpty) {
      _toast(_recognitionReady ? '特征提取失败' : '身份模型未加载，无法录入');
      return;
    }
    final name = await _promptName();
    if (name == null || name.trim().isEmpty) return;
    await _store!.register(name.trim(), face.embedding);
    _toast('记住 $name 啦～下次见一定认得你！');
  }

  Future<String?> _promptName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('想让我怎么称呼你？'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '你的名字或昵称'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('记住我'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 打开设置页面。
  void _openSettings() {
    if (_store == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          store: _store!,
          currentFrame: _frame,
          recognitionReady: _recognitionReady,
          recognitionError: _recognitionError,
          cameraService: _cameraService,
        ),
      ),
    );
  }

  Widget _buildActionButton(
    IconData icon,
    String label, {
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap:
          onTap ??
          () {
            _toast('$label 功能开发中...');
          },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 加载阶段：显示加载页。
    if (!_appReady) {
      return LoadingScreen(
        tasks: _loadingTasks,
        onComplete: _onLoadingComplete,
        // 可替换背景图：把图片放到 assets/images/ 并取消下行注释。
        // backgroundImageAsset: 'assets/images/loading_background.png',
      );
    }

    // 运行阶段：摄像头 + 叠加层 + 调试面板。
    return _buildCameraView();
  }

  Widget _buildCameraView() {
    final controller = _cameraService.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
          final hasImage = _frame.imageSize != Size.zero;
          final ctrl = controller;

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. 摄像头预览（全屏铺满）。仅在预览方向稳定后才渲染，
              //    避免加载完成后首帧画面变形。
              if (ctrl != null && ctrl.value.isInitialized && _previewStable)
                Positioned.fill(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox.fromSize(
                      size: ctrl.value.previewSize,
                      child: CameraPreview(ctrl),
                    ),
                  ),
                )
              else
                const ColoredBox(color: Colors.black),

              // 2. 检测叠加层（与预览同尺寸，坐标由 mapper 映射）。
              if (ctrl != null && ctrl.value.isInitialized && hasImage)
                Positioned.fill(
                  child: CustomPaint(
                    painter: DetectionOverlay(
                      frame: _frame,
                      canvasSize: screenSize,
                      mirrorHorizontally: false,
                      identityLabels: _identities
                          .map((r) => r.isKnown ? r.name : '未知')
                          .toList(),
                    ),
                  ),
                ),

              // 3. 调试面板（左上角）+ 开关。
              Positioned(
                top: 0,
                left: 0,
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 调试开关按钮。
                      GestureDetector(
                        onTap: () =>
                            setState(() => _showDebugPanel = !_showDebugPanel),
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            _showDebugPanel
                                ? Icons.bug_report
                                : Icons.bug_report_outlined,
                            color: _showDebugPanel
                                ? Colors.tealAccent
                                : Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                      // 调试面板（可折叠）。
                      if (_showDebugPanel)
                        DebugPanel(
                          frame: _frame,
                          identities: _identities,
                          fps: _fps,
                          galleryCount: _store?.faces.length ?? 0,
                          onRegister: _registerCurrentFace,
                          previewSize:
                              (ctrl != null && ctrl.value.isInitialized)
                              ? ctrl.value.previewSize
                              : null,
                          recognitionReady: _recognitionReady,
                          recognitionError: _recognitionError,
                        ),
                    ],
                  ),
                ),
              ),

              // 4. 错误状态。
              if (_errorMessage != null)
                Center(
                  child: Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () => setState(() => _appReady = false),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),

              // 5. 右侧悬浮操作栏。
              Positioned(
                right: 16,
                top: 0,
                bottom: 0,
                child: SafeArea(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildActionButton(Icons.chat_bubble_outline, 'AI对话'),
                          const SizedBox(height: 24),
                          _buildActionButton(Icons.trending_up, '成长'),
                          const SizedBox(height: 24),
                          _buildActionButton(
                            Icons.settings_outlined,
                            '设置',
                            onTap: _openSettings,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
