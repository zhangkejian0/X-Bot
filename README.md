# X-Bot

AI 陪伴桌面机器人（Android / iOS）。

基于 Flutter + MediaPipe，为机器人赋予实时视觉感知能力。

## 功能

- **强制横屏** 全屏摄像头预览
- **人脸检测** — MediaPipe FaceLandmarker（478 关键点 + 52 ARKit Blendshapes）
- **表情识别** — 基于 ARKit Blendshape 规则引擎，识别 7 种表情（中性/快乐/悲伤/惊讶/愤怒/恐惧/厌恶）
- **手势识别** — MediaPipe GestureRecognizer（21 关键点 + 7 种手势 + 惯用手）
- **姿势识别** — MediaPipe PoseLandmarker（33 关键点）
- **人脸身份识别** — MobileFaceNet (TFLite) 128 维 embedding 对齐 + 欧氏距离比对
- **实时叠加层** — 人脸框/手势骨架/姿势连线 + 调试数值面板
- **游戏式加载页** — 分阶段加载进度 + 可替换背景图与 logo
- **屏幕常亮** — 运行期间保持屏幕不熄灭

## 技术架构

| 任务 | 引擎 | 模型 |
|---|---|---|
| 人脸检测+表情 | MediaPipe FaceLandmarker | `face_landmarker.task` |
| 手势识别 | MediaPipe GestureRecognizer | `gesture_recognizer.task` |
| 姿势识别 | MediaPipe PoseLandmarker | `pose_landmarker.task` |
| 身份识别 | TFLite MobileFaceNet | `mobilefacenet.tflite` |

所有 AI 推理在原生端（Android Kotlin / iOS Swift）运行，通过 `MethodChannel('xbot/detection')` 与 Flutter 通信，避免跨平台 FFI 问题。

## 项目结构

```
lib/
├── main.dart                       # 入口 + 强制横屏
├── ui/
│   ├── camera_screen.dart          # 主屏幕：加载页 → 摄像头 + 叠加层
│   ├── loading_screen.dart         # 游戏式加载页
│   ├── overlay_painter.dart        # 检测结果叠加层绘制
│   └── debug_panel.dart            # 调试数值面板
├── camera/
│   └── camera_controller_service.dart
├── detection/
│   ├── models.dart                 # 检测结果数据模型
│   ├── detection_bridge.dart       # MethodChannel 封装
│   └── expression_rules.dart       # 7 表情规则引擎
├── recognition/
│   ├── face_recognition_store.dart # 注册库 (JSON 持久化)
│   └── face_recognizer.dart        # embedding 比对
└── utils/
    └── coordinate_mapper.dart      # 横屏坐标映射

android/app/src/main/kotlin/com/xbot/xbot/
├── MainActivity.kt                 # 通道入口
├── BitmapUtil.kt                   # YUV420 → Bitmap
├── MediaPipeDetector.kt            # 三任务封装
└── FaceRecognizer.kt               # TFLite 身份推理

ios/Runner/
├── AppDelegate.swift
└── MediaPipeBridge.swift           # iOS 端三任务 + TFLite
```

## 运行

### Android

```bash
flutter pub get
flutter run                    # 连接真机，需授权相机权限
```

### iOS（需 Mac）

```bash
cd ios && pod install && cd ..
flutter run                    # 需真机（模拟器不支持 TFLite）
```

## 替换加载页背景与 logo

- Logo: 替换 `assets/images/logo.png`
- 背景: 取消 `lib/ui/loading_screen.dart` 中 `backgroundImageAsset` 的注释，并放入图片到 `assets/images/`

## 依赖

- Flutter 3.41+ / Dart 3.11+
- MediaPipe Tasks Vision 0.10.14
- TensorFlow Lite 2.16.1
