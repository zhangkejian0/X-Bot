import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../camera/camera_controller_service.dart';
import '../detection/models.dart';
import '../recognition/face_recognition_store.dart';

/// 录入步骤枚举。
enum RegistrationStep {
  ready, // 准备状态
  front, // 采集正脸
  left, // 采集左侧
  right, // 采集右侧
  complete, // 采集完成
  failed, // 采集失败
}

/// 候选帧数据类。
class _CandidateEmbedding {
  final List<double> embedding;
  final double yaw;
  final double faceSize;
  final DateTime timestamp;
  
  _CandidateEmbedding({
    required this.embedding,
    required this.yaw,
    required this.faceSize,
    required this.timestamp,
  });
}

/// iOS Face ID 风格的人脸录入页面（横屏）。
///
/// 左侧：圆形摄像头取景框 + 放射状刻度进度环（随采集角度逐段点亮）。
/// 右侧：iOS 分组风格的个人信息表单。
class FaceRegistrationScreen extends StatefulWidget {
  const FaceRegistrationScreen({
    super.key,
    required this.cameraService,
    required this.store,
    required this.recognitionReady,
  });

  final CameraControllerService cameraService;
  final FaceRecognitionStore store;
  final bool recognitionReady;

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen>
    with TickerProviderStateMixin {
  // ===== iOS 调色板 =====
  static const _bg = Color(0xFF000000);
  static const _card = Color(0xFF1C1C1E);
  static const _cardRow = Color(0xFF2C2C2E);
  static const _separator = Color(0xFF38383A);
  static const _label = Color(0xFF8E8E93);
  static const _blue = Color(0xFF0A84FF);
  static const _green = Color(0xFF30D158);
  static const _orange = Color(0xFFFF9F0A);
  static const _red = Color(0xFFFF453A);

  // 表单控制器。
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _notesController = TextEditingController();

  // 表单状态。
  String? _gender;
  String? _relationship;
  DateTime? _birthday;

  // 人脸检测状态。
  DetectionFrame _currentFrame = DetectionFrame.empty;
  bool _faceDetected = false;
  bool _faceInCircle = false;

  // 多角度录入状态。
  RegistrationStep _step = RegistrationStep.ready;
  final Map<RegistrationStep, List<double>> _collectedEmbeddings = {};
  bool _isProcessing = false;

  /// 第一次转头采集到的偏航方向符号（-1 / 1），用于要求第二次转向相反方向。
  /// 不直接区分左右，避免前置摄像头镜像导致的 yaw 符号不确定问题。
  double _firstSideSign = 0;

  // 多帧择优相关状态。
  final Map<RegistrationStep, List<_CandidateEmbedding>> _candidateEmbeddings = {};
  DateTime? _collectionWindowStart;
  static const Duration _collectionWindow = Duration(milliseconds: 800);
  static const int _maxCandidates = 5;

  // 动画控制器。
  late final AnimationController _pulseController; // 采集成功脉冲
  late final Animation<double> _pulseAnimation;
  late final AnimationController _scanController; // 扫描呼吸光环

  // 步骤超时计时器。
  DateTime? _stepStartTime;
  static const Duration _stepTimeout = Duration(seconds: 20);

  // 姿态阈值（度）。阈值放低，转头幅度无需太大即可触发。
  static const double _yawThreshold = 18.0;
  static const double _frontYawThreshold = 12.0;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    _scanController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();

    widget.cameraService.onFrameCallback = _onFrame;
  }

