import 'package:flutter/material.dart';

import '../core/controller.dart';
import 'theme.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.controller});

  final VeloController controller;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final String value = _input.text.trim();
    if (value.isEmpty) {
      return;
    }
    await widget.controller.addSource(value);
    _input.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<String> sources = widget.controller.userSources;

    return Scaffold(
      appBar: veloAppBar('Subscriptions'),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Add your own subscription links or raw share links. Velo '
                  'searches them together with its bundled sources.',
                  style: TextStyle(color: VeloColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _input,
                        decoration: veloField('https://example.com/sub'),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _add,
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 20),
          Expanded(
            child: sources.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'No subscriptions of your own yet.\nThe bundled sources '
                        'are already being searched.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: VeloColors.textMuted,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    itemCount: sources.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final String url = sources[index];
                      return Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                        decoration: BoxDecoration(
                          color: VeloColors.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                url,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              color: VeloColors.textMuted,
                              onPressed: () async {
                                await widget.controller.removeSource(url);
                                setState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
