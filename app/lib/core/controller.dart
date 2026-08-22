import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android_engine.dart';
import 'desktop_engine.dart';
import 'engine.dart';
import 'link_parser.dart';
import 'models.dart';
import 'privileged_helper.dart';
import 'settings.dart';
import 'sources.dart';
import 'store.dart';
import 'subscription.dart';

class VeloController extends ChangeNotifier {
  Store? _store;
  VeloEngine? _engine;

  Settings settings = Settings();
  List<String> userSources = <String>[];
  List<Node> pool = <Node>[];

  ConnectPhase phase = ConnectPhase.idle;
  TunnelMode mode = TunnelMode.tun;
  Node? activeNode;
  String status = 'Ready';
  String note = '';
  String warning = '';
  String failure = '';

  int cycle = 0;
  int cycleTotal = 0;
  int tested = 0;
  int testTotal = 0;
  int alive = 0;
  int generation = 0;
  DateTime? poolBuiltAt;

  final CancelFlag _cancel = CancelFlag();
  bool _busy = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get busy => _busy;

  bool get connected => phase == ConnectPhase.connected;

  bool get working =>
      phase == ConnectPhase.fetching ||
      phase == ConnectPhase.testing ||
      phase == ConnectPhase.connecting;

  int get poolSize => pool.length;

  int get freshPoolSize => pool.where((Node node) => !node.used).length;

  int get sourceCount => userSources.length + (settings.useBuiltinSources ? builtinSourceCount() : 0);

  double get progress {
    if (phase == ConnectPhase.testing && testTotal > 0 && cycleTotal > 0) {
      final double inCycle = tested / testTotal;
      return _fraction(((cycle - 1) + inCycle) / cycleTotal);
    }
    if (phase == ConnectPhase.fetching && testTotal > 0) {
      return _fraction(tested / testTotal);
    }
    return 0;
  }

