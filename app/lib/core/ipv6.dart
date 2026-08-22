import 'dart:async';
import 'dart:io';

const List<String> ipv6Probes = <String>[
  '2606:4700:4700::1111',
  '2001:4860:4860::8888',
];

const int ipv6ProbePort = 443;

class Ipv6Check {
  const Ipv6Check({required this.reachable, required this.tried});

  final bool reachable;
  final int tried;

  bool get contained => !reachable;
}

Future<bool> _reaches(InternetAddress target, int port, Duration timeout) async {
  Socket? socket;
  try {
    socket = await Socket.connect(target, port, timeout: timeout);
  } catch (_) {
    return false;
  }
  socket.destroy();
  return true;
}

Future<Ipv6Check> checkIpv6Escape({
  Duration timeout = const Duration(seconds: 2),
  List<String> probes = ipv6Probes,
  int port = ipv6ProbePort,
}) async {
  final List<Future<bool>> attempts = <Future<bool>>[];
  for (final String probe in probes) {
    final InternetAddress? target = InternetAddress.tryParse(probe);
    if (target == null || target.type != InternetAddressType.IPv6) {
      continue;
    }
    attempts.add(_reaches(target, port, timeout));
  }
  if (attempts.isEmpty) {
    return const Ipv6Check(reachable: false, tried: 0);
  }
  final List<bool> results = await Future.wait(attempts);
  return Ipv6Check(
    reachable: results.contains(true),
    tried: attempts.length,
  );
}
