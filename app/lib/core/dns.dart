import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

enum DnsStatus { found, absent, unreachable }

class DnsAnswer {
  const DnsAnswer({
    required this.status,
    this.v4 = const <String>[],
    this.v6 = const <String>[],
    this.ttlSeconds = 300,
  });

  final DnsStatus status;
  final List<String> v4;
  final List<String> v6;
  final int ttlSeconds;

  bool get hasAddress => v4.isNotEmpty || v6.isNotEmpty;
}

class DnsClient {
  DnsClient({this.timeout = const Duration(seconds: 3)});

  final Duration timeout;
  final Random _ids = Random();

  static const int _typeA = 1;
  static const int _typeAaaa = 28;

  Future<DnsAnswer> lookup(String host, List<String> resolvers) async {
    final String name = host.trim();
    if (name.isEmpty) {
      return const DnsAnswer(status: DnsStatus.absent);
    }
    for (final String resolver in resolvers) {
      final InternetAddress? target = InternetAddress.tryParse(resolver);
      if (target == null) {
        continue;
      }
      final DnsAnswer answer = await _ask(name, target);
      if (answer.status != DnsStatus.unreachable) {
        return answer;
      }
    }
    return const DnsAnswer(status: DnsStatus.unreachable);
  }

  Future<DnsAnswer> _ask(String host, InternetAddress resolver) async {
    final List<int>? name = _encodeName(host);
    if (name == null) {
      return const DnsAnswer(status: DnsStatus.absent);
    }

    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(
        resolver.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
    } catch (_) {
      return const DnsAnswer(status: DnsStatus.unreachable);
    }

    final int idA = 1 + _ids.nextInt(0xFFFE);
    final int idAaaa = idA == 0xFFFE ? 1 : idA + 1;

    final List<String> v4 = <String>[];
    final List<String> v6 = <String>[];
    final Set<int> answered = <int>{};
    int ttl = 0;
    int rcodeA = -1;
    int rcodeAaaa = -1;
    final Completer<void> done = Completer<void>();

    socket.listen(
      (RawSocketEvent event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final Datagram? packet = socket.receive();
        if (packet == null) {
          return;
        }
        final _Reply? reply = _parse(packet.data);
        if (reply == null) {
          return;
        }
        if (reply.id != idA && reply.id != idAaaa) {
          return;
        }
        answered.add(reply.id);
        if (reply.id == idA) {
          rcodeA = reply.rcode;
        } else {
          rcodeAaaa = reply.rcode;
        }
        v4.addAll(reply.v4);
        v6.addAll(reply.v6);
        if (reply.ttl > 0 && (ttl == 0 || reply.ttl < ttl)) {
          ttl = reply.ttl;
        }
        if (answered.length >= 2 && !done.isCompleted) {
          done.complete();
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) {
          done.complete();
        }
      },
      cancelOnError: true,
    );

    try {
      socket.send(_query(idA, name, _typeA), resolver, 53);
      socket.send(_query(idAaaa, name, _typeAaaa), resolver, 53);
      await done.future.timeout(timeout, onTimeout: () {});
    } catch (_) {
      socket.close();
      return const DnsAnswer(status: DnsStatus.unreachable);
    }
    socket.close();

    if (v4.isNotEmpty || v6.isNotEmpty) {
      return DnsAnswer(
        status: DnsStatus.found,
        v4: _unique(v4),
        v6: _unique(v6),
        ttlSeconds: ttl <= 0 ? 300 : ttl,
      );
    }
    if (rcodeA == 3 || (rcodeA == 0 && rcodeAaaa == 0)) {
      return const DnsAnswer(status: DnsStatus.absent);
    }
    return const DnsAnswer(status: DnsStatus.unreachable);
  }

  static List<String> _unique(List<String> items) {
    final List<String> out = <String>[];
    for (final String item in items) {
      if (!out.contains(item)) {
        out.add(item);
      }
    }
    return out;
  }

  static List<int>? _encodeName(String host) {
    final String trimmed =
        host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    if (trimmed.isEmpty || trimmed.length > 253) {
      return null;
    }
    final List<int> out = <int>[];
    for (final String label in trimmed.split('.')) {
      if (label.isEmpty || label.length > 63) {
        return null;
      }
      final List<int> bytes = <int>[];
      for (final int unit in label.codeUnits) {
        if (unit <= 0x20 || unit > 0x7E) {
          return null;
        }
        bytes.add(unit);
      }
      out.add(bytes.length);
      out.addAll(bytes);
    }
    out.add(0);
    return out;
  }

