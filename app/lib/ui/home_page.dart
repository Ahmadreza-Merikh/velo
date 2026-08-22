import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/models.dart';
import 'connect_button.dart';
import 'settings_page.dart';
import 'sources_page.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final VeloController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  VeloController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.confirmPrivilege = _askForPrivilege;
  }

  @override
  void dispose() {
    controller.confirmPrivilege = null;
    super.dispose();
  }

  Future<bool> _askForPrivilege(String kind) async {
    final bool upgrade = kind == 'upgrade';
    final String body = upgrade
        ? 'Velo has been updated and the part of it that builds the tunnel '
            'changed, so it has to be replaced. Your system will ask for your '
            'password once. Nothing else is being installed, and this will not '
            'happen again until another update changes that same part.'
        : 'Building a tunnel means creating a network interface, and only an '
            'administrator can do that. Velo installs one small helper for the '
            'job, so your system will ask for your password once. Later '
            'connects will not ask again. You can remove the helper from the '
            'settings screen at any time.';
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          upgrade ? 'Velo needs to replace its helper' : 'Velo needs to '
              'install a helper',
        ),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return Scaffold(
          appBar: veloAppBar(
            'Velo',
            leading: IconButton(
              icon: const Icon(Icons.link),
              tooltip: 'Subscriptions',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      SourcesPage(controller: controller),
                ),
              ),
            ),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: 'Advanced settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) =>
                        SettingsPage(controller: controller),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _ModeBadge(controller: controller),
                      const SizedBox(height: 28),
                      ConnectButton(
                        phase: controller.phase,
                        progress: controller.progress,
                        caption: _caption(controller),
                        onTap: () => controller.toggle(),
                      ),
                      const SizedBox(height: 26),
                      _StatusLine(controller: controller),
                      const SizedBox(height: 22),
                      _StatsRow(controller: controller),
                      const SizedBox(height: 18),
                      _Actions(controller: controller),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _caption(VeloController controller) {
    switch (controller.phase) {
      case ConnectPhase.connected:
        final Node? node = controller.activeNode;
        if (node == null) {
          return 'Tunnel is up';
        }
        return '${node.shortLabel}\n${node.rankPing.round()} ms';
      case ConnectPhase.testing:
        return 'cycle ${controller.cycle}/${controller.cycleTotal}\n'
            '${controller.tested}/${controller.testTotal} tested';
      case ConnectPhase.fetching:
        return 'reading sources\n${controller.tested}/${controller.testTotal}';
      case ConnectPhase.connecting:
        return 'picking the fastest node';
      case ConnectPhase.disconnecting:
        return 'closing the tunnel';
      case ConnectPhase.error:
        return 'tap to try again';
      case ConnectPhase.idle:
        if (controller.poolSize == 0) {
          return 'tap to scan and connect';
        }
        return '${controller.poolSize} nodes ready';
    }
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.controller});

  final VeloController controller;

  @override
  Widget build(BuildContext context) {
    final bool connected = controller.connected;
    final bool proxyOnly = connected && controller.mode == TunnelMode.proxy;
    final String text = !connected
        ? (controller.settings.tunMode ? 'Full tunnel' : 'Proxy mode')
        : (proxyOnly ? 'Proxy mode' : 'Full tunnel');
    final Color color = !connected
        ? VeloColors.textMuted
        : (proxyOnly ? VeloColors.warning : VeloColors.connected);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: VeloColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VeloColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            proxyOnly ? Icons.alt_route : Icons.vpn_lock_outlined,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.controller});

  final VeloController controller;

  @override
  Widget build(BuildContext context) {
    final String note = controller.note;
    final String warning = controller.warning;
    final String failure = controller.failure;

    return Column(
      children: <Widget>[
        Text(
          controller.status,
          textAlign: TextAlign.center,
          style: const TextStyle(color: VeloColors.textPrimary, fontSize: 14),
        ),
        if (failure.isNotEmpty && controller.phase == ConnectPhase.error)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              failure,
              textAlign: TextAlign.center,
              style: const TextStyle(color: VeloColors.danger, fontSize: 12),
            ),
          ),
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              note,
              textAlign: TextAlign.center,
              style: const TextStyle(color: VeloColors.warning, fontSize: 12),
            ),
          ),
        if (warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              warning,
              textAlign: TextAlign.center,
              style: const TextStyle(color: VeloColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.controller});

  final VeloController controller;

  @override
  Widget build(BuildContext context) {
    final Node? best = controller.bestNode;
    return Row(
      children: <Widget>[
        _StatTile(
          label: 'Pool',
          value: '${controller.poolSize}',
        ),
        const SizedBox(width: 12),
        _StatTile(
          label: 'Best ping',
          value: best == null ? '-' : '${best.rankPing.round()} ms',
        ),
        const SizedBox(width: 12),
        _StatTile(
          label: 'Sources',
          value: '${controller.sourceCount}',
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: VeloColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: <Widget>[
            Text(
              value,
              style: const TextStyle(
                color: VeloColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: VeloColors.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.controller});

  final VeloController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.busy) {
      return TextButton.icon(
        onPressed: () => controller.cancel(),
        icon: const Icon(Icons.stop_circle_outlined, size: 18),
        label: const Text('Stop'),
        style: TextButton.styleFrom(foregroundColor: VeloColors.danger),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        TextButton.icon(
          onPressed: () => controller.rescan(),
          icon: const Icon(Icons.radar, size: 18),
          label: Text(
            controller.connected ? 'Rescan in the background' : 'Rescan all',
          ),
          style: TextButton.styleFrom(foregroundColor: VeloColors.textMuted),
        ),
      ],
    );
  }
}
