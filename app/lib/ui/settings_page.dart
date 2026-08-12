import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controller.dart';
import '../core/settings.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final VeloController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Settings _draft;
  late final TextEditingController _cycles;
  late final TextEditingController _timeout;
  late final TextEditingController _recheck;
  late final TextEditingController _concurrency;
  late final TextEditingController _connectedConcurrency;
  late final TextEditingController _maxNodes;
  late final TextEditingController _socksPort;
  late final TextEditingController _httpPort;
  late final TextEditingController _testUrl;

  @override
  void initState() {
    super.initState();
    _draft = widget.controller.settings.copy();
    _cycles = TextEditingController(text: '${_draft.cycles}');
    _timeout = TextEditingController(
      text: _draft.timeoutSeconds.toStringAsFixed(0),
    );
    _recheck = TextEditingController(text: '${_draft.recheckCycles}');
    _concurrency = TextEditingController(
      text: _draft.concurrency == 0 ? '' : '${_draft.concurrency}',
    );
    _connectedConcurrency = TextEditingController(
      text: _draft.connectedConcurrency == 0
          ? ''
          : '${_draft.connectedConcurrency}',
    );
    _maxNodes = TextEditingController(
      text: _draft.maxNodes == 0 ? '' : '${_draft.maxNodes}',
    );
    _socksPort = TextEditingController(text: '${_draft.socksPort}');
    _httpPort = TextEditingController(text: '${_draft.httpPort}');
    _testUrl = TextEditingController(text: _draft.testUrl);
  }

  @override
  void dispose() {
    _cycles.dispose();
    _timeout.dispose();
    _recheck.dispose();
    _concurrency.dispose();
    _connectedConcurrency.dispose();
    _maxNodes.dispose();
    _socksPort.dispose();
    _httpPort.dispose();
    _testUrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _draft.cycles = _readInt(_cycles.text, Settings.defaultCycles, 1, 500);
    _draft.timeoutSeconds = _readDouble(
      _timeout.text,
      Settings.defaultTimeoutSeconds,
      1,
      120,
    );
    _draft.recheckCycles = _readInt(_recheck.text, 1, 1, 50);
    _draft.concurrency = _readInt(_concurrency.text, 0, 0, 256);
    _draft.connectedConcurrency =
        _readInt(_connectedConcurrency.text, 0, 0, 256);
    _draft.maxNodes = _readInt(_maxNodes.text, 0, 0, 100000);
    _draft.socksPort = _readInt(_socksPort.text, 10808, 1024, 65535);
    _draft.httpPort = _readInt(_httpPort.text, 10809, 1024, 65535);
    final String url = _testUrl.text.trim();
    if (url.startsWith('http')) {
      _draft.testUrl = url;
    }

    await widget.controller.saveSettings(_draft);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: veloAppBar(
        'Advanced settings',
        actions: <Widget>[
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          const _SectionTitle('Testing'),
          _NumberField(
            controller: _cycles,
            label: 'Test cycles',
            hint: '20',
            help: 'Each cycle re-tests only the nodes that survived the one '
                'before it. More cycles means a smaller but more reliable pool.',
          ),
          _NumberField(
            controller: _timeout,
            label: 'Timeout (seconds)',
            hint: '10',
            help: 'How long a single node gets to answer before it is counted '
                'as dead.',
          ),
          _NumberField(
            controller: _recheck,
            label: 'Cycles before reconnect',
            hint: '1',
            help: 'Cycles to run over the surviving pool each time you press '
                'connect again.',
          ),
          _NumberField(
            controller: _concurrency,
            label: 'Parallel tests',
            hint: '${Settings.platformConcurrency} (automatic)',
            help: 'Leave empty to pick a value that suits this device.',
          ),
          _NumberField(
            controller: _connectedConcurrency,
            label: 'Parallel tests while connected',
            hint: '${Settings.platformConnectedConcurrency} (automatic)',
            help: 'Tests that run while the tunnel is up are kept slow on '
                'purpose so they do not compete with your own traffic.',
          ),
          _NumberField(
            controller: _maxNodes,
            label: 'Node limit per scan',
            hint: 'no limit',
            help: 'Leave empty to test every node the sources return.',
          ),
          _TextField(
            controller: _testUrl,
            label: 'Test URL',
            hint: Settings.defaultTestUrl,
          ),
          const SizedBox(height: 8),
          const _SectionTitle('Connection'),
          SwitchListTile(
            value: _draft.tunMode,
            onChanged: (bool value) => setState(() => _draft.tunMode = value),
            title: const Text('Full tunnel'),
            subtitle: Text(
              Platform.isAndroid
                  ? 'Route every app through the tunnel.'
                  : 'Route every app through a tun interface. Needs the '
                      'privileged helper.',
              style: const TextStyle(color: VeloColors.textMuted, fontSize: 12),
            ),
            contentPadding: EdgeInsets.zero,
          ),
          if (!Platform.isAndroid)
            SwitchListTile(
              value: _draft.allowProxyFallback,
              onChanged: (bool value) =>
                  setState(() => _draft.allowProxyFallback = value),
              title: const Text('Fall back to proxy mode'),
              subtitle: const Text(
                'If the tunnel cannot start, run a local proxy and switch the '
                'system over to it instead of failing.',
                style: TextStyle(color: VeloColors.textMuted, fontSize: 12),
              ),
              contentPadding: EdgeInsets.zero,
            ),
          SwitchListTile(
            value: _draft.retireNodeAfterUse,
            onChanged: (bool value) =>
                setState(() => _draft.retireNodeAfterUse = value),
            title: const Text('Use each node only once'),
            subtitle: const Text(
              'Move to the next fastest node on every reconnect instead of '
              'staying on the current best one.',
              style: TextStyle(color: VeloColors.textMuted, fontSize: 12),
            ),
            contentPadding: EdgeInsets.zero,
          ),
          _NumberField(
            controller: _socksPort,
            label: 'Local SOCKS port',
            hint: '10808',
          ),
          _NumberField(
            controller: _httpPort,
            label: 'Local HTTP port',
            hint: '10809',
          ),
          const SizedBox(height: 8),
          const _SectionTitle('Sources'),
          SwitchListTile(
            value: _draft.useBuiltinSources,
            onChanged: (bool value) =>
                setState(() => _draft.useBuiltinSources = value),
            title: const Text('Search built-in sources'),
            subtitle: const Text(
              'Velo ships with a bundled set of public sources and searches '
              'them together with your own.',
              style: TextStyle(color: VeloColors.textMuted, fontSize: 12),
            ),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _draft.allowInvalidCertificates,
            onChanged: (bool value) =>
                setState(() => _draft.allowInvalidCertificates = value),
            title: const Text('Accept invalid certificates'),
            subtitle: const Text(
              'Some feeds use self signed certificates. Turning this on lets '
              'them load, but the node list can then be tampered with.',
              style: TextStyle(color: VeloColors.textMuted, fontSize: 12),
            ),
            contentPadding: EdgeInsets.zero,
          ),
          if (!Platform.isAndroid) ...<Widget>[
            const SizedBox(height: 8),
            const _SectionTitle('Helper'),
            const Text(
              'The privileged helper is what lets the tunnel create a network '
              'interface. It is installed once, behind a single admin prompt.',
              style: TextStyle(color: VeloColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _removeHelper,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove privileged helper'),
              style: OutlinedButton.styleFrom(
                foregroundColor: VeloColors.danger,
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _removeHelper() async {
    final bool removed = await widget.controller.removeHelper();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed ? 'Helper removed.' : 'Helper was not removed.',
        ),
      ),
    );
  }

  static int _readInt(String raw, int fallback, int min, int max) {
    final int value = int.tryParse(raw.trim()) ?? fallback;
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  static double _readDouble(
    String raw,
    double fallback,
    double min,
    double max,
  ) {
    final double value = double.tryParse(raw.trim()) ?? fallback;
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: VeloColors.accent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.hint,
    this.help,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String? help;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: veloField(hint),
          ),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                help!,
                style: const TextStyle(
                  color: VeloColors.textMuted,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            decoration: veloField(hint),
          ),
        ],
      ),
    );
  }
}
