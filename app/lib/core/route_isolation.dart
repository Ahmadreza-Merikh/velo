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

class ResolverStats {
  int secure = 0;
  int plain = 0;
  int blind = 0;
  int absent = 0;
  int stale = 0;
  final Map<String, int> byEndpoint = <String, int>{};
  final Map<String, int> failures = <String, int>{};

  void won(String endpoint) {
    byEndpoint[endpoint] = (byEndpoint[endpoint] ?? 0) + 1;
  }

  void lost(String endpoint) {
    failures[endpoint] = (failures[endpoint] ?? 0) + 1;
  }

  bool get trustworthy => secure > 0 && plain == 0 && blind == 0;

  List<String> get lines {
    final List<String> out = <String>[
      'secure $secure, plain $plain, blind $blind, stale $stale',
    ];
    byEndpoint.forEach((String endpoint, int count) {
      out.add('$endpoint answered $count');
    });
    failures.forEach((String endpoint, int count) {
      out.add('$endpoint failed $count');
    });
    return out;
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
  static const Duration _voteWindow = Duration(days: 14);
  static const Duration _restPeriod = Duration(hours: 6);

  final DnsClient _client;
  final DohClient _secure;
  final Map<String, ResolvedHost> _cache = <String, ResolvedHost>{};
  final Map<String, Map<String, String>> _votes =
      <String, Map<String, String>>{};
  final ResolverStats stats = ResolverStats();
  final Map<String, DateTime> _restAfter = <String, DateTime>{};

  ResolverSet _set = const ResolverSet();
  Set<String> _avoided = <String>{};
  String _network = '';
  File? _store;
  bool _loaded = false;

  ResolverSet get resolvers => _set;

  ResolvedHost? cached(String host, {bool allowStale = false}) {
    final ResolvedHost? entry = _cache[host.toLowerCase()];
    if (entry == null) {
      return null;
    }
    if (entry.fresh) {
      return entry;
    }
    if (!allowStale) {
      return null;
    }
    stats.stale += 1;
    return ResolvedHost(
      status: entry.status,
      v4: entry.v4,
      v6: entry.v6,
      expires: entry.expires,
      confidence: DnsConfidence.plain,
      agreement: 0,
    );
  }

  int votesFor(String host) => _liveVotes(host.toLowerCase()).length;

  Set<String> _liveVotes(String key) {
    final Map<String, String>? held = _votes[key];
    if (held == null) {
      return <String>{};
    }
    final DateTime edge = DateTime.now().subtract(_voteWindow);
    final Set<String> live = <String>{};
    held.forEach((String who, String when) {
      final DateTime? at = DateTime.tryParse(when);
      if (at != null && at.isAfter(edge)) {
        live.add(who);
      }
    });
    return live;
  }

  void _recordVote(String key, String who) {
    final Map<String, String> held =
        _votes.putIfAbsent(key, () => <String, String>{});
    held[who] = DateTime.now().toIso8601String();
  }

  void _clearVotes(String key) => _votes.remove(key);

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
      final Object? votes = decoded['votes'];
      if (votes is Map) {
        votes.forEach((Object? key, Object? value) {
          if (key is String && value is Map) {
            final Map<String, String> held = <String, String>{};
            value.forEach((Object? who, Object? when) {
              if (who is String && when is String) {
                held[who] = when;
              }
            });
            if (held.isNotEmpty) {
              _votes[key] = held;
            }
          }
        });
      }
      final Object? rested = decoded['rest'];
      if (rested is Map) {
        rested.forEach((Object? key, Object? value) {
          final DateTime? when =
              value is String ? DateTime.tryParse(value) : null;
          if (key is String && when != null) {
            _restAfter[key] = when;
          }
        });
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
    final Map<String, dynamic> votes = <String, dynamic>{};
    _votes.forEach((String key, Map<String, String> held) {
      final Set<String> live = _liveVotes(key);
      if (live.isEmpty) {
        return;
      }
      votes[key] = <String, String>{
        for (final String who in live) who: held[who]!,
      };
    });
    final Map<String, dynamic> rest = <String, dynamic>{};
    _restAfter.forEach((String key, DateTime when) {
      if (when.isAfter(DateTime.now())) {
        rest[key] = when.toIso8601String();
      }
    });
    try {
      await store.writeAsString(
        jsonEncode(<String, dynamic>{
          'network': _network,
          'hosts': hosts,
          'votes': votes,
          'rest': rest,
        }),
        flush: true,
      );
    } catch (_) {
      return;
    }
  }

  String _restKey(SecureResolver resolver) => '$_network|${resolver.key}';

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

    final DateTime now = DateTime.now();
    final List<SecureResolver> tryNow = secureCandidates.where(
      (SecureResolver item) {
        final DateTime? rest = _restAfter[_restKey(item)];
        return rest == null || now.isAfter(rest);
      },
    ).toList();
    final List<SecureResolver> attempt =
        tryNow.isEmpty ? secureCandidates : tryNow;

    final List<bool> secureAlive = await Future.wait(
      attempt.map((SecureResolver item) async {
        final DnsAnswer answer = await _secure.lookup(resolverProbeName, item);
        return answer.status == DnsStatus.found && answer.hasAddress;
      }),
    );
    final List<SecureResolver> working = <SecureResolver>[];
    for (int index = 0; index < attempt.length; index++) {
      final String restKey = _restKey(attempt[index]);
      if (secureAlive[index]) {
        _restAfter.remove(restKey);
        if (working.length < _secureProbeCount) {
          working.add(attempt[index]);
        }
      } else {
        _restAfter[restKey] = now.add(_restPeriod);
        stats.lost(attempt[index].hostname);
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
        stats.secure += 1;
        stats.won(resolver.hostname);
        _clearVotes(key);
        outcome = _entry(answer);
        break;
      }
      if (answer.status == DnsStatus.absent) {
        stats.won(resolver.hostname);
        _recordVote(key, resolver.hostname);
        outcome = await _confirmAbsent(key, host, resolver, set);
        break;
      }
      stats.lost(resolver.hostname);
    }

    if (outcome == null) {
      final DnsAnswer answer = await _client.lookup(host, set.plain);
      if (answer.status == DnsStatus.found) {
        stats.plain += 1;
        outcome = _entry(answer.withConfidence(DnsConfidence.plain));
      } else {
        final ResolvedHost? old = cached(key, allowStale: true);
        if (old != null && old.usable) {
          return old;
        }
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
    String key,
    String host,
    SecureResolver first,
    ResolverSet set,
  ) async {
    for (final SecureResolver other in set.secure) {
      if (other.hostname == first.hostname) {
        continue;
      }
      if (_liveVotes(key).length >= 2) {
        break;
      }
      final DnsAnswer answer = await _secure.lookup(host, other);
      if (answer.status == DnsStatus.found) {
        stats.secure += 1;
        stats.won(other.hostname);
        _clearVotes(key);
        return _entry(answer);
      }
      if (answer.status == DnsStatus.absent) {
        stats.won(other.hostname);
        _recordVote(key, other.hostname);
      } else {
        stats.lost(other.hostname);
      }
    }
    stats.absent += 1;
    return ResolvedHost(
      status: DnsStatus.absent,
      v4: const <String>[],
      v6: const <String>[],
      expires: DateTime.now().add(const Duration(seconds: _absentSeconds)),
      confidence: DnsConfidence.secure,
      agreement: _liveVotes(key).length,
    );
  }

  ResolvedHost _entry(DnsAnswer answer) {
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
    this.trusted = true,
  });

  final bool ok;
  final int pinned;
  final int unresolved;
  final int deferred;
  final String message;
  final bool trusted;
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
    if (blind) {
      resolver.stats.blind += 1;
    }

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
          ? resolver.cached(node.server, allowStale: true)
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
      trusted: !blind && resolvers.secure.isNotEmpty,
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
