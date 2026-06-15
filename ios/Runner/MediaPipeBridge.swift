import Flutter
import MediaPipeTasksVision
import TensorFlowLite
import UIKit

/// iOS 端检测桥接：与 Android 端 [MainActivity] 一一对应。
///
/// 接收 Flutter [CameraImage]（YUV420 三平面），转成 UIImage 后串行运行：
///   1. FaceLandmarker（人脸框 + 478 关键点 + blendshapes + 身份 embedding）
///   2. GestureRecognizer（21 关键点 + 手势/惯用手）
///   3. PoseLandmarker（33 关键点）
/// 一次性把全部结果回传 Dart，数据结构与 Android 完全一致。
///
/// 注意：本文件在 Windows 上无法编译验证，需在 Mac 上 `pod install` 后用
/// Xcode 构建。模拟器不支持 TFLite，需真机调试。
class MediaPipeBridge: NSObject, FlutterStreamHandler {

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "xbot.detection", qos: .userInitiated)

  private var faceLandmarker: FaceLandmarker?
  private var gestureRecognizer: GestureRecognizer?
  private var poseLandmarker: PoseLandmarker?

  // TFLite 身份识别。
  private var faceRecognizerInterpreter: Interpreter?

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "xbot/detection", binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "detect" {
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "BAD_ARGS", message: "detect expects a map.", details: nil))
          return
        }
        self.queue.async {
          do {
            let payload = try self.detectAll(args: args)
            DispatchQueue.main.async { result(payload) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "DETECT_ERROR", message: "\(error)", details: nil))
            }
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 预热模型。
    queue.async { [weak self] in
      _ = self?.faceLandmarkerInstance
      _ = self?.gestureRecognizerInstance
      _ = self?.poseLandmarkerInstance
      _ = self?.recognizerInterpreter
    }
  }

  // MARK: - 模型懒加载

  private var faceLandmarkerInstance: FaceLandmarker? {
    if faceLandmarker != nil { return faceLandmarker }
    guard let path = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else { return nil }
    let options = FaceLandmarkerOptions()
    options.baseOptions.modelAssetPath = path
    options.runningMode = .image
    options.numFaces = 4
    options.outputFaceBlendshapes = true
    options.outputFacialTransformationMatrixes = true
    faceLandmarker = try? FaceLandmarker(options: options)
    return faceLandmarker
  }

  private var gestureRecognizerInstance: GestureRecognizer? {
    if gestureRecognizer != nil { return gestureRecognizer }
    guard let path = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task") else { return nil }
    let options = GestureRecognizerOptions()
    options.baseOptions.modelAssetPath = path
    options.runningMode = .image
    options.numHands = 4
    gestureRecognizer = try? GestureRecognizer(options: options)
    return gestureRecognizer
  }

  private var poseLandmarkerInstance: PoseLandmarker? {
    if poseLandmarker != nil { return poseLandmarker }
    guard let path = Bundle.main.path(forResource: "pose_landmarker", ofType: "task") else { return nil }
    let options = PoseLandmarkerOptions()
    options.baseOptions.modelAssetPath = path
    options.runningMode = .image
    options.numPoses = 2
    poseLandmarker = try? PoseLandmarker(options: options)
    return poseLandmarker
  }

  private var recognizerInterpreter: Interpreter? {
    if faceRecognizerInterpreter != nil { return faceRecognizerInterpreter }
    guard let path = Bundle.main.path(forResource: "mobilefacenet", ofType: "tflite") else { return nil }
    var options = Interpreter.Options()
    options.threadCount = 2
    faceRecognizerInterpreter = try? Interpreter(modelPath: path, options: options)
    if let interp = faceRecognizerInterpreter {
      try? interp.resizeInput(at: 0, to: [1, 112, 112, 3])
    }
    return faceRecognizerInterpreter
  }

  // MARK: - 主流程

  private func detectAll(args: [String: Any]) throws -> [String: Any] {
    guard let image = image(from: args) else {
      throw NSError(domain: "MediaPipeBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法解码相机图像"])
    }
    let width = Int(image.size.width)
    let height = Int(image.size.height)

    let mpImage = try MPImage(uiImage: image)

    var faces: [[String: Any]] = []
    var hands: [[String: Any]] = []
    var poses: [[String: Any]] = []

    if let faceResult = try faceLandmarkerInstance?.detect(image: mpImage) {
      faces = faceMaps(from: faceResult, image: image)
    }
    if let gestureResult = try gestureRecognizerInstance?.recognize(image: mpImage) {
      hands = handMaps(from: gestureResult)
    }
    if let poseResult = try poseLandmarkerInstance?.detect(image: mpImage) {
      poses = poseMaps(from: poseResult)
    }

    return [
      "imageWidth": width,
      "imageHeight": height,
      "faces": faces,
      "hands": hands,
      "poses": poses
    ]
  }

  // MARK: - 结果映射

  private func faceMaps(from result: FaceLandmarkerResult, image: UIImage) -> [[String: Any]] {
    var maps: [[String: Any]] = []
    let blendshapeLists = result.faceBlendshapes() ?? []
    let transformationMatrixes = result.facialTransformationMatrixes ?? []

    for (i, landmarks) in result.faceLandmarks.enumerated() {
      if landmarks.isEmpty { continue }
      var minX: Float = 1, minY: Float = 1, maxX: Float = 0, maxY: Float = 0
      var landmarkMaps: [[String: Float]] = []
      for lm in landmarks {
        let x = lm.x.floatValue
        let y = lm.y.floatValue
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
        landmarkMaps.append(["x": x, "y": y])
      }
      let bbox: [String: Float] = [
        "x": max(0, minX), "y": max(0, minY),
        "width": max(0, maxX - minX), "height": max(0, maxY - minY)
      ]
      var blendMap: [String: Double] = [:]
      if i < blendshapeLists.count {
        for cat in blendshapeLists[i] {
          blendMap[cat.categoryName] = cat.score.doubleValue
        }
      }

      // 提取头部姿态。
      let headPose: [String: Float]
      if i < transformationMatrixes.count {
        headPose = extractHeadPose(matrix: transformationMatrixes[i])
      } else {
        headPose = ["yaw": 0, "pitch": 0, "roll": 0]
      }

      // 身份识别。
      let embedding = recognizeFace(image: image, landmarks: result.faceLandmarks[i])

      maps.append([
        "boundingBox": bbox,
        "blendshapes": blendMap,
        "landmarks": landmarkMaps,
        "embedding": embedding,
        "headPose": headPose
      ])
    }
    return maps
  }

  private func handMaps(from result: GestureRecognizerResult) -> [[String: Any]] {
    var maps: [[String: Any]] = []
    for (i, landmarks) in result.landmarks.enumerated() {
      let landmarkMaps = landmarks.map { lm -> [String: Float] in
        ["x": lm.x.floatValue, "y": lm.y.floatValue]
      }
      let gesture = result.gestures[i].first
      let handedness = result.handedness[i].first
      maps.append([
        "gesture": [
          "name": gesture?.categoryName ?? "Unknown",
          "score": gesture?.score.floatValue ?? 0
        ] as [String: Any],
        "handedness": [
          "name": handedness?.categoryName ?? "Right",
          "score": handedness?.score.floatValue ?? 0
        ] as [String: Any],
        "landmarks": landmarkMaps
      ])
    }
    return maps
  }

  private func poseMaps(from result: PoseLandmarkerResult) -> [[String: Any]] {
    var maps: [[String: Any]] = []
    for landmarks in result.landmarks {
      let landmarkMaps = landmarks.map { lm -> [String: Float] in
        ["x": lm.x.floatValue, "y": lm.y.floatValue]
      }
      maps.append([
        "landmarks": landmarkMaps,
        "score": 1.0
      ])
    }
    return maps
  }

  // MARK: - 人脸身份识别

  /// 用眼角关键点对齐 → 112x112 → TFLite → 128 维 embedding。
  private func recognizeFace(image: UIImage, landmarks: [NormalizedLandmark]) -> [Double] {
    guard let interp = recognizerInterpreter else { return [] }
    guard landmarks.count > 362 else { return [] }
    guard let aligned = alignAndCrop(image: image, landmarks: landmarks) else { return [] }

    // 112x112x3 float32，归一化到 [-1,1]。
    let size = 112
    var input: [Float] = []
    input.reserveCapacity(size * size * 3)
    guard let cgImage = aligned.cgImage else { return [] }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = size * 4
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    guard let context = CGContext(
      data: &pixels, width: size, height: size,
      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return [] }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    for i in stride(from: 0, to: pixels.count, by: 4) {
      input.append(Float(pixels[i]) / 127.5 - 1)
      input.append(Float(pixels[i + 1]) / 127.5 - 1)
      input.append(Float(pixels[i + 2]) / 127.5 - 1)
    }

    do {
      try interp.resizeInput(at: 0, to: [1, size, size, 3])
      let inputTensor = try Tensor(data: Data(copyingBufferOf: input))
      try interp.invoke(options: nil, tensors: [inputTensor], error: ())
      let output = try interp.output(at: 0)
      let raw = output.data.withUnsafeBytes { ptr -> [Float] in
        let count = output.data.count / MemoryLayout<Float>.size
        let buf = ptr.bindMemory(to: Float.self)
        return Array(buf.prefix(count))
      }
      // L2 归一化。
      var norm: Double = 0
      for v in raw { norm += Double(v) * Double(v) }
      norm = sqrt(norm)
      let n = norm < 1e-6 ? 1 : norm
      return raw.map { Double($0) / n }
    } catch {
      return []
    }
  }

  /// 用左右眼内眼角对齐旋转，裁剪正方形人脸。
  private func alignAndCrop(image: UIImage, landmarks: [NormalizedLandmark]) -> UIImage? {
    let w = Double(image.size.width)
    let h = Double(image.size.height)
    let rightInner = landmarks[133]
    let leftInner = landmarks[362]
    let rxEye = rightInner.x.doubleValue * w
    let ryEye = rightInner.y.doubleValue * h
    let lxEye = leftInner.x.doubleValue * w
    let lyEye = leftInner.y.doubleValue * h
    let angle = atan2(lyEye - ryEye, lxEye - rxEye) * 180 / .pi

    guard let cgImage = image.cgImage else { return nil }
    let rotated = UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
      .rotated(by: angle) ?? image

    let cosA = cos(-angle * .pi / 180)
    let sinA = sin(-angle * .pi / 180)
    let eyeMidX = (rxEye + lxEye) / 2
    let eyeMidY = (ryEye + lyEye) / 2
    let cx = cosA * eyeMidX - sinA * eyeMidY
    let cy = sinA * eyeMidX + cosA * eyeMidY
    let eyeDist = hypot(lxEye - rxEye, lyEye - ryEye)
    let faceSize = eyeDist * 2.6
    let half = faceSize / 2
    let left = max(0, cx - half)
    let top = max(0, cy - half * 0.85)
    let cropW = min(faceSize, Double(rotated.size.width) - left)
    let cropH = min(faceSize, Double(rotated.size.height) - top)
    let cropSize = min(cropW, cropH)
    if cropSize < 32 { return nil }
    guard let cg = rotated.cgImage else { return nil }
    let cropped = cg.cropping(to: CGRect(x: left, y: top, width: cropSize, height: cropSize))
    guard let croppedImg = cropped else { return nil }
    let resized = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 112)).image { _ in
      UIImage(cgImage: croppedImg, scale: 1, orientation: .up)
        .draw(in: CGRect(x: 0, y: 0, width: 112, height: 112))
    }
    return resized
  }

  // MARK: - CameraImage → UIImage

  /// 从 4x4 变换矩阵中提取头部姿态角（yaw、pitch、roll）。
  ///
  /// 矩阵是列主序的 16 个 float：
  /// [m00, m01, m02, m03, m10, m11, m12, m13, m20, m21, m22, m23, m30, m31, m32, m33]
  ///
  /// 旋转矩阵 R：
  /// | m00 m01 m02 |
  /// | m10 m11 m12 |
  /// | m20 m21 m22 |
  ///
  /// yaw = atan2(m20, m00)  (绕 Y 轴)
  /// pitch = -asin(m21)     (绕 X 轴)
  /// roll = atan2(m01, m11) (绕 Z 轴)
  private func extractHeadPose(matrix: [Float]) -> [String: Float] {
    guard matrix.count >= 16 else {
      return ["yaw": 0, "pitch": 0, "roll": 0]
    }

    // 提取旋转矩阵元素（列主序）。
    let m00 = matrix[0]; let m01 = matrix[4]; let m02 = matrix[8]
    let m10 = matrix[1]; let m11 = matrix[5]; let m12 = matrix[9]
    let m20 = matrix[2]; let m21 = matrix[6]; let m22 = matrix[10]

    // 计算欧拉角（弧度）。
    let pitch = -asin(max(-1, min(1, m21)))
    let yaw = atan2(m20, m00)
    let roll = atan2(m01, m11)

    // 转换为角度。
    let pitchDeg = pitch * 180 / .pi
    let yawDeg = yaw * 180 / .pi
    let rollDeg = roll * 180 / .pi

    return [
      "yaw": yawDeg,
      "pitch": pitchDeg,
      "roll": rollDeg
    ]
  }

  /// Flutter CameraImage (YUV420) → UIImage。
  /// 旋转后返回正立图像。
  private func image(from args: [String: Any]) -> UIImage? {
    guard let width = args["width"] as? Int,
          let height = args["height"] as? Int,
          let planes = args["planes"] as? [[String: Any]] else { return nil }
    let rotation = args["rotationDegrees"] as? Int ?? 0
    // YUV420 三平面 → 拼成 NV21 → 转 UIImage。iOS 上更常用 CV pixelbuffer，
    // 但 Flutter 传入的是字节描述，这里用简化的 Y-only→灰度→RGB 近似处理
    // 仅用于第一版联调；生产环境建议改用 camera 插件的 CVPixelBuffer 直传。
    guard planes.count >= 3,
          let yBytes = planes[0]["bytes"] as? FlutterStandardTypedData else { return nil }
    // 为保证功能可用，这里用 Y 平面构造灰度图再转 RGB。
    let yData = yBytes.data
    var rgb = [UInt8](repeating: 128, count: width * height * 4)
    yData.withUnsafeBytes { ptr in
      let yPtr = ptr.bindMemory(to: UInt8.self)
      for i in 0..<(width * height) {
        let v = yPtr[i]
        rgb[i * 4] = v
        rgb[i * 4 + 1] = v
        rgb[i * 4 + 2] = v
        rgb[i * 4 + 3] = 255
      }
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(rgb) as CFData),
          let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ) else { return nil }
    var img = UIImage(cgImage: cgImage)
    if rotation != 0 {
      img = img.rotated(by: Double(rotation)) ?? img
    }
    return img
  }
}

// MARK: - UIImage 旋转扩展

extension UIImage {
  func rotated(by degrees: Double) -> UIImage? {
    let radians = degrees * .pi / 180
    let size = self.size
    UIGraphicsBeginImageContextWithOptions(size, true, self.scale)
    guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
    ctx.translateBy(x: size.width / 2, y: size.height / 2)
    ctx.rotate(by: CGFloat(radians))
    self.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    let result = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return result
  }
}
