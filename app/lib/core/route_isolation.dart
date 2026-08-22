import 'dart:convert';
import 'dart:io';

import 'dns.dart';
import 'doh.dart';
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
    this.confidence = DnsConfidence.plain,
    this.agreement = 0,
  });

  final DnsStatus status;
  final List<String> v4;
  final List<String> v6;
  final DateTime expires;
  final DnsConfidence confidence;
  final int agreement;

  bool get fresh => DateTime.now().isBefore(expires);

  bool get usable => v4.isNotEmpty;

  bool get deadName =>
      status == DnsStatus.absent &&
      confidence == DnsConfidence.secure &&
      agreement >= 2;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'status': status.name,
        'v4': v4,
        'v6': v6,
        'expires': expires.toIso8601String(),
        'confidence': confidence.name,
        'agreement': agreement,
      };

  static ResolvedHost? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final DateTime? expires =
        DateTime.tryParse((value['expires'] as String?) ?? '');
    if (expires == null) {
      return null;
    }
    DnsStatus status = DnsStatus.unreachable;
    for (final DnsStatus item in DnsStatus.values) {
      if (item.name == value['status']) {
        status = item;
      }
    }
    DnsConfidence confidence = DnsConfidence.plain;
    for (final DnsConfidence item in DnsConfidence.values) {
      if (item.name == value['confidence']) {
        confidence = item;
      }
    }
    return ResolvedHost(
      status: status,
      v4: <String>[...?(value['v4'] as List<dynamic>?)?.cast<String>()],
      v6: <String>[...?(value['v6'] as List<dynamic>?)?.cast<String>()],
      expires: expires,
      confidence: confidence,
      agreement: (value['agreement'] as num?)?.toInt() ?? 0,
    );
  }
}

class ResolverSet {
  const ResolverSet({
    this.secure = const <SecureResolver>[],
    this.plain = const <String>[],
  });

  final List<SecureResolver> secure;
  final List<String> plain;

  bool get isEmpty => secure.isEmpty && plain.isEmpty;

  List<String> get addresses => <String>[
        ...secure.map((SecureResolver item) => item.address),
        ...plain,
      ];
}

class HostResolver {
  HostResolver({DnsClient? client, DohClient? secure})
      : _client = client ?? DnsClient(timeout: const Duration(seconds: 3)),
        _secure = secure ?? DohClient();

  static const int _ttlFloorSeconds = 14400;
  static const int _ttlCeilingSeconds = 86400;
  static const int _absentSeconds = 3600;
  static const int _secureProbeCount = 3;

  final DnsClient _client;
  final DohClient _secure;
  final Map<String, ResolvedHost> _cache = <String, ResolvedHost>{};

  ResolverSet _set = const ResolverSet();
  Set<String> _avoided = <String>{};
  String _network = '';
  File? _store;
  bool _loaded = false;

  ResolverSet get resolvers => _set;

  ResolvedHost? cached(String host) {
    final ResolvedHost? entry = _cache[host.toLowerCase()];
    if (entry == null || !entry.fresh) {
      return null;
    }
    return entry;
  }

