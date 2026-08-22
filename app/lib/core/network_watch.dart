import 'dart:async';
import 'dart:io';

Future<String> networkFingerprint() async {
  try {
    final List<NetworkInterface> found = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.any,
    );
    final List<String> parts = <String>[];
    for (final NetworkInterface item in found) {
      for (final InternetAddress address in item.addresses) {
        parts.add('${item.name}=${address.address}');
      }
    }
    parts.sort();
    return parts.join(',');
  } catch (_) {
    return '';
  }
}

class NetworkWatch {
  NetworkWatch({this.period = const Duration(seconds: 5)});

  final Duration period;

  Timer? _timer;
  String _seen = '';

  Future<void> start(void Function() onChange) async {
    await stop();
    _seen = await networkFingerprint();
    _timer = Timer.periodic(period, (Timer _) async {
      final String now = await networkFingerprint();
      if (now.isEmpty || now == _seen) {
        return;
      }
      _seen = now;
      onChange();
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }
}
