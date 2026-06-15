import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 必须强引用，否则 MediaPipeBridge 初始化后会被释放，MethodChannel 回调里
  /// weak self 为 nil 且不会调用 result，Dart 端 invokeMethod 将永久挂起。
  private var mediaPipeBridge: MediaPipeBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 允许横屏左右旋转（180°），与 Info.plist / Dart SystemChrome 保持一致。
  override func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    return [.landscapeLeft, .landscapeRight]
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Scene 架构下通过 applicationRegistrar 获取 messenger（勿强转 FlutterEngine）。
    let messenger = engineBridge.applicationRegistrar.messenger()
    mediaPipeBridge = MediaPipeBridge(binaryMessenger: messenger)
  }
}
