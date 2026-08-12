import 'dart:io';

import 'dns.dart';
import 'engine.dart';
import 'models.dart';
import 'privileged_helper.dart';

const List<String> directResolverCandidates = <String>[
  '208.67.222.222',
  '1.0.0.1',
  '9.9.9.9',
  '208.67.220.220',
  '149.112.112.112',
  '8.8.4.4',
  '1.1.1.1',
  '8.8.8.8',
];

const String resolverProbeName = 'www.cloudflare.com';

class ResolvedHost {
  ResolvedHost({
    required this.status,
    required this.v4,
    required this.v6,
    required this.expires,
  });

  final DnsStatus status;
  final List<String> v4;
  final List<String> v6;
  final DateTime expires;

  bool get fresh => DateTime.now().isBefore(expires);
  bool get usable => v4.isNotEmpty;
}

class HostResolver {
  HostResolver({DnsClient? client})
      : _client = client ?? DnsClient(timeout: const Duration(seconds: 3));

  static const int _ttlFloorSeconds = 120;
  static const int _ttlCeilingSeconds = 3600;
  static const int _absentSeconds = 600;

  final DnsClient _client;
  final Map<String, ResolvedHost> _cache = <String, ResolvedHost>{};
  List<String> _verified = <String>[];

  ResolvedHost? cached(String host) {
    final ResolvedHost? entry = _cache[host.toLowerCase()];
    if (entry == null || !entry.fresh) {
      return null;
    }
    return entry;
  }

  Future<List<String>> pickResolvers({
    required List<String> avoid,
    required Future<HelperResult> Function(List<String> addresses) pin,
  }) async {
    final Set<String> blocked = avoid
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toSet();
    final List<String> candidates = directResolverCandidates
        .where((String item) => !blocked.contains(item))
        .toList();
    if (candidates.isEmpty) {
      return <String>[];
    }

    final List<String> known =
        _verified.where(candidates.contains).toList();
    if (known.isNotEmpty) {
      final List<String> working = await _probe(known, pin);
      if (working.isNotEmpty) {
        return working;
      }
    }

    final List<String> working = await _probe(candidates, pin);
    _verified = working;
    return working;
  }

  Future<List<String>> _probe(
    List<String> candidates,
    Future<HelperResult> Function(List<String> addresses) pin,
  ) async {
    final HelperResult pinned = await pin(candidates);
    if (!pinned.ok) {
      return <String>[];
    }

    final List<bool> alive = await Future.wait(
      candidates.map((String candidate) async {
        final DnsAnswer answer = await _client.lookup(
          resolverProbeName,
          <String>[candidate],
        );
        return answer.status == DnsStatus.found && answer.hasAddress;
      }),
    );

    final List<String> working = <String>[];
    for (int index = 0; index < candidates.length; index++) {
      if (alive[index]) {
        working.add(candidates[index]);
      }
      if (working.length >= 2) {
        break;
      }
    }
    return working;
  }

  Future<ResolvedHost> resolve(String host, List<String> resolvers) async {
    final String key = host.toLowerCase();
    final ResolvedHost? hit = cached(key);
    if (hit != null) {
      return hit;
    }

    final InternetAddress? literal = InternetAddress.tryParse(host);
    if (literal != null) {
      final ResolvedHost entry = ResolvedHost(
        status: DnsStatus.found,
        v4: literal.type == InternetAddressType.IPv4
            ? <String>[literal.address]
            : <String>[],
        v6: literal.type == InternetAddressType.IPv6
            ? <String>[literal.address]
            : <String>[],
        expires: DateTime.now().add(const Duration(hours: 12)),
      );
      _cache[key] = entry;
      return entry;
    }

    final DnsAnswer answer = await _client.lookup(host, resolvers);
    int seconds = answer.ttlSeconds;
    if (seconds < _ttlFloorSeconds) {
      seconds = _ttlFloorSeconds;
    }
    if (seconds > _ttlCeilingSeconds) {
      seconds = _ttlCeilingSeconds;
    }

    final ResolvedHost entry = ResolvedHost(
      status: answer.status,
      v4: answer.v4,
      v6: answer.v6,
      expires: DateTime.now().add(
        Duration(
          seconds: answer.status == DnsStatus.absent ? _absentSeconds : seconds,
        ),
      ),
    );
    if (answer.status != DnsStatus.unreachable) {
      _cache[key] = entry;
    }
    return entry;
  }
}

