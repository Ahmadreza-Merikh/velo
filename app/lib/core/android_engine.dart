import 'dart:convert';

import 'package:flutter/services.dart';

import 'engine.dart';
import 'link_parser.dart';
import 'models.dart';
import 'settings.dart';

class AndroidEngine implements VeloEngine {
  static const MethodChannel _channel = MethodChannel('velo/engine');
  static const int _probePortBase = 28000;
  static const int _probePortSpan = 10000;

  bool _prepared = false;
  int _probeCounter = 0;

  int _nextProbePort() {
    _probeCounter = (_probeCounter + 1) % _probePortSpan;
    return _probePortBase + _probeCounter;
  }

  @override
  Future<void> prepare({void Function(String message)? onStatus}) async {
    if (_prepared) {
      return;
    }
    onStatus?.call('starting proxy core');
    await _channel.invokeMethod<void>('prepareCore');
    _prepared = true;
  }

  Future<bool> requestVpnPermission() async {
    final bool? granted =
        await _channel.invokeMethod<bool>('requestVpnPermission');
    return granted ?? false;
  }

  Future<String> coreVersion() async {
    final String? version = await _channel.invokeMethod<String>('coreVersion');
    return version ?? '';
  }

  @override
  Future<bool> get isActive async {
    final bool? active = await _channel.invokeMethod<bool>('isActive');
    return active ?? false;
  }

  @override
  Future<List<TestOutcome>> testCycle(
    List<Node> nodes, {
    required Settings settings,
    required CancelFlag cancel,
    void Function(TestOutcome outcome, int done, int total)? onEach,
  }) async {
    await prepare();

    final List<TestOutcome> outcomes = <TestOutcome>[];
    int done = 0;

    await runPool<Node>(
      nodes,
      settings.effectiveConcurrency,
      (Node node) async {
        TestOutcome outcome;
        if (cancel.cancelled) {
          outcome = TestOutcome(node: node, ok: false, error: 'cancelled');
        } else {
          outcome = await _measure(node, settings);
        }
        outcomes.add(outcome);
        done += 1;
        onEach?.call(outcome, done, nodes.length);
      },
      cancel: cancel,
    );

    return outcomes;
  }

  Future<TestOutcome> _measure(Node node, Settings settings) async {
    final ParsedLink parsed = parseLink(node.uri);
    final Map<String, dynamic>? outbound = parsed.outbound;
    if (outbound == null) {
      return TestOutcome(
        node: node,
        ok: false,
        error: parsed.error.isEmpty ? 'unsupported link' : parsed.error,
      );
    }

    try {
      final int? delay = await _channel.invokeMethod<int>(
        'measure',
        <String, dynamic>{
          'config': jsonEncode(probeConfig(outbound, _nextProbePort())),
          'url': settings.testUrl,
          'timeoutMs': settings.timeout.inMilliseconds,
        },
      );
      if (delay == null || delay <= 0) {
        return TestOutcome(node: node, ok: false, error: 'no response');
      }
      return TestOutcome(node: node, ok: true, pingMs: delay.toDouble());
    } on PlatformException catch (error) {
      return TestOutcome(
        node: node,
        ok: false,
        error: error.message ?? 'measure failed',
      );
    } catch (_) {
      return TestOutcome(node: node, ok: false, error: 'measure failed');
    }
  }

  @override
  Future<ConnectReport> connect({
    required Node node,
    required Map<String, dynamic> outbound,
    required Settings settings,
  }) async {
    await prepare();

    final bool granted = await requestVpnPermission();
    if (!granted) {
      throw EngineFailure('vpn permission was not granted');
    }

    final String config = jsonEncode(
      androidTunnelConfig(outbound, socksPort: settings.socksPort),
    );

    try {
      final bool? started = await _channel.invokeMethod<bool>(
        'start',
        <String, dynamic>{
          'config': config,
          'label': node.label,
        },
      );
      if (started != true) {
        throw EngineFailure('the tunnel did not start');
      }
    } on PlatformException catch (error) {
      throw EngineFailure(error.message ?? 'the tunnel did not start');
    }

    return ConnectReport(mode: TunnelMode.tun, node: node);
  }

  @override
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (_) {
      return;
    }
  }

  @override
  Future<void> shutdown() async {
    await disconnect();
  }
}
