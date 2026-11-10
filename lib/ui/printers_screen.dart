import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/printer.dart';
import '../printers/printer_connection.dart';
import '../printers/printer_manager.dart';
import 'printer_detail_screen.dart';

String statusLabel(PrinterConnection? c) => switch (c?.status) {
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.connecting => 'Connecting…',
      ConnectionStatus.error => c?.lastError ?? 'Error',
      _ => 'Disconnected',
    };

Color statusColor(PrinterConnection? c) => switch (c?.status) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting => Colors.orange,
      ConnectionStatus.error => Colors.red,
      _ => Colors.grey,
    };

class PrintersScreen extends StatelessWidget {
  const PrintersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pm = context.watch<PrinterManager>();
    return Scaffold(
      appBar: AppBar(title: const Text('Printers')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add printer'),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrinterFormScreen())),
      ),
      body: pm.printers.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Add a Bambu Lab printer to see AMS slots and assign spools.\n\n'
                  'The printer must have LAN mode / Developer Mode enabled. You need its IP address, '
                  'serial number and LAN access code (shown on the printer screen).',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(children: [
              for (final p in pm.printers)
                Builder(builder: (context) {
                  final c = pm.connection(p.serial);
                  final s = c?.state;
                  final printing = s?.gcodeState == 'RUNNING' || s?.gcodeState == 'PAUSE';
                  return ListTile(
                    leading: Icon(Icons.print, color: statusColor(c)),
                    title: Text(p.displayName),
                    subtitle: Text([
                      statusLabel(c),
                      if (c?.connected == true && printing) '${s?.subtaskName ?? ''} ${s?.printProgress ?? 0}%',
                      if (c?.connected == true && !printing && s?.gcodeState != null) s!.gcodeState!,
                    ].join(' · ')),
                    trailing: (c?.connected ?? false) || c?.status == ConnectionStatus.connecting
                        ? TextButton(onPressed: () => pm.disconnect(p.serial), child: const Text('Disconnect'))
                        : TextButton(onPressed: () => pm.connect(p.serial), child: const Text('Connect')),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => PrinterDetailScreen(serial: p.serial))),
                  );
                }),
            ]),
    );
  }
}

class PrinterFormScreen extends StatefulWidget {
  const PrinterFormScreen({super.key, this.printer});

  final Printer? printer;

  @override
  State<PrinterFormScreen> createState() => _PrinterFormScreenState();
}

class _PrinterFormScreenState extends State<PrinterFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.printer?.name);
  late final _serial = TextEditingController(text: widget.printer?.serial);
  late final _ip = TextEditingController(text: widget.printer?.ipAddress);
  late final _code = TextEditingController(text: widget.printer?.accessCode);
  late final _model = TextEditingController(text: widget.printer?.model);
  late bool _autoConnect = widget.printer?.autoConnect ?? true;

  @override
  void dispose() {
    for (final c in [_name, _serial, _ip, _code, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final pm = context.read<PrinterManager>();
    final nav = Navigator.of(context);
    final printer = Printer(
      serial: _serial.text.trim().toUpperCase(),
      name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      model: _model.text.trim().isEmpty ? null : _model.text.trim(),
      ipAddress: _ip.text.trim(),
      accessCode: _code.text.trim(),
      autoConnect: _autoConnect,
      nozzleCount: widget.printer?.nozzleCount ?? 1,
    );
    await pm.savePrinter(printer);
    if (widget.printer == null) pm.connect(printer.serial);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;
    const gap = SizedBox(height: 12);
    InputDecoration dec(String l, {String? hint}) =>
        InputDecoration(labelText: l, hintText: hint, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.printer == null ? 'Add printer' : 'Edit printer'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(controller: _name, decoration: dec('Name', hint: 'e.g. Workshop X1C')),
          gap,
          TextFormField(
            controller: _serial,
            enabled: widget.printer == null,
            decoration: dec('Serial number'),
            validator: required,
          ),
          gap,
          TextFormField(
            controller: _ip,
            keyboardType: TextInputType.url,
            decoration: dec('IP address', hint: '192.168.1.50'),
            validator: (v) {
              if (required(v) != null) return 'Required';
              return InternetAddressCheck.isIp(v!.trim()) ? null : 'Enter an IPv4 address';
            },
          ),
          gap,
          TextFormField(controller: _code, decoration: dec('LAN access code'), validator: required),
          gap,
          TextFormField(controller: _model, decoration: dec('Model (optional)', hint: 'X1C, P1S, A1, H2D…')),
          gap,
          SwitchListTile(
            title: const Text('Connect automatically'),
            value: _autoConnect,
            onChanged: (v) => setState(() => _autoConnect = v),
          ),
        ]),
      ),
    );
  }
}

class InternetAddressCheck {
  static bool isIp(String s) {
    final parts = s.split('.');
    return parts.length == 4 && parts.every((p) => (int.tryParse(p) ?? -1) >= 0 && (int.tryParse(p) ?? 256) <= 255);
  }
}