  static Uint8List _query(int id, List<int> name, int type) {
    final List<int> out = <int>[
      (id >> 8) & 0xFF,
      id & 0xFF,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      ...name,
      (type >> 8) & 0xFF,
      type & 0xFF,
      0x00,
      0x01,
    ];
    return Uint8List.fromList(out);
  }

  static _Reply? _parse(Uint8List data) {
    if (data.length < 12) {
      return null;
    }
    final int id = (data[0] << 8) | data[1];
    final int flags = (data[2] << 8) | data[3];
    if ((flags & 0x8000) == 0) {
      return null;
    }
    final int rcode = flags & 0x000F;
    final int questions = (data[4] << 8) | data[5];
    final int answers = (data[6] << 8) | data[7];

    int cursor = 12;
    for (int i = 0; i < questions; i++) {
      cursor = _skipName(data, cursor);
      if (cursor < 0 || cursor + 4 > data.length) {
        return _Reply(id, rcode, const <String>[], const <String>[], 0);
      }
      cursor += 4;
    }

    final List<String> v4 = <String>[];
    final List<String> v6 = <String>[];
    int ttl = 0;

    for (int i = 0; i < answers; i++) {
      cursor = _skipName(data, cursor);
      if (cursor < 0 || cursor + 10 > data.length) {
        break;
      }
      final int type = (data[cursor] << 8) | data[cursor + 1];
      final int recordTtl = (data[cursor + 4] << 24) |
          (data[cursor + 5] << 16) |
          (data[cursor + 6] << 8) |
          data[cursor + 7];
      final int length = (data[cursor + 8] << 8) | data[cursor + 9];
      cursor += 10;
      if (length < 0 || cursor + length > data.length) {
        break;
      }
      if (type == _typeA && length == 4) {
        v4.add(
          InternetAddress.fromRawAddress(
            Uint8List.fromList(data.sublist(cursor, cursor + 4)),
          ).address,
        );
        if (recordTtl > 0 && (ttl == 0 || recordTtl < ttl)) {
          ttl = recordTtl;
        }
      } else if (type == _typeAaaa && length == 16) {
        v6.add(
          InternetAddress.fromRawAddress(
            Uint8List.fromList(data.sublist(cursor, cursor + 16)),
          ).address,
        );
        if (recordTtl > 0 && (ttl == 0 || recordTtl < ttl)) {
          ttl = recordTtl;
        }
      }
      cursor += length;
    }

    return _Reply(id, rcode, v4, v6, ttl);
  }

  static int _skipName(Uint8List data, int start) {
    int cursor = start;
    int hops = 0;
    while (cursor < data.length && hops < 128) {
      final int length = data[cursor];
      if (length == 0) {
        return cursor + 1;
      }
      if ((length & 0xC0) == 0xC0) {
        return cursor + 2;
      }
      cursor += 1 + length;
      hops += 1;
    }
    return -1;
  }
}

class _Reply {
  _Reply(this.id, this.rcode, this.v4, this.v6, this.ttl);

  final int id;
  final int rcode;
  final List<String> v4;
  final List<String> v6;
  final int ttl;
}

Future<List<String>> systemResolvers() async {
  try {
    if (Platform.isMacOS) {
      final ProcessResult result = await Process.run(
        'scutil',
        <String>['--dns'],
      );
      if (result.exitCode != 0) {
        return <String>[];
      }
      final List<String> out = <String>[];
      final RegExp pattern = RegExp(r'nameserver\[\d+\]\s*:\s*(\S+)');
      for (final RegExpMatch match
          in pattern.allMatches(result.stdout as String)) {
        final String value = match.group(1) ?? '';
        if (value.isNotEmpty && !out.contains(value)) {
          out.add(value);
        }
      }
      return out;
    }
    if (Platform.isWindows) {
      final ProcessResult result = await Process.run('powershell', <String>[
        '-NoProfile',
        '-Command',
        'Get-DnsClientServerAddress | ForEach-Object '
            '{ \$_.ServerAddresses } | Sort-Object -Unique',
      ]);
      if (result.exitCode != 0) {
        return <String>[];
      }
      final List<String> out = <String>[];
      for (final String line in (result.stdout as String).split('\n')) {
        final String value = line.trim();
        if (value.isNotEmpty &&
            InternetAddress.tryParse(value) != null &&
            !out.contains(value)) {
          out.add(value);
        }
      }
      return out;
    }
  } catch (_) {
    return <String>[];
  }
  return <String>[];
}