  Future<void> load(File store) async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    _store = store;
    if (!store.existsSync()) {
      return;
    }
    try {
      final Object? decoded = jsonDecode(await store.readAsString());
      if (decoded is! Map) {
        return;
      }
      final Object? entries = decoded['hosts'];
      if (entries is Map) {
        entries.forEach((Object? key, Object? value) {
          final ResolvedHost? entry = ResolvedHost.fromJson(value);
          if (key is String && entry != null && entry.fresh) {
            _cache[key] = entry;
          }
        });
      }
      final Object? network = decoded['network'];
      if (network is String) {
        _network = network;
      }
    } catch (_) {
      return;
    }
  }

  Future<void> save() async {
    final File? store = _store;
    if (store == null) {
      return;
    }
    final Map<String, dynamic> hosts = <String, dynamic>{};
    _cache.forEach((String key, ResolvedHost entry) {
      if (entry.fresh) {
        hosts[key] = entry.toJson();
      }
    });
    try {
      await store.writeAsString(
        jsonEncode(<String, dynamic>{'network': _network, 'hosts': hosts}),
        flush: true,
      );
    } catch (_) {
      return;
    }
  }

  void onNetwork(String fingerprint) {
    if (fingerprint == _network) {
      return;
    }
    _network = fingerprint;
    _set = const ResolverSet();
    _avoided = <String>{};
  }

  Future<ResolverSet> pickResolvers({
    required List<String> avoid,
    required Future<HelperResult> Function(List<String> addresses) pin,
  }) async {
    final Set<String> blocked = avoid
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toSet();

    if (!_set.isEmpty && _avoided.containsAll(blocked)) {
      final HelperResult known = await pin(_set.addresses);
      if (known.ok) {
        return _set;
      }
    }
    _set = const ResolverSet();

    final List<SecureResolver> secureCandidates = secureResolvers
        .where((SecureResolver item) => !blocked.contains(item.address))
        .toList();
    final List<String> plainCandidates = directResolverCandidates
        .where((String item) => !blocked.contains(item))
        .toList();

    final List<String> everything = <String>{
      ...secureCandidates.map((SecureResolver item) => item.address),
      ...plainCandidates,
    }.toList();
    if (everything.isEmpty) {
      return const ResolverSet();
    }

    final HelperResult pinned = await pin(everything);
    if (!pinned.ok) {
      return const ResolverSet();
    }

    final List<bool> secureAlive = await Future.wait(
      secureCandidates.map((SecureResolver item) async {
        final DnsAnswer answer = await _secure.lookup(resolverProbeName, item);
        return answer.status == DnsStatus.found && answer.hasAddress;
      }),
    );
    final List<SecureResolver> working = <SecureResolver>[];
    for (int index = 0; index < secureCandidates.length; index++) {
      if (secureAlive[index] && working.length < _secureProbeCount) {
        working.add(secureCandidates[index]);
      }
    }

    final List<bool> plainAlive = await Future.wait(
      plainCandidates.map((String item) async {
        final DnsAnswer answer =
            await _client.lookup(resolverProbeName, <String>[item]);
        return answer.status == DnsStatus.found && answer.hasAddress;
      }),
    );
    final List<String> plainWorking = <String>[];
    for (int index = 0; index < plainCandidates.length; index++) {
      if (plainAlive[index] && plainWorking.length < 2) {
        plainWorking.add(plainCandidates[index]);
      }
    }

    _set = ResolverSet(secure: working, plain: plainWorking);
    _avoided = blocked;
    return _set;
  }

  Future<ResolvedHost> resolve(String host, ResolverSet set) async {
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
        expires: DateTime.now().add(const Duration(days: 7)),
        confidence: DnsConfidence.secure,
      );
      _cache[key] = entry;
      return entry;
    }

    ResolvedHost? outcome;

    for (final SecureResolver resolver in set.secure) {
      final DnsAnswer answer = await _secure.lookup(host, resolver);
      if (answer.status == DnsStatus.found) {
        outcome = _entry(answer, agreement: 1);
        break;
      }
      if (answer.status == DnsStatus.absent) {
        outcome = await _confirmAbsent(host, resolver, set);
        break;
      }
    }

    if (outcome == null) {
      final DnsAnswer answer = await _client.lookup(host, set.plain);
      if (answer.status == DnsStatus.found) {
        outcome = _entry(answer.withConfidence(DnsConfidence.plain));
      } else {
        outcome = ResolvedHost(
          status: DnsStatus.unreachable,
          v4: const <String>[],
          v6: const <String>[],
          expires: DateTime.now(),
        );
      }
    }

    if (outcome.status != DnsStatus.unreachable) {
      _cache[key] = outcome;
    }
    return outcome;
  }

  Future<ResolvedHost> _confirmAbsent(
    String host,
    SecureResolver first,
    ResolverSet set,
  ) async {
    for (final SecureResolver other in set.secure) {
      if (other.address == first.address || other.hostname == first.hostname) {
        continue;
      }
      final DnsAnswer answer = await _secure.lookup(host, other);
      if (answer.status == DnsStatus.found) {
        return _entry(answer, agreement: 1);
      }
      if (answer.status == DnsStatus.absent) {
        return ResolvedHost(
          status: DnsStatus.absent,
          v4: const <String>[],
          v6: const <String>[],
          expires: DateTime.now().add(const Duration(seconds: _absentSeconds)),
          confidence: DnsConfidence.secure,
          agreement: 2,
        );
      }
    }
    return ResolvedHost(
      status: DnsStatus.absent,
      v4: const <String>[],
      v6: const <String>[],
      expires: DateTime.now().add(const Duration(seconds: _absentSeconds)),
      confidence: DnsConfidence.secure,
      agreement: 1,
    );
  }

  ResolvedHost _entry(DnsAnswer answer, {int agreement = 0}) {
    int seconds = answer.ttlSeconds;
    if (seconds < _ttlFloorSeconds) {
      seconds = _ttlFloorSeconds;
    }
    if (seconds > _ttlCeilingSeconds) {
      seconds = _ttlCeilingSeconds;
    }
    return ResolvedHost(
      status: answer.status,
      v4: answer.v4,
      v6: answer.v6,
      expires: DateTime.now().add(Duration(seconds: seconds)),
      confidence: answer.confidence,
      agreement: agreement,
    );
  }

  void dispose() => _secure.close();
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
  static const int warmConcurrency = 8;
  static const Duration resolveBudget = Duration(seconds: 40);

  final PrivilegedHelper _helper;
  final HostResolver resolver = HostResolver();
  final Map<String, String> _dial = <String, String>{};

  bool _active = false;

  String? dialFor(String uri) => _dial[uri];

  Future<IsolationReport> begin(
    List<Node> nodes, {
    required List<String> avoidResolvers,
    required List<String> tunnelAddresses,
    String network = '',
    File? cache,
    CancelFlag? cancel,
  }) async {
    _dial.clear();
    await _helper.unpin();
    _active = false;

    if (cache != null) {
      await resolver.load(cache);
    }
    resolver.onNetwork(network);

    final ResolverSet resolvers = await resolver.pickResolvers(
      avoid: avoidResolvers,
      pin: _helper.pin,
    );
    _active = true;
    final bool blind = resolvers.isEmpty;

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
      final ResolvedHost? host = blind
          ? resolver.cached(node.server)
          : await resolver.resolve(node.server, resolvers);
      if (stop.cancelled) {
        return;
      }
      if (host == null || !host.usable) {
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

    await resolver.save();

    final List<String> notes = <String>[];
    if (full) {
      notes.add('only $maxPinnedAddresses addresses can be isolated at once');
    }
    if (blind) {
      notes.add('no resolver answered, using cached addresses only');
    }

    return IsolationReport(
      ok: true,
      pinned: wanted.length,
      unresolved: unresolved,
      deferred: deferred < 0 ? 0 : deferred,
      message: notes.join('; '),
    );
  }

  Future<void> warm(
    List<Node> nodes, {
    required File cache,
    required List<String> avoidResolvers,
    Duration budget = const Duration(seconds: 30),
  }) async {
    await resolver.load(cache);
    final List<Node> missing = nodes
        .where((Node node) => resolver.cached(node.server) == null)
        .toList();
    if (missing.isEmpty) {
      return;
    }

    final ResolverSet set = await resolver.pickResolvers(
      avoid: avoidResolvers,
      pin: (List<String> addresses) async => HelperResult(ok: true),
    );
    if (set.isEmpty) {
      return;
    }

    final CancelFlag stop = CancelFlag();
    Future<void> one(Node node) async {
      if (stop.cancelled) {
        return;
      }
      await resolver.resolve(node.server, set);
    }

    await runPool<Node>(missing, warmConcurrency, one, cancel: stop)
        .timeout(budget, onTimeout: stop.cancel);
    await resolver.save();
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
