class Node {
  Node({
    required this.uri,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    this.pingMs = 0,
    this.samples = 0,
    this.lastError = '',
    this.used = false,
  });

  final String uri;
  final String name;
  final String protocol;
  final String server;
  final int port;

  double pingMs;
  int samples;
  String lastError;
  bool used;

  String get label {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return '$server:$port';
    }
    return trimmed;
  }

  String get shortLabel {
    final String value = label;
    if (value.length <= 28) {
      return value;
    }
    return '${value.substring(0, 27)}...';
  }

  void recordPing(double value) {
    if (samples <= 0) {
      pingMs = value;
      samples = 1;
    } else {
      pingMs = ((pingMs * samples) + value) / (samples + 1);
      samples += 1;
    }
    lastError = '';
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'uri': uri,
      'name': name,
      'protocol': protocol,
      'server': server,
      'port': port,
      'pingMs': pingMs,
      'samples': samples,
      'used': used,
    };
  }

  static Node? fromJson(Map<String, dynamic> json) {
    final Object? uri = json['uri'];
    if (uri is! String || uri.isEmpty) {
      return null;
    }
    return Node(
      uri: uri,
      name: (json['name'] as String?) ?? '',
      protocol: (json['protocol'] as String?) ?? '',
      server: (json['server'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      pingMs: (json['pingMs'] as num?)?.toDouble() ?? 0,
      samples: (json['samples'] as num?)?.toInt() ?? 0,
      used: (json['used'] as bool?) ?? false,
    );
  }
}

class TestOutcome {
  TestOutcome({
    required this.node,
    required this.ok,
    this.pingMs = 0,
    this.error = '',
  });

  final Node node;
  final bool ok;
  final double pingMs;
  final String error;
}

enum ConnectPhase {
  idle,
  fetching,
  testing,
  connecting,
  connected,
  disconnecting,
  error,
}

enum TunnelMode { tun, proxy }
