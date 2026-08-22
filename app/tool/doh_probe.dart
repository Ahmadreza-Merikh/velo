import 'dart:io';

import '../lib/core/dns.dart';
import '../lib/core/doh.dart';

Future<void> main(List<String> args) async {
  final String host = args.isEmpty ? 'raw.githubusercontent.com' : args.first;
  final DohClient client = DohClient(
    onTrouble: (String message) => stdout.writeln('  ! $message'),
  );

  int secure = 0;
  int failed = 0;

  stdout.writeln('resolving $host over ${secureResolvers.length} endpoints');

  for (final SecureResolver resolver in secureResolvers) {
    final Stopwatch watch = Stopwatch()..start();
    final DnsAnswer answer = await client.lookup(host, resolver);
    watch.stop();
    final String line = '${resolver.address.padRight(16)} '
        '${resolver.hostname.padRight(24)} '
        '${watch.elapsedMilliseconds.toString().padLeft(5)}ms  '
        'status=${answer.status.name.padRight(11)} '
        'confidence=${answer.confidence.name.padRight(6)} '
        'v4=${answer.v4.take(2).toList()}';
    stdout.writeln(line);
    if (answer.status == DnsStatus.found &&
        answer.hasAddress &&
        answer.confidence == DnsConfidence.secure) {
      secure += 1;
    } else {
      failed += 1;
    }
  }

  final DnsAnswer missing = await client.lookup(
    'velo-probe-no-such-name-98f3a1.example',
    secureResolvers.first,
  );
  stdout.writeln('nxdomain probe: status=${missing.status.name} '
      'confidence=${missing.confidence.name}');

  client.close();

  stdout.writeln('secure=$secure failed=$failed');
  if (secure == 0) {
    stderr.writeln('no endpoint answered over the secure transport');
    exit(1);
  }
  if (missing.status != DnsStatus.absent) {
    stderr.writeln('nxdomain was not reported as absent');
    exit(1);
  }
}
