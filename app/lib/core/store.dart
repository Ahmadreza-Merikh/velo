import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'settings.dart';

class Store {
  Store._(this._root);

  final Directory _root;

  static Store? _instance;

  static Future<Store> open() async {
    final Store? existing = _instance;
    if (existing != null) {
      return existing;
    }
    final Directory support = await getApplicationSupportDirectory();
    final Directory root = Directory('${support.path}${Platform.pathSeparator}velo');
    if (!root.existsSync()) {
      root.createSync(recursive: true);
    }
    final Store store = Store._(root);
    _instance = store;
    return store;
  }

  Directory get root => _root;

  Directory get workDir {
    final Directory dir =
        Directory('${_root.path}${Platform.pathSeparator}run');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  File _file(String name) =>
      File('${_root.path}${Platform.pathSeparator}$name');

  Future<Settings> loadSettings() async {
    final Map<String, dynamic>? json = await _readJson('settings.json');
    if (json == null) {
      return Settings();
    }
    return Settings.fromJson(json);
  }

  Future<void> saveSettings(Settings settings) async {
    await _writeJson('settings.json', settings.toJson());
  }

  Future<List<String>> loadUserSources() async {
    final Map<String, dynamic>? json = await _readJson('sources.json');
    if (json == null) {
      return <String>[];
    }
    final Object? list = json['sources'];
    if (list is! List) {
      return <String>[];
    }
    final List<String> out = <String>[];
    for (final Object? item in list) {
      if (item is String && item.trim().isNotEmpty) {
        out.add(item.trim());
      }
    }
    return out;
  }

  Future<void> saveUserSources(List<String> sources) async {
    await _writeJson('sources.json', <String, dynamic>{'sources': sources});
  }

  Future<PoolSnapshot> loadPool() async {
    final Map<String, dynamic>? json = await _readJson('pool.json');
    if (json == null) {
      return PoolSnapshot(nodes: <Node>[], builtAt: null, generation: 0);
    }
    final Object? list = json['nodes'];
    final List<Node> nodes = <Node>[];
    if (list is List) {
      for (final Object? item in list) {
        if (item is Map) {
          final Node? node = Node.fromJson(item.cast<String, dynamic>());
          if (node != null) {
            nodes.add(node);
          }
        }
      }
    }
    DateTime? builtAt;
    final Object? stamp = json['builtAt'];
    if (stamp is String) {
      builtAt = DateTime.tryParse(stamp);
    }
    return PoolSnapshot(
      nodes: nodes,
      builtAt: builtAt,
      generation: (json['generation'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> savePool(PoolSnapshot snapshot) async {
    await _writeJson('pool.json', <String, dynamic>{
      'nodes': snapshot.nodes.map((Node node) => node.toJson()).toList(),
      'builtAt': snapshot.builtAt?.toIso8601String(),
      'generation': snapshot.generation,
    });
  }

  Future<Map<String, dynamic>?> _readJson(String name) async {
    try {
      final File file = _file(name);
      if (!file.existsSync()) {
        return null;
      }
      final String text = await file.readAsString();
      if (text.trim().isEmpty) {
        return null;
      }
      final Object? decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(String name, Map<String, dynamic> data) async {
    try {
      final File temp = _file('$name.tmp');
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename(_file(name).path);
    } catch (_) {
      return;
    }
  }
}

class PoolSnapshot {
  PoolSnapshot({
    required this.nodes,
    required this.builtAt,
    required this.generation,
  });

  final List<Node> nodes;
  final DateTime? builtAt;
  final int generation;
}
