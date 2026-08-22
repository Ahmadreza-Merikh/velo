import 'dart:io';

import '../lib/core/ipv6.dart';

Future<void> main() async {
  stdout.writeln('--- a reachable address must be reported as reachable ---');
  ServerSocket? listener;
  try {
    listener = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
  } catch (error) {
    stdout.writeln('this runner has no ipv6 loopback: $error');
  }

  if (listener != null) {
    listener.listen((Socket client) => client.destroy());
    final Ipv6Check open = await checkIpv6Escape(
      probes: <String>[InternetAddress.loopbackIPv6.address],
      port: listener.port,
    );
    stdout.writeln('loopback on ${listener.port}: '
        'reachable=${open.reachable} tried=${open.tried}');
    await listener.close();
    if (!open.reachable) {
      stderr.writeln('the check failed to notice a reachable address');
      exit(1);
    }
  }

  stdout.writeln('--- the real probe against this runner ---');
  final Stopwatch watch = Stopwatch()..start();
  final Ipv6Check live = await checkIpv6Escape();
  watch.stop();
  stdout.writeln('reachable=${live.reachable} contained=${live.contained} '
      'tried=${live.tried} in ${watch.elapsedMilliseconds}ms');

  if (live.tried != ipv6Probes.length) {
    stderr.writeln('the check did not attempt every probe');
    exit(1);
  }
  if (watch.elapsedMilliseconds > 4000) {
    stderr.writeln('the check took too long to give an answer');
    exit(1);
  }
  stdout.writeln(live.reachable
      ? 'this runner has ipv6 and the check saw it'
      : 'this runner has no ipv6 and the check said so');
}
