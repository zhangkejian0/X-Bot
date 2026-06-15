import 'package:flutter/material.dart';

/// 加载页：全屏背景 + 居中 logo + 进度条 + 分阶段状态文字。
///
/// 设计为类似游戏加载的体验：摄像头、检测模型、身份模型逐项初始化，
/// 每完成一项推进进度条，全部就绪后淡出，进入摄像头画面。
///
/// 背景图可替换：将图片放到 assets/images/loading_background.png 并在
/// pubspec.yaml 声明，[backgroundImageAsset] 设为该路径即可。
class LoadingScreen extends StatefulWidget {
  const LoadingScreen({
    super.key,
    required this.tasks,
    this.backgroundImageAsset,
    this.onComplete,
  });

  /// 有序的加载任务列表。每个任务完成后推进进度条。
  final List<LoadingTask> tasks;

  /// 可选：背景图资源路径（如 'assets/images/loading_background.png'）。
  /// 为 null 时使用程序化生成的渐变背景。
  final String? backgroundImageAsset;

  /// 所有任务完成后的回调。
  final VoidCallback? onComplete;

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _progressController;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  int _currentIndex = 0;
  String _currentLabel = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.value = 1.0;
    _runTasks();
  }

  @override
  void dispose() {
    _progressController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _runTasks() async {
    final total = widget.tasks.length;
    for (var i = 0; i < total; i++) {
      if (!mounted) return;
      setState(() {
        _currentIndex = i;
        _currentLabel = widget.tasks[i].label;
      });
      try {
        await widget.tasks[i].action();
      } catch (e) {
        setState(() => _error = '$e');
        // 出错不中断，继续下一个任务（保证 App 能进主界面）。
      }
      // 推进进度条到 (i+1)/total。
      final target = (i + 1) / total;
      _progressController.animateTo(target);
      // 最后一个任务完成后短暂停留再淡出。
      if (i == total - 1) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        await _fadeController.reverse();
      }
    }
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) {
        return Opacity(opacity: _fadeAnimation.value, child: child);
      },
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景层：可替换的图片 或 程序化渐变背景。
          _buildBackground(),
          // 前景层：logo + 进度条 + 状态文字。
          _buildForeground(context),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    if (widget.backgroundImageAsset != null) {
      return Image.asset(
        widget.backgroundImageAsset!,
        fit: BoxFit.cover,
        errorBuilder: (_, e, _) => _buildGradientBackground(),
      );
    }
    return _buildGradientBackground();
  }

  /// 程序化科技感渐变背景（深色 + 径向光晕）。
  Widget _buildGradientBackground() {
    return CustomPaint(
      painter: _LoadingBackgroundPainter(),
      size: Size.infinite,
    );
  }

  Widget _buildForeground(BuildContext context) {
    final progress =
        (_currentIndex + (_progressController.value)) / widget.tasks.length;
    final clampedProgress = progress.clamp(0.0, 1.0);
    return SafeArea(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 3),
          // Logo / 标题。
          _buildLogo(),
          const SizedBox(height: 48),
          // 进度条。
          _buildProgressBar(clampedProgress),
          const SizedBox(height: 16),
          // 状态文字。
          _buildStatusText(),
          const Spacer(flex: 2),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Logo 图片（圆角 + 发光阴影）。
        Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF64FFDA).withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Image.asset(
              'assets/images/logo.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'X-Bot',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '实时视觉识别',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.6),
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar(double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.15),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF64FFDA)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusText() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _currentLabel,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white70,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: TextStyle(
              fontSize: 11,
              color: Colors.red.withValues(alpha: 0.7),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// 一个加载任务：标签 + 执行动作。
class LoadingTask {
  const LoadingTask({required this.label, required this.action});

  /// 显示给用户的状态文字（如"初始化摄像头..."）。
  final String label;

  /// 实际执行的异步操作。
  final Future<void> Function() action;
}

/// 加载页程序化背景：深色渐变 + 径向光晕 + 网格线。
class _LoadingBackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 深色基底渐变。
    final basePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: const [
          Color(0xFF0A1A1F),
          Color(0xFF001215),
          Color(0xFF000000),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, basePaint);

    // 径向光晕（中心偏上）。
    final center = Offset(size.width * 0.5, size.height * 0.35);
    final glowRect = Rect.fromCenter(
      center: center,
      width: size.width,
      height: size.width,
    );
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF00897B).withValues(alpha: 0.25),
          const Color(0xFF00897B).withValues(alpha: 0.0),
        ],
      ).createShader(glowRect);
    canvas.drawRect(rect, glowPaint);

    // 科技感网格线。
    final gridPaint = Paint()
      ..color = const Color(0xFF64FFDA).withValues(alpha: 0.04)
      ..strokeWidth = 1;
    const step = 40.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
