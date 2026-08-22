import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dns.dart';

class SecureResolver {
  const SecureResolver(this.address, this.hostname, {this.path = '/dns-query'});

  final String address;
  final String hostname;
  final String path;

  Uri get url => Uri.parse('https://$hostname$path');
}

const List<SecureResolver> secureResolvers = <SecureResolver>[
  SecureResolver('1.0.0.1', 'cloudflare-dns.com'),
  SecureResolver('8.8.4.4', 'dns.google'),
  SecureResolver('94.140.14.14', 'dns.adguard-dns.com'),
  SecureResolver('76.76.2.0', 'freedns.controld.com'),
  SecureResolver('45.90.28.0', 'dns.nextdns.io'),
  SecureResolver('94.140.15.15', 'dns.adguard-dns.com'),
];

class DohClient {
  DohClient({this.timeout = const Duration(seconds: 6), this.onTrouble});

  final Duration timeout;
  final void Function(String message)? onTrouble;
  final Random _ids = Random();
  final Map<String, HttpClient> _clients = <String, HttpClient>{};

  HttpClient _clientFor(SecureResolver resolver) {
    return _clients.putIfAbsent(resolver.address, () {
      final HttpClient client = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 20)
        ..maxConnectionsPerHost = 4
        ..userAgent = null;
      client.connectionFactory = (Uri url, String? proxyHost, int? proxyPort) {
        return Socket.startConnect(resolver.address, url.port);
      };
      return client;
    });
  }

  Future<DnsAnswer> lookup(String host, SecureResolver resolver) async {
    final String name = host.trim();
    if (name.isEmpty) {
      return const DnsAnswer(status: DnsStatus.absent);
    }

    final List<DnsReply?> replies = await Future.wait(<Future<DnsReply?>>[
      _ask(name, DnsWire.typeA, resolver),
      _ask(name, DnsWire.typeAaaa, resolver),
    ]);

    if (replies[0] == null && replies[1] == null) {
      return const DnsAnswer(status: DnsStatus.unreachable);
    }
    return DnsWire.classify(replies[0], replies[1])
        .withConfidence(DnsConfidence.secure);
  }

  Future<DnsReply?> _ask(
    String host,
    int type,
    SecureResolver resolver,
  ) async {
    final int id = _ids.nextInt(0xFFFE) + 1;
    final Uint8List body = DnsWire.query(id, host, type);
    if (body.isEmpty) {
      return null;
    }

    try {
      final HttpClientRequest request =
          await _clientFor(resolver).postUrl(resolver.url).timeout(timeout);
      request.headers.set('content-type', 'application/dns-message');
      request.headers.set('accept', 'application/dns-message');
      request.headers.contentLength = body.length;
      request.add(body);
      final HttpClientResponse response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        onTrouble?.call('${resolver.hostname} answered ${response.statusCode}');
        return null;
      }
      final BytesBuilder collected = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(timeout)) {
        collected.add(chunk);
        if (collected.length > 4096) {
          return null;
        }
      }
      final DnsReply? reply = DnsWire.parse(collected.takeBytes());
      if (reply == null || reply.id != id) {
        return null;
      }
      return reply;
    } catch (error) {
      onTrouble?.call('${resolver.hostname}: $error');
      return null;
    }
  }

  void close() {
    for (final HttpClient client in _clients.values) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