class IsolationReport {
  IsolationReport({
    required this.ok,
    this.pinned = 0,
    this.unresolved = 0,
    this.deferred = 0,
    this.message = '',
  });

  final bool ok;
  final int pinned;
  final int unresolved;
  final int deferred;
  final String message;
}

class TestRouteGuard {
  TestRouteGuard(this._helper);

  static const int maxPinnedAddresses = 600;
  static const int resolveConcurrency = 32;
  static const Duration resolveBudget = Duration(seconds: 25);

  final PrivilegedHelper _helper;
  final HostResolver resolver = HostResolver();
  final Map<String, String> _dial = <String, String>{};

  bool _active = false;

  String? dialFor(String uri) => _dial[uri];

  Future<IsolationReport> begin(
    List<Node> nodes, {
    required List<String> avoidResolvers,
    required List<String> tunnelAddresses,
    CancelFlag? cancel,
  }) async {
    _dial.clear();
    await _helper.unpin();
    _active = false;

    final List<String> resolvers = await resolver.pickResolvers(
      avoid: avoidResolvers,
      pin: _helper.pin,
    );
    if (resolvers.isEmpty) {
      await _helper.unpin();
      return IsolationReport(
        ok: false,
        message: 'no resolver is reachable outside the tunnel',
      );
    }
    _active = true;

    final Set<String> protected = tunnelAddresses.toSet();
    final Set<String> wanted = <String>{};
    int unresolved = 0;
    int deferred = 0;
    bool full = false;

    final CancelFlag stop = CancelFlag();

    Future<void> collect(Node node) async {
      if (cancel != null && cancel.cancelled) {
        stop.cancel();
        return;
      }
      if (stop.cancelled) {
        return;
      }
      final ResolvedHost host = await resolver.resolve(node.server, resolvers);
      if (stop.cancelled) {
        return;
      }
      if (!host.usable) {
        unresolved += 1;
        return;
      }
      final String dial = host.v4.first;
      final List<String> fresh = <String>[];
      for (final String address in host.v4) {
        if (!protected.contains(address) && !wanted.contains(address)) {
          fresh.add(address);
        }
      }
      if (wanted.length + fresh.length > maxPinnedAddresses) {
        full = true;
        deferred += 1;
        return;
      }
      wanted.addAll(fresh);
      _dial[node.uri] = dial;
    }

    await runPool<Node>(nodes, resolveConcurrency, collect, cancel: stop)
        .timeout(resolveBudget, onTimeout: stop.cancel);
    if (stop.cancelled) {
      final int missing = nodes.length - _dial.length - unresolved;
      if (missing > deferred) {
        deferred = missing;
      }
    }

    if (wanted.isNotEmpty) {
      final HelperResult pinned = await _helper.pin(wanted.toList());
      if (!pinned.ok) {
        await end();
        return IsolationReport(
          ok: false,
          message: pinned.message.isEmpty
              ? 'could not pin the test routes'
              : pinned.message,
        );
      }
    }

    return IsolationReport(
      ok: true,
      pinned: wanted.length,
      unresolved: unresolved,
      deferred: deferred < 0 ? 0 : deferred,
      message: full
          ? 'only $maxPinnedAddresses addresses can be isolated at once'
          : '',
    );
  }

  Future<void> end() async {
    _dial.clear();
    if (!_active) {
      return;
    }
    _active = false;
    await _helper.unpin();
  }
}
