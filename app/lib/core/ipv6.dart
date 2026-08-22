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

Future<Ipv6Check> checkIpv6Escape({
  Duration timeout = const Duration(seconds: 4),
  List<String> probes = ipv6Probes,
}) async {
  int tried = 0;
  for (final String probe in probes) {
    final InternetAddress? target = InternetAddress.tryParse(probe);
    if (target == null || target.type != InternetAddressType.IPv6) {
      continue;
    }
    tried += 1;
    Socket? socket;
    try {
      socket = await Socket.connect(target, ipv6ProbePort, timeout: timeout);
    } catch (_) {
      socket = null;
    }
    if (socket != null) {
      socket.destroy();
      return Ipv6Check(reachable: true, tried: tried);
    }
  }
  return Ipv6Check(reachable: false, tried: tried);
}
