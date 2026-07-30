import 'dart:io';

class SystemProxy {
  static const String _registryKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static Future<bool> enable({
    required int socksPort,
    required int httpPort,
  }) async {
    if (Platform.isWindows) {
      return _enableWindows(httpPort);
    }
    if (Platform.isMacOS) {
      return _enableMac(socksPort: socksPort, httpPort: httpPort);
    }
    return false;
  }

  static Future<void> disable() async {
    if (Platform.isWindows) {
      await _disableWindows();
      return;
    }
    if (Platform.isMacOS) {
      await _disableMac();
    }
  }

  static Future<bool> _enableWindows(int httpPort) async {
    final ProcessResult server = await Process.run('reg', <String>[
      'add',
      _registryKey,
      '/v',
      'ProxyServer',
      '/t',
      'REG_SZ',
      '/d',
      '127.0.0.1:$httpPort',
      '/f',
    ]);
    final ProcessResult enable = await Process.run('reg', <String>[
      'add',
      _registryKey,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/d',
      '1',
      '/f',
    ]);
    await Process.run('reg', <String>[
      'add',
      _registryKey,
      '/v',
      'ProxyOverride',
      '/t',
      'REG_SZ',
      '/d',
      '<local>',
      '/f',
    ]);
    return server.exitCode == 0 && enable.exitCode == 0;
  }

  static Future<void> _disableWindows() async {
    await Process.run('reg', <String>[
      'add',
      _registryKey,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/d',
      '0',
      '/f',
    ]);
  }

  static Future<List<String>> _macNetworkServices() async {
    final ProcessResult result = await Process.run(
      'networksetup',
      <String>['-listallnetworkservices'],
    );
    if (result.exitCode != 0) {
      return <String>[];
    }
    final List<String> services = <String>[];
    final List<String> lines = (result.stdout as String).split('\n');
    for (int i = 1; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (line.isEmpty || line.startsWith('*')) {
        continue;
      }
      services.add(line);
    }
    return services;
  }

  static Future<bool> _enableMac({
    required int socksPort,
    required int httpPort,
  }) async {
    final List<String> services = await _macNetworkServices();
    bool any = false;
    for (final String service in services) {
      final ProcessResult socks = await Process.run('networksetup', <String>[
        '-setsocksfirewallproxy',
        service,
        '127.0.0.1',
        '$socksPort',
      ]);
      final ProcessResult web = await Process.run('networksetup', <String>[
        '-setwebproxy',
        service,
        '127.0.0.1',
        '$httpPort',
      ]);
      final ProcessResult secure = await Process.run('networksetup', <String>[
        '-setsecurewebproxy',
        service,
        '127.0.0.1',
        '$httpPort',
      ]);
      if (socks.exitCode == 0 || web.exitCode == 0 || secure.exitCode == 0) {
        any = true;
      }
    }
    return any;
  }

  static Future<void> _disableMac() async {
    final List<String> services = await _macNetworkServices();
    for (final String service in services) {
      await Process.run(
        'networksetup',
        <String>['-setsocksfirewallproxystate', service, 'off'],
      );
      await Process.run(
        'networksetup',
        <String>['-setwebproxystate', service, 'off'],
      );
      await Process.run(
        'networksetup',
        <String>['-setsecurewebproxystate', service, 'off'],
      );
    }
  }
}
