import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../camera/camera_controller_service.dart';
import '../detection/detection_bridge.dart';
import '../detection/models.dart';
import '../recognition/face_recognition_store.dart';
import '../recognition/face_recognizer.dart';
import 'debug_panel.dart';
import 'loading_screen.dart';
import 'overlay_painter.dart';

/// 主屏幕：加载页 → 横屏全屏摄像头预览 + 检测叠加层 + 角落调试面板。
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
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

  // FPS 统计。
  int _frameCount = 0;
  DateTime _fpsTimestamp = DateTime.now();
  double _fps = 0;

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
              final status = await DetectionBridge().getRecognitionStatus();
              _recognitionReady = status['ready'] as bool? ?? false;
              _recognitionError = status['error'] as String? ?? '';
            } catch (_) {/* 忽略 */}
          },
        ),
        LoadingTask(
          label: '即将就绪',
          action: () async {},
        ),
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
    // 身份识别。
    final identities = <RecognitionResult>[];
    for (final face in frame.faces) {
      identities.add(_recognizer.recognize(face.embedding, _store?.faces ?? const []));
    }
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
        _identities = identities;
        _errorMessage = null;
      });
    }
  }

  Future<void> _registerCurrentFace() async {
    if (_store == null) return;
    if (_frame.faces.isEmpty) {
      _toast('没有检测到人脸');
      return;
    }
    final face = _frame.faces.first;
    if (face.embedding.isEmpty) {
      _toast(_recognitionReady ? 'embedding 为空' : '身份模型未加载，无法注册');
      return;
    }
    final name = await _promptName();
    if (name == null || name.trim().isEmpty) return;
    await _store!.register(name.trim(), face.embedding);
    _toast('已注册：$name');
  }

  Future<String?> _promptName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('注册人脸'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入姓名'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

              // 3. 调试面板（右上角）。
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: DebugPanel(
                    frame: _frame,
                    identities: _identities,
                    fps: _fps,
                    galleryCount: _store?.faces.length ?? 0,
                    onRegister: _registerCurrentFace,
                    previewSize: (ctrl != null && ctrl.value.isInitialized)
                        ? ctrl.value.previewSize
                        : null,
                    recognitionReady: _recognitionReady,
                    recognitionError: _recognitionError,
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
                        Text(_errorMessage!, style: const TextStyle(color: Colors.white)),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () => setState(() => _appReady = false),
                          child: const Text('重试'),
                        ),
                      ],
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
