import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 注册检测通道。scene-based 架构下，engine 由 FlutterSceneDelegate 持有，
    // 此处获取 binaryMessenger 并交给 MediaPipeBridge。
    guard let engine = engineBridge.pluginRegistry as? FlutterEngine else { return }
    let _ = MediaPipeBridge(binaryMessenger: engine.binaryMessenger)
  }
}
