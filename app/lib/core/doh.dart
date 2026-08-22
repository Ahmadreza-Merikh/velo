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

  String get key => '$address$path';
}

const List<SecureResolver> secureResolvers = <SecureResolver>[
  SecureResolver('1.0.0.1', 'cloudflare-dns.com'),
  SecureResolver('8.8.4.4', 'dns.google'),
  SecureResolver('94.140.14.14', 'dns.adguard-dns.com'),
  SecureResolver('76.76.2.0', 'freedns.controld.com'),
  SecureResolver('45.90.28.0', 'dns.nextdns.io'),
  SecureResolver('94.140.15.15', 'dns.adguard-dns.com'),
];

class _Conn {
  _Conn(this.socket) {
    socket.listen(
      (Uint8List chunk) {
        _buffer.addAll(chunk);
        _wake();
      },
      onError: (Object _) {
        dead = true;
        _wake();
      },
      onDone: () {
        dead = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  final SecureSocket socket;
  final List<int> _buffer = <int>[];
  bool dead = false;
  Completer<void>? _waiter;

  void _wake() {
    final Completer<void>? waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Future<void> _more() {
    if (dead) {
      return Future<void>.error(const SocketException('resolver went away'));
    }
    final Completer<void> waiter = Completer<void>();
    _waiter = waiter;
    return waiter.future;
  }

  Future<String> readLine() async {
    while (true) {
      for (int i = 0; i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
          final String line = String.fromCharCodes(_buffer.sublist(0, i));
          _buffer.removeRange(0, i + 2);
          return line;
        }
      }
      if (_buffer.length > 16384) {
        throw const SocketException('header line was too long');
      }
      await _more();
    }
  }

  Future<Uint8List> readBytes(int count) async {
    while (_buffer.length < count) {
      await _more();
    }
    final Uint8List out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return out;
  }

  void close() {
    dead = true;
    try {
      socket.destroy();
    } catch (_) {
      return;
    }
  }
}

class DohClient {
  DohClient({this.timeout = const Duration(seconds: 6), this.onTrouble});

  static const int _maxBody = 8192;

  final Duration timeout;
  final void Function(String message)? onTrouble;
  final Random _ids = Random();
  final Map<String, _Conn> _pool = <String, _Conn>{};
  final Map<String, Future<void>> _turn = <String, Future<void>>{};

  Future<DnsAnswer> lookup(String host, SecureResolver resolver) async {
    final String name = host.trim();
    if (name.isEmpty) {
      return const DnsAnswer(status: DnsStatus.absent);
    }

    final DnsReply? a = await _ask(name, DnsWire.typeA, resolver);
    final DnsReply? aaaa = await _ask(name, DnsWire.typeAaaa, resolver);

    if (a == null && aaaa == null) {
      return const DnsAnswer(status: DnsStatus.unreachable);
    }
    return DnsWire.classify(a, aaaa).withConfidence(DnsConfidence.secure);
  }

  Future<DnsReply?> _ask(
    String host,
    int type,
    SecureResolver resolver,
  ) async {
    final Future<void> queued = _turn[resolver.key] ?? Future<void>.value();
    final Completer<void> mine = Completer<void>();
    _turn[resolver.key] = mine.future;
    try {
      await queued;
    } catch (_) {
      _ignore();
    }
    try {
      return await _exchange(host, type, resolver).timeout(timeout);
    } catch (error) {
      _drop(resolver);
      onTrouble?.call('${resolver.hostname}: $error');
      return null;
    } finally {
      mine.complete();
    }
  }

  Future<DnsReply?> _exchange(
    String host,
    int type,
    SecureResolver resolver,
  ) async {
    final int id = _ids.nextInt(0xFFFE) + 1;
    final Uint8List body = DnsWire.query(id, host, type);
    if (body.isEmpty) {
      return null;
    }

    _Conn conn = await _connect(resolver);
    DnsReply? reply;
    try {
      reply = await _round(conn, resolver, body, id);
    } on SocketException {
      _drop(resolver);
      conn = await _connect(resolver);
      reply = await _round(conn, resolver, body, id);
    }
    return reply;
  }

  Future<DnsReply?> _round(
    _Conn conn,
    SecureResolver resolver,
    Uint8List body,
    int id,
  ) async {
    final StringBuffer head = StringBuffer()
      ..write('POST ${resolver.path} HTTP/1.1\r\n')
      ..write('Host: ${resolver.hostname}\r\n')
      ..write('Content-Type: application/dns-message\r\n')
      ..write('Accept: application/dns-message\r\n')
      ..write('Content-Length: ${body.length}\r\n')
      ..write('\r\n');

    conn.socket.add(head.toString().codeUnits);
    conn.socket.add(body);
    await conn.socket.flush();

    final String status = await conn.readLine();
    final List<String> parts = status.split(' ');
    final int code = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    int length = -1;
    bool chunked = false;
    bool closing = false;
    while (true) {
      final String line = await conn.readLine();
      if (line.isEmpty) {
        break;
      }
      final int split = line.indexOf(':');
      if (split < 0) {
        continue;
      }
      final String field = line.substring(0, split).trim().toLowerCase();
      final String value = line.substring(split + 1).trim().toLowerCase();
      if (field == 'content-length') {
        length = int.tryParse(value) ?? -1;
      } else if (field == 'transfer-encoding' && value.contains('chunked')) {
        chunked = true;
      } else if (field == 'connection' && value.contains('close')) {
        closing = true;
      }
    }

    final Uint8List payload = chunked
        ? await _readChunked(conn)
        : await conn.readBytes(length < 0 ? 0 : length);

    if (closing) {
      _drop(resolver);
    }

    if (code != 200) {
      onTrouble?.call('${resolver.hostname} answered $code');
      return null;
    }
    final DnsReply? reply = DnsWire.parse(payload);
    if (reply == null || reply.id != id) {
      onTrouble?.call('${resolver.hostname} sent an answer that did not match');
      return null;
    }
    return reply;
  }

  Future<Uint8List> _readChunked(_Conn conn) async {
    final BytesBuilder out = BytesBuilder();
    while (true) {
      final String header = await conn.readLine();
      final int size = int.tryParse(header.split(';').first.trim(), radix: 16) ?? 0;
      if (size <= 0) {
        await conn.readLine();
        break;
      }
      out.add(await conn.readBytes(size));
      await conn.readLine();
      if (out.length > _maxBody) {
        throw const SocketException('answer was too large');
      }
    }
    return out.takeBytes();
  }

  Future<_Conn> _connect(SecureResolver resolver) async {
    final _Conn? held = _pool[resolver.key];
    if (held != null && !held.dead) {
      return held;
    }
    _pool.remove(resolver.key);

    final Socket raw = await Socket.connect(
      resolver.address,
      443,
      timeout: timeout,
    );
    final SecureSocket secure = await SecureSocket.secure(
      raw,
      host: resolver.hostname,
    );
    final _Conn conn = _Conn(secure);
    _pool[resolver.key] = conn;
    return conn;
  }

  void _drop(SecureResolver resolver) {
    _pool.remove(resolver.key)?.close();
  }

  static void _ignore() {}

  void close() {
    for (final _Conn conn in _pool.values) {
      conn.close();
    }
    _pool.clear();
    _turn.clear();
  }
}