  @override
  void dispose() {
    widget.cameraService.onFrameCallback = null;
    _nameController.dispose();
    _ageController.dispose();
    _notesController.dispose();
    _pulseController.dispose();
    _scanController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // 检测逻辑
  // ===========================================================================

  void _onFrame() {
    final frame = widget.cameraService.latest;
    if (!mounted) return;

    setState(() {
      _currentFrame = frame;
      _faceDetected = frame.faces.isNotEmpty;

      if (_faceDetected) {
        final bbox = frame.faces.first.boundingBox;
        final faceCenterX = bbox.left + bbox.width / 2;
        final faceCenterY = bbox.top + bbox.height / 2;
        final faceSize = bbox.width;

        _faceInCircle = faceCenterX > 0.22 &&
            faceCenterX < 0.78 &&
            faceCenterY > 0.12 &&
            faceCenterY < 0.80 &&
            faceSize > 0.14 &&
            faceSize < 0.65;
      } else {
        _faceInCircle = false;
      }
    });

    if (_step == RegistrationStep.front ||
        _step == RegistrationStep.left ||
        _step == RegistrationStep.right) {
      _checkPoseAndCollect();
    }
  }

  void _checkPoseAndCollect() {
    // 转头时人脸会偏移出圆心，因此只有「正脸」步骤要求在圆框内，
    // 侧脸步骤只要求检测到人脸即可，避免转头时被 _faceInCircle 拦截。
    if (!_faceDetected || _isProcessing) return;

    final face = _currentFrame.faces.first;
    final yaw = face.headPose.yaw;
    final bbox = face.boundingBox;
    final faceSize = bbox.width;

    bool shouldCollect = false;
    switch (_step) {
      case RegistrationStep.front:
        shouldCollect = _faceInCircle && yaw.abs() < _frontYawThreshold;
        break;
      case RegistrationStep.left:
        // 第一次转头：转向任意一侧超过阈值即可，记录方向符号。
        if (yaw.abs() > _yawThreshold) {
          _firstSideSign = yaw < 0 ? -1 : 1;
          shouldCollect = true;
        }
        break;
      case RegistrationStep.right:
        // 第二次转头：必须转向与第一次相反的方向。
        if (yaw.abs() > _yawThreshold && (yaw < 0 ? -1 : 1) != _firstSideSign) {
          shouldCollect = true;
        }
        break;
      default:
        break;
    }

    if (shouldCollect && face.embedding.isNotEmpty) {
      // 如果已经在采集窗口中，继续收集候选帧。
      if (_collectionWindowStart != null) {
        _candidateEmbeddings[_step]!.add(_CandidateEmbedding(
          embedding: List.from(face.embedding),
          yaw: yaw,
          faceSize: faceSize,
          timestamp: DateTime.now(),
        ));
        // 检查是否达到最大候选数或窗口结束。
        if (_candidateEmbeddings[_step]!.length >= _maxCandidates ||
            DateTime.now().difference(_collectionWindowStart!) > _collectionWindow) {
          _selectBestEmbedding();
        }
      } else {
        // 开始新的采集窗口。
        _collectionWindowStart = DateTime.now();
        _candidateEmbeddings[_step] = [];
        _candidateEmbeddings[_step]!.add(_CandidateEmbedding(
          embedding: List.from(face.embedding),
          yaw: yaw,
          faceSize: faceSize,
          timestamp: DateTime.now(),
        ));
      }
    }

    if (_stepStartTime != null &&
        DateTime.now().difference(_stepStartTime!) > _stepTimeout) {
      setState(() => _step = RegistrationStep.failed);
    }
  }

  void _selectBestEmbedding() {
    final candidates = _candidateEmbeddings[_step];
    if (candidates == null || candidates.isEmpty) return;
    // 质量评估：姿态接近目标 + 人脸大小 + 时间衰减。
    _CandidateEmbedding best = candidates.first;
    double bestScore = 0;
    for (final candidate in candidates) {
      double score = 0;
      // 姿态评分（越接近目标越好）。
      switch (_step) {
        case RegistrationStep.front:
          score += (1 - candidate.yaw.abs() / 30) * 40; // 正脸：yaw越小越好
          break;
        case RegistrationStep.left:
        case RegistrationStep.right:
          score += (candidate.yaw.abs() / 30) * 30; // 侧脸：yaw越大越好
          break;
        default:
          break;
      }
      // 人脸大小评分（适中大小最好）。
      score += (1 - (candidate.faceSize - 0.3).abs() / 0.3) * 30;
      // 时间衰减（越新的帧越好）。
      final age = DateTime.now().difference(candidate.timestamp).inMilliseconds;
      score += (1 - age / 800) * 30;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    // 使用最优帧。
    _collectEmbedding(best.embedding);
    _collectionWindowStart = null;
    _candidateEmbeddings[_step] = [];
  }

  void _collectEmbedding(List<double> embedding) {
    if (_isProcessing) return;
    _isProcessing = true;

    setState(() => _collectedEmbeddings[_step] = List.from(embedding));
    _pulseController.forward(from: 0).then((_) => _pulseController.reverse());

    Future.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _isProcessing = false;
      // 清理采集窗口状态。
      _collectionWindowStart = null;
      _candidateEmbeddings.remove(_step);
      setState(() {
        switch (_step) {
          case RegistrationStep.front:
            _step = RegistrationStep.left;
            _stepStartTime = DateTime.now();
            break;
          case RegistrationStep.left:
            _step = RegistrationStep.right;
            _stepStartTime = DateTime.now();
            break;
          case RegistrationStep.right:
            _step = RegistrationStep.complete;
            break;
          default:
            break;
        }
      });
    });
  }

