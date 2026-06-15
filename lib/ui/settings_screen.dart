import 'package:flutter/material.dart';
import '../camera/camera_controller_service.dart';
import '../detection/models.dart';
import '../recognition/face_recognition_store.dart';
import '../recognition/face_recognizer.dart';
import 'face_registration_screen.dart';

/// 设置页面：包含人脸识别、摄像头、检测、语言等设置。
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
  // 检测设置状态。
  bool _showOverlay = true;
  bool _showSkeleton = true;
  double _detectionConfidence = 0.5;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        children: [
          // 人脸识别设置。
          _buildSectionHeader('人脸识别'),
          _buildFaceRecognitionSection(),
          
          const Divider(color: Colors.grey, height: 1),
          
          // 摄像头设置。
          _buildSectionHeader('摄像头'),
          _buildCameraSection(),
          
          const Divider(color: Colors.grey, height: 1),
          
          // 检测设置。
          _buildSectionHeader('检测'),
          _buildDetectionSection(),
          
          const Divider(color: Colors.grey, height: 1),
          
          // 界面设置。
          _buildSectionHeader('界面'),
          _buildInterfaceSection(),
          
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.tealAccent,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildFaceRecognitionSection() {
    final faces = widget.store.faces;
    return Column(
      children: [
        // 认识我（人脸录入）。
        ListTile(
          leading: const Icon(Icons.face, color: Colors.white),
          title: const Text('认识我', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            widget.recognitionReady ? '让 AI 记住你的样子' : '模型加载中...',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: widget.recognitionReady ? _registerFace : null,
        ),
        
        // 我的朋友（已录入人脸列表）。
        if (faces.isNotEmpty) ...[
          const Divider(color: Colors.grey, height: 1, indent: 56),
          ListTile(
            leading: const Icon(Icons.people, color: Colors.white),
            title: const Text('我的朋友', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              '已认识 ${faces.length} 位朋友',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: _showFriendsList,
          ),
        ],
      ],
    );
  }

  Widget _buildCameraSection() {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.cameraswitch, color: Colors.white),
          title: const Text('切换摄像头', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            '当前：前置摄像头',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('摄像头切换功能开发中...')),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.high_quality, color: Colors.white),
          title: const Text('分辨率', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            '当前：720p',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('分辨率设置功能开发中...')),
            );
          },
        ),
      ],
    );
  }

  Widget _buildDetectionSection() {
    return Column(
      children: [
        // 显示检测叠加层。
        SwitchListTile(
          secondary: const Icon(Icons.layers, color: Colors.white),
          title: const Text('显示检测叠加层', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            '在画面上显示检测结果',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          value: _showOverlay,
          activeColor: Colors.tealAccent,
          onChanged: (value) {
            setState(() => _showOverlay = value);
          },
        ),
        
        // 显示骨架。
        SwitchListTile(
          secondary: const Icon(Icons.accessibility, color: Colors.white),
          title: const Text('显示骨架', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            '显示手势和姿势骨架',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          value: _showSkeleton,
          activeColor: Colors.tealAccent,
          onChanged: (value) {
            setState(() => _showSkeleton = value);
          },
        ),
        
        // 检测灵敏度。
        ListTile(
          leading: const Icon(Icons.tune, color: Colors.white),
          title: const Text('检测灵敏度', style: TextStyle(color: Colors.white)),
          subtitle: Slider(
            value: _detectionConfidence,
            min: 0.1,
            max: 0.9,
            divisions: 8,
            activeColor: Colors.tealAccent,
            inactiveColor: Colors.grey[700],
            onChanged: (value) {
              setState(() => _detectionConfidence = value);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildInterfaceSection() {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.language, color: Colors.white),
          title: const Text('语言', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            '当前：中文',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('语言切换功能开发中...')),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.info_outline, color: Colors.white),
          title: const Text('关于', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            'X-Bot v1.0.0',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () {
            showAboutDialog(
              context: context,
              applicationName: 'X-Bot',
              applicationVersion: '1.0.0',
              applicationLegalese: '© 2024 X-Bot Team',
            );
          },
        ),
      ],
    );
  }

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

    // 如果录入成功，刷新列表。
    if (result == true) {
      setState(() {});
    }
  }

  /// 弹出姓名输入对话框。
  Future<String?> _promptName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('想让我怎么称呼你？'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '你的名字或昵称',
          ),
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

  /// 显示已录入的朋友列表。
  void _showFriendsList() {
    final faces = widget.store.faces;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏。
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '我的朋友',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${faces.length} 位',
                  style: TextStyle(color: Colors.grey[400], fontSize: 14),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.grey, height: 1),
          
          // 朋友列表。
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: faces.length,
              itemBuilder: (ctx, index) {
                final face = faces[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.tealAccent,
                    child: Text(
                      face.name.isNotEmpty ? face.name[0] : '?',
                      style: const TextStyle(color: Colors.black),
                    ),
                  ),
                  title: Text(face.name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    'ID: ${face.id}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deleteFriend(face.id, face.name),
                  ),
                );
              },
            ),
          ),
          
          // 底部安全区域。
          SizedBox(height: MediaQuery.of(ctx).padding.bottom),
        ],
      ),
    );
  }

  /// 删除朋友。
  Future<void> _deleteFriend(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要忘记 $name 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('忘记'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.store.remove(id);
      _showSnackBar('已经忘记 $name 了');
      setState(() {}); // 刷新列表。
      if (mounted) Navigator.pop(context); // 关闭底部弹窗。
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