  static double _fraction(double value) {
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  Node? get bestNode {
    final List<Node> sorted = _sortedPool();
    if (sorted.isEmpty) {
      return null;
    }
    return sorted.first;
  }

  Future<void> init() async {
    final Store store = await Store.open();
    _store = store;
    settings = await store.loadSettings();
    userSources = await store.loadUserSources();
    final PoolSnapshot snapshot = await store.loadPool();
    pool = snapshot.nodes;
    poolBuiltAt = snapshot.builtAt;
    generation = snapshot.generation;
    _engine = Platform.isAndroid ? AndroidEngine() : DesktopEngine(store);
    status = pool.isEmpty
        ? 'Ready. First connect will scan for nodes.'
        : 'Ready. ${pool.length} nodes in the pool.';
    notifyListeners();

    final bool active = await _engine!.isActive;
    if (active) {
      await _engine!.disconnect();
    }
  }

  Future<bool> helperInstalled() async {
    final VeloEngine? engine = _engine;
    if (engine is DesktopEngine) {
      return engine.helperInstalled();
    }
    return false;
  }

  Future<bool> removeHelper() async {
    final VeloEngine? engine = _engine;
    if (engine is DesktopEngine) {
      if (connected) {
        await disconnect();
      }
      final HelperResult result = await engine.removeHelper();
      return result.ok;
    }
    return false;
  }

  Future<void> saveSettings(Settings updated) async {
    settings = updated;
    await _store?.saveSettings(updated);
    notifyListeners();
  }

  Future<void> addSource(String raw) async {
    final List<String> parts = splitSourceList(raw);
    bool changed = false;
    for (final String part in parts) {
      if (!userSources.contains(part)) {
        userSources.add(part);
        changed = true;
      }
    }
    if (changed) {
      await _store?.saveUserSources(userSources);
      notifyListeners();
    }
  }

  Future<void> removeSource(String url) async {
    if (userSources.remove(url)) {
      await _store?.saveUserSources(userSources);
      notifyListeners();
    }
  }

  void cancel() {
    _cancel.cancel();
    status = 'Stopping';
    notifyListeners();
  }

  Future<void> toggle() async {
    if (_busy) {
      cancel();
      return;
    }
    if (connected) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> connect() async {
    final VeloEngine? engine = _engine;
    if (engine == null || _busy) {
      return;
    }

    _busy = true;
    _cancel.reset();
    failure = '';
    note = '';
    warning = '';

    try {
      _setPhase(ConnectPhase.fetching, 'Preparing');
      await engine.prepare(onStatus: (String message) {
        status = message;
        notifyListeners();
      });

      if (pool.isEmpty) {
        await _fullScan(engine);
      } else {
        await _recheck(engine);
        if (_candidates().isEmpty && !_cancel.cancelled) {
          status = 'Pool is empty, scanning again';
          notifyListeners();
          await _resetPool();
          await _fullScan(engine);
        }
      }

      if (_cancel.cancelled) {
        _setPhase(ConnectPhase.idle, 'Stopped');
        return;
      }

      final List<Node> candidates = _candidates();
      if (candidates.isEmpty) {
        failure = 'No working node was found.';
        _setPhase(ConnectPhase.error, failure);
        return;
      }

      await _connectBest(engine, candidates);
    } on EngineFailure catch (error) {
      failure = error.message;
      _setPhase(ConnectPhase.error, failure);
    } catch (error) {
      failure = error.toString();
      _setPhase(ConnectPhase.error, 'Could not connect');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _connectBest(VeloEngine engine, List<Node> candidates) async {
    _setPhase(ConnectPhase.connecting, 'Connecting');

    final int attempts = candidates.length < 3 ? candidates.length : 3;
    for (int i = 0; i < attempts; i++) {
      final Node candidate = candidates[i];
      final ParsedLink parsed = parseLink(candidate.uri);
      final Map<String, dynamic>? outbound = parsed.outbound;
      if (outbound == null) {
        pool.remove(candidate);
        continue;
      }

      status = 'Connecting to ${candidate.shortLabel}';
      notifyListeners();

      try {
        final ConnectReport report = await engine.connect(
          node: candidate,
          outbound: outbound,
          settings: settings,
        );
        activeNode = candidate;
        mode = report.mode;
        note = report.note;
        warning = <String>[warning, report.warning]
            .where((String item) => item.isNotEmpty)
            .join(' - ');
        if (settings.retireNodeAfterUse) {
          candidate.used = true;
        }
        await _savePool();
        _setPhase(
          ConnectPhase.connected,
          '${candidate.shortLabel} at ${candidate.pingMs.round()} ms',
        );
        return;
      } on EngineFailure catch (error) {
        failure = error.message;
        pool.remove(candidate);
        await _savePool();
      }
    }

    _setPhase(
      ConnectPhase.error,
      failure.isEmpty ? 'Could not connect' : failure,
    );
  }

  Future<void> disconnect() async {
    final VeloEngine? engine = _engine;
    if (engine == null) {
      return;
    }
    _setPhase(ConnectPhase.disconnecting, 'Disconnecting');
    try {
      await engine.disconnect();
    } catch (_) {
      failure = '';
    }
    activeNode = null;
    note = '';
    warning = '';
    _setPhase(
      ConnectPhase.idle,
      pool.isEmpty
          ? 'Ready. Next connect will scan for nodes.'
          : 'Ready. ${pool.length} nodes in the pool.',
    );
  }

  Future<void> rescan() async {
    final VeloEngine? engine = _engine;
    if (engine == null || _busy) {
      return;
    }
    _busy = true;
    _cancel.reset();
    failure = '';
    try {
      if (connected) {
        await engine.disconnect();
        activeNode = null;
      }
      await engine.prepare(onStatus: (String message) {
        status = message;
        notifyListeners();
      });
      await _resetPool();
      await _fullScan(engine);
      _setPhase(
        ConnectPhase.idle,
        pool.isEmpty
            ? 'No working node was found.'
            : '${pool.length} nodes ready, best ${pool.first.pingMs.round()} ms',
      );
    } on EngineFailure catch (error) {
      failure = error.message;
      _setPhase(ConnectPhase.error, failure);
    } catch (error) {
      failure = error.toString();
      _setPhase(ConnectPhase.error, 'Scan failed');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _fullScan(VeloEngine engine) async {
    _setPhase(ConnectPhase.fetching, 'Collecting nodes');

    final List<String> sources = <String>[...userSources];
    if (settings.useBuiltinSources) {
      for (final String url in builtinSources()) {
        if (!sources.contains(url)) {
          sources.add(url);
        }
      }
    }
    if (sources.isEmpty) {
      throw EngineFailure('Add a subscription link first.');
    }

    tested = 0;
    testTotal = sources.length;

    final SubscriptionFetcher fetcher = SubscriptionFetcher(
      allowInvalidCertificates: settings.allowInvalidCertificates,
    );
    final List<String> links = await fetcher.fetchAll(
      sources,
      onSource: (int done, int total, SourceResult result) {
        tested = done;
        testTotal = total;
        status = 'Collecting nodes ($done/$total sources)';
        _throttledNotify();
      },
    );

    if (_cancel.cancelled) {
      return;
    }

    List<Node> nodes = parseLinks(links);
    if (settings.maxNodes > 0 && nodes.length > settings.maxNodes) {
      nodes = nodes.sublist(0, settings.maxNodes);
    }
    if (nodes.isEmpty) {
      throw EngineFailure('No usable nodes came back from the sources.');
    }

    final List<Node> survivors = await _runCycles(
      engine,
      nodes,
      settings.cycles,
    );

    pool = survivors;
    generation += 1;
    poolBuiltAt = DateTime.now();
    await _savePool();
  }

  Future<void> _recheck(VeloEngine engine) async {
    final List<Node> survivors = await _runCycles(
      engine,
      _sortedPool(),
      settings.recheckCycles,
    );
    pool = survivors;
    await _savePool();
  }

  Future<List<Node>> _runCycles(
    VeloEngine engine,
    List<Node> input,
    int cycles,
  ) async {
    _setPhase(ConnectPhase.testing, 'Testing nodes');
    cycleTotal = cycles < 1 ? 1 : cycles;
    List<Node> current = List<Node>.from(input);

    for (int index = 1; index <= cycleTotal; index++) {
      if (_cancel.cancelled || current.isEmpty) {
        break;
      }

      cycle = index;
      tested = 0;
      testTotal = current.length;
      alive = 0;
      status = 'Cycle $index of $cycleTotal, ${current.length} nodes';
      notifyListeners();

      final List<TestOutcome> outcomes = await engine.testCycle(
        current,
        settings: settings,
        cancel: _cancel,
        onEach: (TestOutcome outcome, int done, int total) {
          tested = done;
          testTotal = total;
          if (outcome.ok) {
            alive += 1;
          }
          _throttledNotify();
        },
      );

      if (_cancel.cancelled) {
        break;
      }

      final List<Node> survivors = <Node>[];
      for (final TestOutcome outcome in outcomes) {
        if (outcome.ok) {
          outcome.node.recordPing(outcome.pingMs);
          survivors.add(outcome.node);
        } else {
          outcome.node.lastError = outcome.error;
        }
      }

      current = survivors;
      alive = survivors.length;
      status = 'Cycle $index done, ${survivors.length} alive';
      notifyListeners();
    }

    current.sort((Node a, Node b) => a.pingMs.compareTo(b.pingMs));
    return current;
  }

  List<Node> _sortedPool() {
    final List<Node> sorted = List<Node>.from(pool);
    sorted.sort((Node a, Node b) => a.pingMs.compareTo(b.pingMs));
    return sorted;
  }

  List<Node> _candidates() {
    final List<Node> sorted = _sortedPool();
    if (!settings.retireNodeAfterUse) {
      return sorted;
    }
    return sorted.where((Node node) => !node.used).toList();
  }

  Future<void> _resetPool() async {
    pool = <Node>[];
    activeNode = null;
    await _savePool();
  }

  Future<void> _savePool() async {
    await _store?.savePool(
      PoolSnapshot(
        nodes: pool,
        builtAt: poolBuiltAt,
        generation: generation,
      ),
    );
  }

  void _setPhase(ConnectPhase next, String message) {
    phase = next;
    status = message;
    notifyListeners();
  }

  void _throttledNotify() {
    final DateTime now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 120) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _engine?.shutdown();
    super.dispose();
  }
}