  void _startRegistration() {
    if (!widget.recognitionReady) {
      _toast('身份模型尚未加载完成');
      return;
    }
    setState(() {
      _step = RegistrationStep.front;
      _stepStartTime = DateTime.now();
      _collectedEmbeddings.clear();
      _firstSideSign = 0;
    });
  }

  void _resetRegistration() {
    setState(() {
      _step = RegistrationStep.ready;
      _stepStartTime = null;
      _collectedEmbeddings.clear();
      _isProcessing = false;
      _firstSideSign = 0;
      _collectionWindowStart = null;
      _candidateEmbeddings.clear();
    });
  }

  Future<void> _saveRegistration() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _toast('请输入姓名或昵称');
      return;
    }
    if (_collectedEmbeddings.length < 3) {
      _toast('请先完成面部录入');
      return;
    }

    final frontEmb = _collectedEmbeddings[RegistrationStep.front]!;
    final leftEmb = _collectedEmbeddings[RegistrationStep.left]!;
    final rightEmb = _collectedEmbeddings[RegistrationStep.right]!;
    final avgEmbedding = List<double>.generate(
      frontEmb.length,
      (i) => (frontEmb[i] + leftEmb[i] + rightEmb[i]) / 3,
    );
    // L2归一化：平均后重新归一化到单位球面
    final norm = sqrt(avgEmbedding.fold<double>(0, (s, v) => s + v * v));
    if (norm > 1e-6) {
      for (var i = 0; i < avgEmbedding.length; i++) {
        avgEmbedding[i] /= norm;
      }
    }

    try {
      await widget.store.register(
        name,
        avgEmbedding,
        gender: _gender,
        birthday: _birthday?.toIso8601String(),
        age: _ageController.text.isNotEmpty
            ? int.tryParse(_ageController.text)
            : null,
        relationship: _relationship,
        notes: _notesController.text.trim().isNotEmpty
            ? _notesController.text.trim()
            : null,
      );
      _toast('记住 $name 啦～下次见一定认得你！');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  // ===========================================================================
  // 派生状态
  // ===========================================================================

  /// 采集进度 0..1（三个角度）。
  double get _captureProgress {
    if (_step == RegistrationStep.complete) return 1.0;
    return _collectedEmbeddings.length / 3.0;
  }

  bool get _isScanning =>
      _step == RegistrationStep.front ||
      _step == RegistrationStep.left ||
      _step == RegistrationStep.right;

  bool get _canSave =>
      _step == RegistrationStep.complete &&
      _nameController.text.trim().isNotEmpty;

  String get _instructionTitle {
    switch (_step) {
      case RegistrationStep.ready:
        return '录入面部';
      case RegistrationStep.front:
        if (!_faceDetected) return '请将面部移入圆框';
        if (!_faceInCircle) return '请正对屏幕并靠近一点';
        return '请正视前方，保持不动';
      case RegistrationStep.left:
        return '请缓慢转向一侧';
      case RegistrationStep.right:
        return '请缓慢转向另一侧';
      case RegistrationStep.complete:
        return '面部录入完成';
      case RegistrationStep.failed:
        return '录入超时';
    }
  }

  String get _instructionSubtitle {
    switch (_step) {
      case RegistrationStep.ready:
        return '将面部置于圆框内，跟随提示转动头部即可完成录入';
      case RegistrationStep.front:
      case RegistrationStep.left:
      case RegistrationStep.right:
        return '保持光线充足，动作放缓';
      case RegistrationStep.complete:
        return '在右侧补充资料后即可保存';
      case RegistrationStep.failed:
        return '请确保面部清晰可见，然后重试';
    }
  }

  Color get _ringColor {
    switch (_step) {
      case RegistrationStep.failed:
        return _red;
      case RegistrationStep.complete:
        return _green;
      case RegistrationStep.front:
      case RegistrationStep.left:
      case RegistrationStep.right:
        return _faceInCircle ? _green : _blue;
      case RegistrationStep.ready:
        return _blue;
    }
  }

  // ===========================================================================
  // 构建
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Row(
                children: [
                  Expanded(flex: 5, child: _buildScanPane()),
                  Expanded(flex: 4, child: _buildFormPane()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () => Navigator.pop(context),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.back, color: _blue, size: 22),
                Text('取消', style: TextStyle(color: _blue, fontSize: 17)),
              ],
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                '认识新朋友',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          // 占位，保证标题居中。
          const SizedBox(width: 96),
        ],
      ),
    );
  }

  // ===== 左侧：Face ID 风格扫描区 =====

  Widget _buildScanPane() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 只需保留少量padding，不需要为文字预留空间
        const reserved = 20.0;
        final available = constraints.maxHeight - reserved;
        final circle = max(
          120.0,
          min(
            min(available, constraints.maxWidth * 0.82),
            320.0,
          ),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildFaceCircle(circle),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFaceCircle(double size) {
    final controller = widget.cameraService.controller;
    final ringPadding = 22.0; // 刻度环占用的外圈空间
    final previewSize = size - ringPadding * 2;

    return AnimatedBuilder(
      animation: Listenable.merge([_pulseAnimation, _scanController]),
      builder: (context, _) {
        final scale = _isProcessing ? _pulseAnimation.value : 1.0;
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 进度刻度环（带平滑动画）。
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: _captureProgress),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, progress, child) {
                  return CustomPaint(
                    size: Size(size, size),
                    painter: _FaceIdRingPainter(
                      progress: progress,
                      activeColor: _ringColor,
                      baseColor: _separator,
                      sweep: _isScanning ? _scanController.value : null,
                    ),
                  );
                },
              ),
              // 圆形摄像头取景。
              Transform.scale(
                scale: scale,
                child: ClipOval(
                  child: SizedBox(
                    width: previewSize,
                    height: previewSize,
                    child: _buildPreview(controller, previewSize),
                  ),
                ),
              ),
              // 完成态：对勾覆盖。
              if (_step == RegistrationStep.complete)
                Container(
                  width: previewSize,
                  height: previewSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _green.withValues(alpha: 0.18),
                  ),
                  child: const Icon(CupertinoIcons.checkmark_alt,
                      color: _green, size: 72),
                ),
              // 失败态。
              if (_step == RegistrationStep.failed)
                Container(
                  width: previewSize,
                  height: previewSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _red.withValues(alpha: 0.18),
                  ),
                  child: const Icon(CupertinoIcons.exclamationmark,
                      color: _red, size: 64),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPreview(CameraController? controller, double size) {
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.previewSize == null) {
      return Container(
        color: _card,
        child: const Center(
          child: CupertinoActivityIndicator(color: Colors.white, radius: 14),
        ),
      );
    }
    // 与主预览页保持一致：直接用 previewSize（不交换宽高），由 FittedBox
    // cover 按真实宽高比缩放并裁切，避免画面被拉伸变形。
    return FittedBox(
      fit: BoxFit.cover,
      alignment: Alignment.center,
      child: SizedBox.fromSize(
        size: controller.value.previewSize,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _buildScanAction() {
    switch (_step) {
      case RegistrationStep.ready:
        return _pillButton(
          label: '开始录入',
          color: _blue,
          onPressed: _startRegistration,
        );
      case RegistrationStep.front:
      case RegistrationStep.left:
      case RegistrationStep.right:
        return _buildStepDots();
      case RegistrationStep.complete:
        return _pillButton(
          label: '重新录入',
          color: _cardRow,
          textColor: Colors.white,
          onPressed: _resetRegistration,
        );
      case RegistrationStep.failed:
        return _pillButton(
          label: '重试',
          color: _orange,
          onPressed: _resetRegistration,
        );
    }
  }

  Widget _buildStepDots() {
    Widget dot(RegistrationStep step) {
      final done = _collectedEmbeddings.containsKey(step);
      final active = _step == step;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: active ? 26 : 8,
        height: 8,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: done
              ? _green
              : active
                  ? _blue
                  : _separator,
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        dot(RegistrationStep.front),
        const SizedBox(width: 8),
        dot(RegistrationStep.left),
        const SizedBox(width: 8),
        dot(RegistrationStep.right),
      ],
    );
  }

  Widget _pillButton({
    required String label,
    required Color color,
    required VoidCallback onPressed,
    Color textColor = Colors.white,
  }) {
    return SizedBox(
      height: 40,
      width: 180,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(23),
        color: color,
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ===== 右侧：iOS 分组表单 =====

  Widget _buildFormPane() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: _separator, width: 0.5)),
      ),
      child: Column(
        children: [
          Expanded(
            child: _buildFormContent(),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildFormContent() {
    switch (_step) {
      case RegistrationStep.ready:
        return _buildReadyContent();
      case RegistrationStep.front:
      case RegistrationStep.left:
      case RegistrationStep.right:
        return _buildScanningContent();
      case RegistrationStep.complete:
        return _buildCompleteContent();
      case RegistrationStep.failed:
        return _buildFailedContent();
    }
  }

  Widget _buildBottomBar() {
    // 只有完成步骤才显示底部栏
    switch (_step) {
      case RegistrationStep.ready:
      case RegistrationStep.front:
      case RegistrationStep.left:
      case RegistrationStep.right:
      case RegistrationStep.failed:
        return const SizedBox.shrink();
      case RegistrationStep.complete:
        return _buildCompleteBottomBar();
    }
  }

  // ===== 右侧：动态内容方法 =====

  Widget _buildReadyContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          Text(
            _instructionTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 280,
            child: Text(
              _instructionSubtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _label, fontSize: 15, height: 1.4),
            ),
          ),
          const SizedBox(height: 32),
          _pillButton(
            label: '开始录入',
            color: _blue,
            onPressed: _startRegistration,
          ),
        ],
      ),
    );
  }

  Widget _buildScanningContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          Text(
            _instructionTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 280,
            child: Text(
              _instructionSubtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _label, fontSize: 14, height: 1.4),
            ),
          ),
          const SizedBox(height: 24),
          _buildStepDots(),
          const SizedBox(height: 32),
          _pillButton(
            label: '重新录入',
            color: _cardRow,
            textColor: Colors.white,
            onPressed: _resetRegistration,
          ),
        ],
      ),
    );
  }

  Widget _buildCompleteContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('个人信息'),
          _formCard([
            _textRow(
              label: '姓名',
              controller: _nameController,
              hint: '想让我怎么称呼你',
              onChanged: (_) => setState(() {}),
            ),
            _pickerRow(
              label: '性别',
              value: _gender,
              placeholder: '请选择',
              onTap: _pickGender,
            ),
            _pickerRow(
              label: '生日',
              value: _birthday != null
                  ? '${_birthday!.year}年${_birthday!.month}月${_birthday!.day}日'
                  : null,
              placeholder: '请选择',
              onTap: _pickBirthday,
            ),
            _textRow(
              label: '年龄',
              controller: _ageController,
              hint: '可选',
              keyboardType: TextInputType.number,
            ),
            _pickerRow(
              label: '关系',
              value: _relationship,
              placeholder: '请选择',
              onTap: _pickRelationship,
            ),
          ]),
          const SizedBox(height: 22),
          _sectionHeader('备注 / 喜好'),
          _formCard([
            _textRow(
              label: null,
              controller: _notesController,
              hint: '记录一些关于 TA 的信息…',
              maxLines: 3,
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildFailedContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          Text(
            _instructionTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _red,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 280,
            child: Text(
              _instructionSubtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _label, fontSize: 15, height: 1.4),
            ),
          ),
          const SizedBox(height: 32),
          _pillButton(
            label: '重试',
            color: _orange,
            onPressed: _resetRegistration,
          ),
        ],
      ),
    );
  }

  Widget _buildReadyBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _separator, width: 0.5)),
      ),
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(12),
          color: _cardRow,
          disabledColor: _cardRow,
          onPressed: null,
          child: const Text(
            '请先完成面部录入',
            style: TextStyle(
              color: _label,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanningBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _separator, width: 0.5)),
      ),
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(12),
          color: _cardRow,
          onPressed: _resetRegistration,
          child: const Text(
            '重新录入',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompleteBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _separator, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(12),
                color: _cardRow,
                onPressed: _resetRegistration,
                child: const Text(
                  '重新录入',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 48,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(12),
                color: _blue,
                disabledColor: _cardRow,
                onPressed: _canSave ? _saveRegistration : null,
                child: Text(
                  '保存',
                  style: TextStyle(
                    color: _canSave ? Colors.white : _label,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailedBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _separator, width: 0.5)),
      ),
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(12),
          color: _orange,
          onPressed: _resetRegistration,
          child: const Text(
            '重试',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: _label,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _formCard(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(
          const Padding(
            padding: EdgeInsets.only(left: 16),
            child: Divider(height: 0.5, thickness: 0.5, color: _separator),
          ),
        );
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _textRow({
    required String? label,
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboardType,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            SizedBox(
              width: 64,
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              maxLines: maxLines,
              onChanged: onChanged,
              textAlign: label != null ? TextAlign.right : TextAlign.left,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              cursorColor: _blue,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(color: _label, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickerRow({
    required String label,
    required String? value,
    required String placeholder,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
            const Spacer(),
            Text(
              value ?? placeholder,
              style: TextStyle(
                color: value != null ? Colors.white : _label,
                fontSize: 16,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(CupertinoIcons.right_chevron, color: _label, size: 16),
          ],
        ),
      ),
    );
  }


  // ===========================================================================
  // iOS 选择器
  // ===========================================================================

  Future<void> _pickGender() async {
    final result = await _showActionSheet('选择性别', const ['男', '女', '其他']);
    if (result != null) setState(() => _gender = result);
  }

  Future<void> _pickRelationship() async {
    final result = await _showActionSheet(
        '与我的关系', const ['家人', '朋友', '主人', '伙伴', '同事', '其他']);
    if (result != null) setState(() => _relationship = result);
  }

  Future<String?> _showActionSheet(String title, List<String> options) {
    return showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(title),
        actions: options
            .map((o) => CupertinoActionSheetAction(
                  onPressed: () => Navigator.pop(ctx, o),
                  child: Text(o),
                ))
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Future<void> _pickBirthday() async {
    DateTime temp = _birthday ?? DateTime(2000);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 280,
        color: _card,
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消', style: TextStyle(color: _label)),
                  ),
                  CupertinoButton(
                    onPressed: () {
                      setState(() => _birthday = temp);
                      Navigator.pop(ctx);
                    },
                    child: const Text('完成', style: TextStyle(color: _blue)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CupertinoTheme(
                data: const CupertinoThemeData(brightness: Brightness.dark),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: _birthday ?? DateTime(2000),
                  minimumYear: 1900,
                  maximumDate: DateTime.now(),
                  onDateTimeChanged: (d) => temp = d,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: _cardRow,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// Face ID 风格的放射状刻度进度环。
///
/// 围绕圆周绘制一圈短刻度；已完成进度内的刻度变长、变亮，
/// 未完成的刻度短而灰。扫描时叠加一段「流动高光」营造动态感。
class _FaceIdRingPainter extends CustomPainter {
  _FaceIdRingPainter({
    required this.progress,
    required this.activeColor,
    required this.baseColor,
    this.sweep,
  });

  static const int tickCount = 72;

  /// 0..1 的完成进度。
  final double progress;
  final Color activeColor;
  final Color baseColor;

  /// 0..1 的流动高光相位；为 null 时不绘制高光。
  final double? sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2 - 2;

    const baseLen = 7.0;
    const activeLen = 14.0;

    for (var i = 0; i < tickCount; i++) {
      final t = i / tickCount;
      final angle = -pi / 2 + 2 * pi * t;
      final filled = t <= progress;

      final len = filled ? activeLen : baseLen;
      final inner = outerRadius - len;
      final cosA = cos(angle);
      final sinA = sin(angle);

      final p1 = Offset(center.dx + cosA * inner, center.dy + sinA * inner);
      final p2 =
          Offset(center.dx + cosA * outerRadius, center.dy + sinA * outerRadius);

      var color = filled ? activeColor : baseColor;
      var width = filled ? 3.0 : 2.0;

      // 流动高光：在进度前沿附近加亮一小段。
      if (sweep != null && filled) {
        final dist = (sweep! - t).abs();
        final glow = (1 - (dist * 6)).clamp(0.0, 1.0);
        if (glow > 0) {
          color = Color.lerp(color, Colors.white, glow * 0.6)!;
          width = 3.0 + glow * 1.5;
        }
      }

      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FaceIdRingPainter old) =>
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.sweep != sweep;
}
