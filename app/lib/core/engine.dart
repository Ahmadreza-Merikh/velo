import 'models.dart';
import 'settings.dart';

class CancelFlag {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void reset() {
    _cancelled = false;
  }
}

class EngineFailure implements Exception {
  EngineFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class ConnectReport {
  ConnectReport({
    required this.mode,
    required this.node,
    this.note = '',
    this.warning = '',
  });

  final TunnelMode mode;
  final Node node;
  final String note;
  final String warning;
}

abstract class VeloEngine {
  Future<void> prepare({void Function(String message)? onStatus});

  Future<List<TestOutcome>> testCycle(
    List<Node> nodes, {
    required Settings settings,
    required CancelFlag cancel,
    void Function(TestOutcome outcome, int done, int total)? onEach,
  });

  Future<ConnectReport> connect({
    required Node node,
    required Map<String, dynamic> outbound,
    required Settings settings,
  });

  Future<void> disconnect();

  Future<bool> get isActive;

  Future<String> routingConflict();

  Future<void> shutdown();
}

Future<void> runPool<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) body, {
  CancelFlag? cancel,
}) async {
  final int workers = concurrency < 1 ? 1 : concurrency;
  int cursor = 0;

  Future<void> worker() async {
    while (true) {
      if (cancel != null && cancel.cancelled) {
        return;
      }
      final int index = cursor;
      if (index >= items.length) {
        return;
      }
      cursor = index + 1;
      await body(items[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (int i = 0; i < workers && i < items.length; i++) worker(),
  ]);
}
