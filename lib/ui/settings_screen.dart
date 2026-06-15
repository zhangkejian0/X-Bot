import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../camera/camera_controller_service.dart';
import '../detection/models.dart';
import '../recognition/face_recognition_store.dart';
import 'face_registration_screen.dart';

/// 设置页面（iOS 风格）：人脸识别、摄像头、检测、界面等设置。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.currentFrame,
    required this.recognitionReady,
    required this.recognitionError,
    required this.cameraService,
  });

  final FaceRecognitionStore store;
  final DetectionFrame currentFrame;
  final bool recognitionReady;
  final String recognitionError;
  final CameraControllerService cameraService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ===== iOS 调色板 =====
  static const _bg = Color(0xFF000000);
  static const _card = Color(0xFF1C1C1E);
  static const _separator = Color(0xFF38383A);
  static const _label = Color(0xFF8E8E93);
  static const _blue = Color(0xFF0A84FF);
  static const _green = Color(0xFF30D158);
  static const _orange = Color(0xFFFF9F0A);
  static const _purple = Color(0xFFBF5AF2);
  static const _gray = Color(0xFF8E8E93);
  static const _red = Color(0xFFFF453A);
  static const _teal = Color(0xFF64D2FF);

  // 检测设置状态。
  bool _showOverlay = true;
  bool _showSkeleton = true;
  double _detectionConfidence = 0.5;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    children: [
                      _section('人脸识别', _faceRecognitionRows()),
                      const SizedBox(height: 22),
                      _section('摄像头', _cameraRows()),
                      const SizedBox(height: 22),
                      _section('检测', _detectionRows()),
                      const SizedBox(height: 22),
                      _section('界面', _interfaceRows()),
                    ],
                  ),
                ),
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
                Text('返回', style: TextStyle(color: _blue, fontSize: 17)),
              ],
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                '设置',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 96),
        ],
      ),
    );
  }

  // ===========================================================================
  // 各分组
  // ===========================================================================

  List<Widget> _faceRecognitionRows() {
    final faces = widget.store.faces;
    return [
      _navRow(
        icon: CupertinoIcons.person_crop_circle,
        iconColor: _blue,
        title: '认识我',
        value: widget.recognitionReady ? null : '模型加载中',
        onTap: widget.recognitionReady ? _registerFace : null,
      ),
      if (faces.isNotEmpty)
        _navRow(
          icon: CupertinoIcons.person_2_fill,
          iconColor: _green,
          title: '我的朋友',
          value: '${faces.length} 位',
          onTap: _showFriendsList,
        ),
    ];
  }

  List<Widget> _cameraRows() {
    return [
      _navRow(
        icon: CupertinoIcons.switch_camera,
        iconColor: _orange,
        title: '切换摄像头',
        value: '前置',
        onTap: () => _toast('摄像头切换功能开发中'),
      ),
      _navRow(
        icon: CupertinoIcons.wand_stars,
        iconColor: _purple,
        title: '分辨率',
        value: '720p',
        onTap: () => _toast('分辨率设置功能开发中'),
      ),
    ];
  }

  List<Widget> _detectionRows() {
    return [
      _switchRow(
        icon: CupertinoIcons.square_stack_3d_up,
        iconColor: _teal,
        title: '显示检测叠加层',
        value: _showOverlay,
        onChanged: (v) => setState(() => _showOverlay = v),
      ),
      _switchRow(
        icon: CupertinoIcons.person_crop_rectangle,
        iconColor: _green,
        title: '显示骨架',
        value: _showSkeleton,
        onChanged: (v) => setState(() => _showSkeleton = v),
      ),
      _sliderRow(
        icon: CupertinoIcons.slider_horizontal_3,
        iconColor: _blue,
        title: '检测灵敏度',
        value: _detectionConfidence,
        onChanged: (v) => setState(() => _detectionConfidence = v),
      ),
    ];
  }

  List<Widget> _interfaceRows() {
    return [
      _navRow(
        icon: CupertinoIcons.globe,
        iconColor: _blue,
        title: '语言',
        value: '中文',
        onTap: () => _toast('语言切换功能开发中'),
      ),
      _navRow(
        icon: CupertinoIcons.info_circle,
        iconColor: _gray,
        title: '关于',
        value: 'v1.0.0',
        onTap: _showAbout,
      ),
    ];
  }

  // ===========================================================================
  // iOS 风格通用组件
  // ===========================================================================

  Widget _section(String title, List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(const Padding(
          padding: EdgeInsets.only(left: 56),
          child: Divider(height: 0.5, thickness: 0.5, color: _separator),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: _label,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _iconBadge(IconData icon, Color color) {
    return Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    );
  }

  Widget _navRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? value,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            _iconBadge(icon, iconColor),
            const SizedBox(width: 13),
            Text(
              title,
              style: TextStyle(
                color: enabled ? Colors.white : _label,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            if (value != null)
              Text(value, style: const TextStyle(color: _label, fontSize: 16)),
            const SizedBox(width: 6),
            const Icon(CupertinoIcons.right_chevron, color: _label, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          _iconBadge(icon, iconColor),
          const SizedBox(width: 13),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
          const Spacer(),
          CupertinoSwitch(
            value: value,
            activeTrackColor: _green,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _sliderRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          _iconBadge(icon, iconColor),
          const SizedBox(width: 13),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
          const SizedBox(width: 12),
          Expanded(
            child: CupertinoSlider(
              value: value,
              min: 0.1,
              max: 0.9,
              divisions: 8,
              activeColor: _blue,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              value.toStringAsFixed(1),
              textAlign: TextAlign.right,
              style: const TextStyle(color: _label, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 业务逻辑
  // ===========================================================================

  /// 人脸录入流程 - 跳转到人脸录入页面。
  Future<void> _registerFace() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => FaceRegistrationScreen(
          cameraService: widget.cameraService,
          store: widget.store,
          recognitionReady: widget.recognitionReady,
        ),
      ),
    );
    if (result == true) setState(() {});
  }

  /// 显示已录入的朋友列表（iOS 底部弹层）。
  void _showFriendsList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final faces = widget.store.faces;
            return Container(
              margin: const EdgeInsets.all(10),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部抓手。
                  Container(
                    width: 36,
                    height: 5,
                    margin: const EdgeInsets.only(top: 8, bottom: 4),
                    decoration: BoxDecoration(
                      color: _separator,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '我的朋友',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text('${faces.length} 位',
                            style: const TextStyle(color: _label, fontSize: 14)),
                      ],
                    ),
                  ),
                  const Divider(height: 0.5, thickness: 0.5, color: _separator),
                  Flexible(
                    child: faces.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: Text('还没有认识的朋友',
                                style: TextStyle(color: _label, fontSize: 15)),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: faces.length,
                            separatorBuilder: (context, index) => const Padding(
                              padding: EdgeInsets.only(left: 70),
                              child: Divider(
                                  height: 0.5,
                                  thickness: 0.5,
                                  color: _separator),
                            ),
                            itemBuilder: (ctx, index) {
                              final face = faces[index];
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 8),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 20,
                                      backgroundColor: _blue,
                                      child: Text(
                                        face.name.isNotEmpty
                                            ? face.name[0]
                                            : '?',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(face.name,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16)),
                                          if (face.relationship != null)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 2),
                                              child: Text(
                                                face.relationship!,
                                                style: const TextStyle(
                                                    color: _label,
                                                    fontSize: 12),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    CupertinoButton(
                                      padding: EdgeInsets.zero,
                                      onPressed: () async {
                                        await _deleteFriend(
                                            face.id, face.name);
                                        setSheetState(() {});
                                      },
                                      child: const Icon(
                                        CupertinoIcons.delete,
                                        color: _red,
                                        size: 22,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  SizedBox(height: MediaQuery.of(ctx).padding.bottom + 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 删除朋友（iOS 确认弹窗）。
  Future<void> _deleteFriend(String id, String name) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要忘记 $name 吗？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('忘记'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.store.remove(id);
      if (mounted) setState(() {});
      _toast('已经忘记 $name 了');
    }
  }

  void _showAbout() {
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('X-Bot'),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('版本 1.0.0\n© 2024 X-Bot Team'),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2C2C2E),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
