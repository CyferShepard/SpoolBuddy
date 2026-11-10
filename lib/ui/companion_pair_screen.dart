import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../bambuddy/companion.dart';
import 'widgets.dart';

/// Pair with (or unpair from) a Bambuddy server as a SpoolBuddy device.
class CompanionPairScreen extends StatefulWidget {
  const CompanionPairScreen({super.key});

  @override
  State<CompanionPairScreen> createState() => _CompanionPairScreenState();
}

class _CompanionPairScreenState extends State<CompanionPairScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _url = TextEditingController(text: context.read<BambuddyCompanion>().url ?? '');
  final _key = TextEditingController();
  late final _name = TextEditingController(text: context.read<BambuddyCompanion>().deviceName);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final companion = context.read<BambuddyCompanion>();
    final nav = Navigator.of(context);
    try {
      await companion.pair(_url.text, _key.text, _name.text);
      nav.popUntil((r) => r.isFirst);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpair() async {
    final companion = context.read<BambuddyCompanion>();
    final nav = Navigator.of(context);
    if (!await confirm(context, 'Unpair from Bambuddy?',
        'This device is removed from Bambuddy and the app returns to standalone mode.',
        action: 'Unpair')) {
      return;
    }
    await companion.unpair();
    nav.popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<BambuddyCompanion>();
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(title: const Text('Bambuddy companion')),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (c.paired) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.link),
                title: Text('Paired as ${c.deviceName}'),
                subtitle: Text('${c.url}\nDevice ID ${c.deviceId}'),
                isThreeLine: true,
              ),
            ),
            gap,
            OutlinedButton.icon(onPressed: _unpair, icon: const Icon(Icons.link_off), label: const Text('Unpair')),
            const Divider(height: 32),
            Text('Re-pair with new settings', style: Theme.of(context).textTheme.titleSmall),
            gap,
          ] else
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'The phone becomes a SpoolBuddy device for Bambuddy. Tags you scan are matched against '
                "Bambuddy's inventory (including Spoolman), and Bambuddy's SpoolBuddy screen is shown in the app.\n\n"
                'Create an API key in Bambuddy under Settings → API Keys with inventory read and update permissions.',
              ),
            ),
          TextFormField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
                labelText: 'Bambuddy URL', hintText: 'http://192.168.1.100:8000', border: OutlineInputBorder()),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          gap,
          TextFormField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API key', border: OutlineInputBorder()),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          gap,
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Device name', border: OutlineInputBorder()),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _pair,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.link),
            label: Text(c.paired ? 'Re-pair' : 'Pair'),
          ),
        ]),
      ),
    );
  }
}
