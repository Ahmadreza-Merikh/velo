import 'dart:io';

import 'models.dart';

class Settings {
  Settings({
    this.cycles = defaultCycles,
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.concurrency = 0,
    this.connectedConcurrency = 0,
    this.recheckCycles = 1,
    this.useBuiltinSources = true,
    this.tunMode = true,
    this.allowProxyFallback = true,
    this.retireNodeAfterUse = false,
    this.allowInvalidCertificates = false,
    this.maxNodes = 0,
    this.socksPort = 10808,
    this.httpPort = 10809,
    this.testUrl = defaultTestUrl,
  });

  static const int defaultCycles = 20;
  static const double defaultTimeoutSeconds = 10;
  static const String defaultTestUrl = 'http://cp.cloudflare.com/generate_204';

  int cycles;
  double timeoutSeconds;
  int concurrency;
  int connectedConcurrency;
  int recheckCycles;
  bool useBuiltinSources;
  bool tunMode;
  bool allowProxyFallback;
  bool retireNodeAfterUse;
  bool allowInvalidCertificates;
  int maxNodes;
  int socksPort;
  int httpPort;
  String testUrl;

  static int get platformConcurrency {
    if (Platform.isAndroid || Platform.isIOS) {
      return 12;
    }
    return 32;
  }

  static int get platformConnectedConcurrency {
    if (Platform.isAndroid || Platform.isIOS) {
      return 4;
    }
    return 8;
  }

  int get effectiveConcurrency {
    if (concurrency > 0) {
      return concurrency;
    }
    return platformConcurrency;
  }

  int concurrencyFor(TestRegime regime) {
    if (regime == TestRegime.idle) {
      return effectiveConcurrency;
    }
    if (connectedConcurrency > 0) {
      return connectedConcurrency;
    }
    final int idle = effectiveConcurrency;
    final int connected = platformConnectedConcurrency;
    return connected < idle ? connected : idle;
  }

  Duration get timeout =>
      Duration(milliseconds: (timeoutSeconds * 1000).round());

  Settings copy() {
    return Settings(
      cycles: cycles,
      timeoutSeconds: timeoutSeconds,
      concurrency: concurrency,
      connectedConcurrency: connectedConcurrency,
      recheckCycles: recheckCycles,
      useBuiltinSources: useBuiltinSources,
      tunMode: tunMode,
      allowProxyFallback: allowProxyFallback,
      retireNodeAfterUse: retireNodeAfterUse,
      allowInvalidCertificates: allowInvalidCertificates,
      maxNodes: maxNodes,
      socksPort: socksPort,
      httpPort: httpPort,
      testUrl: testUrl,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'cycles': cycles,
      'timeoutSeconds': timeoutSeconds,
      'concurrency': concurrency,
      'connectedConcurrency': connectedConcurrency,
      'recheckCycles': recheckCycles,
      'useBuiltinSources': useBuiltinSources,
      'tunMode': tunMode,
      'allowProxyFallback': allowProxyFallback,
      'retireNodeAfterUse': retireNodeAfterUse,
      'allowInvalidCertificates': allowInvalidCertificates,
      'maxNodes': maxNodes,
      'socksPort': socksPort,
      'httpPort': httpPort,
      'testUrl': testUrl,
    };
  }

  static Settings fromJson(Map<String, dynamic> json) {
    final Settings settings = Settings();
    settings.cycles = _clampInt(json['cycles'], settings.cycles, 1, 500);
    settings.timeoutSeconds = _clampDouble(
      json['timeoutSeconds'],
      settings.timeoutSeconds,
      1,
      120,
    );
    settings.concurrency = _clampInt(json['concurrency'], 0, 0, 256);
    settings.connectedConcurrency =
        _clampInt(json['connectedConcurrency'], 0, 0, 256);
    settings.recheckCycles = _clampInt(json['recheckCycles'], 1, 1, 50);
    settings.useBuiltinSources =
        (json['useBuiltinSources'] as bool?) ?? settings.useBuiltinSources;
    settings.tunMode = (json['tunMode'] as bool?) ?? settings.tunMode;
    settings.allowProxyFallback =
        (json['allowProxyFallback'] as bool?) ?? settings.allowProxyFallback;
    settings.retireNodeAfterUse =
        (json['retireNodeAfterUse'] as bool?) ?? settings.retireNodeAfterUse;
    settings.allowInvalidCertificates =
        (json['allowInvalidCertificates'] as bool?) ??
            settings.allowInvalidCertificates;
    settings.maxNodes = _clampInt(json['maxNodes'], 0, 0, 100000);
    settings.socksPort = _clampInt(json['socksPort'], 10808, 1024, 65535);
    settings.httpPort = _clampInt(json['httpPort'], 10809, 1024, 65535);
    final Object? url = json['testUrl'];
    if (url is String && url.startsWith('http')) {
      settings.testUrl = url;
    }
    return settings;
  }

  static int _clampInt(Object? value, int fallback, int min, int max) {
    final int parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? fallback;
    if (parsed < min) {
      return min;
    }
    if (parsed > max) {
      return max;
    }
    return parsed;
  }

  static double _clampDouble(
    Object? value,
    double fallback,
    double min,
    double max,
  ) {
    final double parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? fallback;
    if (parsed < min) {
      return min;
    }
    if (parsed > max) {
      return max;
    }
    return parsed;
  }
}
