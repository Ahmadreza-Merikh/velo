import 'dart:convert';
import 'dart:io';

import 'engine.dart';
import 'link_parser.dart';
import 'models.dart';
import 'privileged_helper.dart';
import 'settings.dart';
import 'store.dart';
import 'system_proxy.dart';
import 'xray_binary.dart';

class DesktopEngine implements VeloEngine {
  DesktopEngine(this._store);

  final Store _store;

  File? _core;
  Process? _tunnel;
  TunnelMode _mode = TunnelMode.proxy;
  bool _helperTunnelRunning = false;
  bool _proxyApplied = false;

  @override
  Future<void> prepare({void Function(String message)? onStatus}) async {
    _core ??= await XrayBinary.ensure(_store.root, onStatus: onStatus);
  }

  File get _coreOrThrow {
    final File? core = _core;
    if (core == null) {
      throw EngineFailure('proxy core is not ready yet');
    }
    return core;
  }

  @override
  Future<bool> get isActive async =>
      _tunnel != null || _helperTunnelRunning;

  @override
  Future<List<TestOutcome>> testCycle(
    List<Node> nodes, {
    required Settings settings,
    required CancelFlag cancel,
    void Function(TestOutcome outcome, int done, int total)? onEach,
  }) async {
    await prepare();

    final List<TestOutcome> outcomes = <TestOutcome>[];
    final Directory work = _store.workDir;
    int done = 0;

    await runPool<Node>(
      nodes,
      settings.effectiveConcurrency,
      (Node node) async {
        final TestOutcome outcome = cancel.cancelled
            ? TestOutcome(node: node, ok: false, error: 'cancelled')
            : await _probeNode(node, settings, work);
        outcomes.add(outcome);
        done += 1;
        onEach?.call(outcome, done, nodes.length);
      },
      cancel: cancel,
    );

    return outcomes;
  }

  Future<TestOutcome> _probeNode(
    Node node,
    Settings settings,
    Directory work,
  ) async {
    final ParsedLink parsed = parseLink(node.uri);
    final Map<String, dynamic>? outbound = parsed.outbound;
    if (outbound == null) {
      return TestOutcome(
        node: node,
        ok: false,
        error: parsed.error.isEmpty ? 'unsupported link' : parsed.error,
      );
    }

    Process? process;
    File? configFile;
    try {
      final int port = await _freePort();
      configFile = File(
        '${work.path}${Platform.pathSeparator}probe_$port.json',
      );
      await configFile.writeAsString(jsonEncode(probeConfig(outbound, port)));

      process = await _spawnCore(configFile);

      final bool up = await _waitForPort(port, const Duration(seconds: 3));
      if (!up) {
        return TestOutcome(node: node, ok: false, error: 'core did not start');
      }

      final double? latency = await _measure(port, settings);
      if (latency == null) {
        return TestOutcome(node: node, ok: false, error: 'no response');
      }
      return TestOutcome(node: node, ok: true, pingMs: latency);
    } catch (error) {
      return TestOutcome(node: node, ok: false, error: _short(error));
    } finally {
      process?.kill(ProcessSignal.sigkill);
      if (configFile != null && configFile.existsSync()) {
        try {
          configFile.deleteSync();
        } catch (_) {
          _ignore();
        }
      }
    }
  }

