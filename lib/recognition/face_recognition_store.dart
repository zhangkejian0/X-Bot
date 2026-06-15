import 'dart:convert';
import 'dart:io';

/// 一个已注册的人脸身份。
class RegisteredFace {
  RegisteredFace({required this.id, required this.name, required this.embedding});

  /// 唯一 ID（时间戳生成的简单 ID）。
  final String id;
  final String name;

  /// 128 维特征向量。
  final List<double> embedding;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'embedding': embedding};

  factory RegisteredFace.fromJson(Map<String, dynamic> json) => RegisteredFace(
        id: json['id'] as String,
        name: json['name'] as String,
        embedding: (json['embedding'] as List<dynamic>)
            .map((e) => (e as num).toDouble())
            .toList(growable: false),
      );
}

/// 本地 JSON 持久化的人脸注册库。
///
/// 文件位置：{applicationDocumentsDirectory}/face_db.json。
/// 第一版只支持单设备本地识别；后续可扩展为多 embedding 融合/云端同步。
class FaceRecognitionStore {
  FaceRecognitionStore(this._file);

  final File _file;
  final List<RegisteredFace> _faces = [];

  List<RegisteredFace> get faces => List.unmodifiable(_faces);

  /// 从磁盘加载。文件不存在时创建空库。
  Future<void> load() async {
    if (!_file.existsSync()) {
      _faces.clear();
      return;
    }
    try {
      final raw = await _file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      _faces
        ..clear()
        ..addAll(list
            .whereType<Map<String, dynamic>>()
            .map(RegisteredFace.fromJson));
    } catch (_) {
      _faces.clear();
    }
  }

  /// 注册一个新身份，返回生成的记录。
  Future<RegisteredFace> register(String name, List<double> embedding) async {
    final face = RegisteredFace(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      embedding: embedding,
    );
    _faces.add(face);
    await _persist();
    return face;
  }

  /// 按 ID 删除。
  Future<void> remove(String id) async {
    _faces.removeWhere((f) => f.id == id);
    await _persist();
  }

  /// 清空。
  Future<void> clear() async {
    _faces.clear();
    await _persist();
  }

  Future<void> _persist() async {
    final list = _faces.map((f) => f.toJson()).toList();
    await _file.writeAsString(jsonEncode(list));
  }
}