  Future<double?> _measure(int port, Settings settings) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = settings.timeout
      ..idleTimeout = const Duration(seconds: 1)
      ..findProxy = (Uri uri) => 'PROXY 127.0.0.1:$port';
    final Stopwatch watch = Stopwatch()..start();
    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse(settings.testUrl))
          .timeout(settings.timeout);
      request.followRedirects = false;
      final HttpClientResponse response =
          await request.close().timeout(settings.timeout);
      await response.drain<void>().timeout(settings.timeout);
      watch.stop();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return watch.elapsedMicroseconds / 1000.0;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<ConnectReport> connect({
    required Node node,
    required Map<String, dynamic> outbound,
    required Settings settings,
  }) async {
    await prepare();
    await disconnect();

    final File core = _coreOrThrow;
    final Directory work = _store.workDir;
    final File config = File(
      '${work.path}${Platform.pathSeparator}tunnel.json',
    );

    if (settings.tunMode) {
      final String tunName = Platform.isMacOS
          ? await _freeTunName()
          : WindowsHelper.adapterName;
      await config.writeAsString(
        jsonEncode(
          tunnelConfig(
            outbound,
            tun: true,
            socksPort: settings.socksPort,
            httpPort: settings.httpPort,
            tunName: tunName,
          ),
        ),
      );

      final List<String> servers = await _resolveServers(outbound);
      final PrivilegedHelper? helper = PrivilegedHelper.forPlatform();
      if (helper != null) {
        String failure = '';
        if (!await helper.isInstalled()) {
          final HelperResult installed = await helper.install(
            xray: core,
            config: config,
            workDir: work,
          );
          failure = installed.ok ? '' : installed.message;
        }
        if (failure.isEmpty) {
          final HelperResult started = await helper.start(
            config: config,
            tunName: tunName,
            serverAddresses: servers,
          );
          if (started.ok) {
            _helperTunnelRunning = true;
            _mode = TunnelMode.tun;
            final bool alive = await _verifyTunnel(settings);
            if (alive) {
              return ConnectReport(mode: TunnelMode.tun, node: node);
            }
            await helper.stop();
            _helperTunnelRunning = false;
            failure = 'tunnel came up but carried no traffic';
          } else {
            failure = started.message;
          }
        }

        if (!settings.allowProxyFallback) {
          throw EngineFailure(
            failure.isEmpty ? 'could not start the tunnel' : failure,
          );
        }
        return _connectProxy(
          node: node,
          outbound: outbound,
          settings: settings,
          note: failure,
        );
      }
    }

    return _connectProxy(
      node: node,
      outbound: outbound,
      settings: settings,
      note: '',
    );
  }

  Future<ConnectReport> _connectProxy({
    required Node node,
    required Map<String, dynamic> outbound,
    required Settings settings,
    required String note,
  }) async {
    final Directory work = _store.workDir;
    final File config = File(
      '${work.path}${Platform.pathSeparator}proxy.json',
    );
    await config.writeAsString(
      jsonEncode(
        tunnelConfig(
          outbound,
          tun: false,
          socksPort: settings.socksPort,
          httpPort: settings.httpPort,
        ),
      ),
    );

    final Process process = await _spawnCore(config);
    _tunnel = process;
    _mode = TunnelMode.proxy;

    final bool up = await _waitForPort(
      settings.httpPort,
      const Duration(seconds: 5),
    );
    if (!up) {
      await disconnect();
      throw EngineFailure('local proxy did not start');
    }

    _proxyApplied = await SystemProxy.enable(
      socksPort: settings.socksPort,
      httpPort: settings.httpPort,
    );

    final String message = _proxyApplied
        ? note
        : 'set your proxy to 127.0.0.1:${settings.httpPort} manually';

    return ConnectReport(
      mode: TunnelMode.proxy,
      node: node,
      note: message,
    );
  }

  Future<bool> _verifyTunnel(Settings settings) async {
    final bool up = await _waitForPort(
      settings.httpPort,
      const Duration(seconds: 6),
    );
    if (!up) {
      return false;
    }
    final double? latency = await _measure(settings.httpPort, settings);
    return latency != null;
  }

  @override
  Future<void> disconnect() async {
    if (_proxyApplied) {
      await SystemProxy.disable();
      _proxyApplied = false;
    }

    final Process? process = _tunnel;
    if (process != null) {
      process.kill(ProcessSignal.sigkill);
      _tunnel = null;
    }

    if (_helperTunnelRunning) {
      final PrivilegedHelper? helper = PrivilegedHelper.forPlatform();
      if (helper != null) {
        await helper.stop();
      }
      _helperTunnelRunning = false;
    }
  }

  @override
  Future<void> shutdown() async {
    await disconnect();
  }

  TunnelMode get mode => _mode;

  Future<bool> helperInstalled() async {
    final PrivilegedHelper? helper = PrivilegedHelper.forPlatform();
    if (helper == null) {
      return false;
    }
    return helper.isInstalled();
  }

  Future<HelperResult> removeHelper() async {
    final PrivilegedHelper? helper = PrivilegedHelper.forPlatform();
    if (helper == null) {
      return HelperResult(ok: false, message: 'not supported here');
    }
    return helper.uninstall();
  }

  static Future<String> _freeTunName() async {
    final Set<String> used = <String>{};
    try {
      final ProcessResult result = await Process.run('ifconfig', <String>['-l']);
      if (result.exitCode == 0) {
        for (final String name
            in (result.stdout as String).trim().split(RegExp(r'\s+'))) {
          if (name.isNotEmpty) {
            used.add(name);
          }
        }
      }
    } catch (_) {
      _ignore();
    }
    for (int index = 10; index < 250; index++) {
      final String candidate = 'utun$index';
      if (!used.contains(candidate)) {
        return candidate;
      }
    }
    return 'utun240';
  }

  static Future<List<String>> _resolveServers(
    Map<String, dynamic> outbound,
  ) async {
    final List<String> hosts = <String>[];
    final Object? settings = outbound['settings'];
    if (settings is Map) {
      for (final String key in <String>['vnext', 'servers']) {
        final Object? list = settings[key];
        if (list is List) {
          for (final Object? entry in list) {
            if (entry is Map) {
              final Object? address = entry['address'];
              if (address is String && address.isNotEmpty) {
                hosts.add(address);
              }
            }
          }
        }
      }
    }

    final List<String> resolved = <String>[];
    for (final String host in hosts) {
      final InternetAddress? literal = InternetAddress.tryParse(host);
      if (literal != null) {
        if (!resolved.contains(literal.address)) {
          resolved.add(literal.address);
        }
        continue;
      }
      try {
        final List<InternetAddress> found = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 5));
        for (final InternetAddress item in found) {
          if (!resolved.contains(item.address)) {
            resolved.add(item.address);
          }
        }
      } catch (_) {
        _ignore();
      }
    }
    return resolved;
  }

  Future<Process> _spawnCore(File config) async {
    final Process process = await Process.start(
      _coreOrThrow.path,
      <String>['run', '-c', config.path],
      workingDirectory: _coreOrThrow.parent.path,
    );
    process.stdout.drain<void>().catchError((Object _) {});
    process.stderr.drain<void>().catchError((Object _) {});
    return process;
  }

  static Future<int> _freePort() async {
    final ServerSocket socket =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int port = socket.port;
    await socket.close();
    return port;
  }

  static Future<bool> _waitForPort(int port, Duration limit) async {
    final DateTime deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final Socket socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 400),
        );
        socket.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
    return false;
  }

  static String _short(Object error) {
    final String text = error.toString();
    if (text.length <= 80) {
      return text;
    }
    return '${text.substring(0, 80)}...';
  }

  static void _ignore() {}
}
