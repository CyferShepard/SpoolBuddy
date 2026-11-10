import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/spool_store.dart';
import '../models/printer.dart';
import '../models/spool.dart';
import '../printers/printer_connection.dart';
import '../printers/printer_manager.dart';
import 'assign_flow.dart';
import 'printers_screen.dart';
import 'widgets.dart';

class PrinterDetailScreen extends StatelessWidget {
  const PrinterDetailScreen({super.key, required this.serial});

  final String serial;

  @override
  Widget build(BuildContext context) {
    final pm = context.watch<PrinterManager>();
    final spools = context.watch<SpoolStore>();
    final printer = pm.printers.where((p) => p.serial == serial).firstOrNull;
    if (printer == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Printer not found')));
    final conn = pm.connection(serial);
    final s = conn?.state;
    final assignments = pm.assignmentsFor(serial);

    return Scaffold(
      appBar: AppBar(
        title: Text(printer.displayName),
        actions: [
          if (conn?.connected ?? false)
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: conn!.refreshState),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => PrinterFormScreen(printer: printer))),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final nav = Navigator.of(context);
              if (await confirm(context, 'Remove printer?', 'Remove ${printer.displayName} and its slot assignments?',
                  action: 'Remove')) {
                await pm.deletePrinter(serial);
                nav.pop();
              }
            },
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: ListTile(
            leading: Icon(Icons.circle, color: statusColor(conn), size: 14),
            title: Text(statusLabel(conn)),
            subtitle: Text('${printer.serial} · ${printer.ipAddress}'),
            trailing: (conn?.connected ?? false)
                ? null
                : FilledButton(onPressed: () => pm.connect(serial), child: const Text('Connect')),
          ),
        ),
        if (conn?.connected ?? false) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s!.gcodeState ?? 'Unknown', style: Theme.of(context).textTheme.titleMedium),
                if (s.stgCurName != null) Text(s.stgCurName!),
                if (s.gcodeState == 'RUNNING' || s.gcodeState == 'PAUSE') ...[
                  const SizedBox(height: 8),
                  Text(s.subtaskName ?? ''),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: (s.printProgress ?? 0) / 100),
                  const SizedBox(height: 4),
                  Text([
                    '${s.printProgress ?? 0}%',
                    if (s.layerNum != null) 'Layer ${s.layerNum}/${s.totalLayerNum ?? '?'}',
                    if (s.mcRemainingTime != null) '${s.mcRemainingTime} min left',
                  ].join(' · ')),
                ],
              ]),
            ),
          ),
          if (s.amsUnits.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No AMS detected.')),
          for (final unit in s.amsUnits)
            _AmsCard(
                serial: serial, unit: unit, conn: conn!, assignments: assignments, spools: spools, state: s),
          _TrayTile(
            serial: serial,
            label: 'External spool',
            amsId: 255,
            tray: s.vtTray ?? const AmsTray(amsId: 255, trayId: 0),
            conn: conn!,
            spool: spools.byId(assignments[(255, 0)] ?? ''),
            active: s.trayNow == 254, // 254 = external spool, 255 = none
          ),
        ],
      ]),
    );
  }
}

class _AmsCard extends StatelessWidget {
  const _AmsCard({
    required this.serial,
    required this.unit,
    required this.conn,
    required this.assignments,
    required this.spools,
    required this.state,
  });

  final String serial;
  final AmsUnit unit;
  final PrinterConnection conn;
  final Map<(int, int), String> assignments;
  final SpoolStore spools;
  final PrinterState state;

  bool _isActive(AmsTray t) {
    final global = unit.isHt ? 16 + unit.id - 128 : unit.id * 4 + t.trayId;
    return state.trayNow == global || state.trayNowLeft == global || state.trayNowRight == global;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Text(unit.label, style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (unit.extruder != null) Text(unit.extruder == 0 ? 'Right  ' : 'Left  '),
            if (unit.humidity != null) ...[const Icon(Icons.water_drop, size: 16), Text(' ${unit.humidity}%  ')],
            if (unit.temperature != null) ...[
              const Icon(Icons.thermostat, size: 16),
              Text(' ${unit.temperature!.toStringAsFixed(1)}°C'),
            ],
          ]),
        ),
        for (final t in unit.trays)
          _TrayTile(
            serial: serial,
            label: slotLabel(unit, t),
            amsId: unit.id,
            tray: t,
            conn: conn,
            spool: spools.byId(assignments[(unit.id, t.trayId)] ?? ''),
            active: _isActive(t),
          ),
      ]),
    );
  }
}

class _TrayTile extends StatelessWidget {
  const _TrayTile({
    required this.serial,
    required this.label,
    required this.amsId,
    required this.tray,
    required this.conn,
    required this.spool,
    required this.active,
  });

  final String serial;
  final String label;
  final int amsId;
  final AmsTray tray;
  final PrinterConnection conn;
  final Spool? spool;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final pending = conn.pendingAssignments.containsKey((amsId, tray.trayId));
    final reading = conn.state.trayReadingBits != null &&
        amsId <= 3 &&
        (conn.state.trayReadingBits! >> (amsId * 4 + tray.trayId)) & 1 == 1;
    return ListTile(
      leading: ColorDot(tray.isEmpty ? null : tray.trayColor),
      title: Row(children: [
        Text(label),
        if (active) const Padding(padding: EdgeInsets.only(left: 8), child: Chip(label: Text('Active'))),
      ]),
      subtitle: Text([
        if (tray.isEmpty) 'Empty' else [tray.trayType, tray.traySubBrands].whereType<String>().join(' · '),
        if (tray.remain != null && tray.remain! >= 0 && !tray.isEmpty) '${tray.remain}%',
        if (tray.kValue != null) 'K ${tray.kValue!.toStringAsFixed(3)}',
        if (spool != null) 'Spool #${spool!.spoolNumber}',
        if (pending) 'Waiting for spool…',
        if (reading) 'Reading RFID…',
      ].join(' · ')),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        builder: (_) => _TraySheet(serial: serial, label: label, amsId: amsId, tray: tray, spool: spool, pending: pending),
      ),
    );
  }
}

class _TraySheet extends StatelessWidget {
  const _TraySheet({
    required this.serial,
    required this.label,
    required this.amsId,
    required this.tray,
    required this.spool,
    required this.pending,
  });

  final String serial;
  final String label;
  final int amsId;
  final AmsTray tray;
  final Spool? spool;
  final bool pending;

  Future<void> _pickSpool(BuildContext context) async {
    final spools = context.read<SpoolStore>().spools.where((s) => !s.isArchived).toList();
    final picked = await showModalBottomSheet<Spool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (c, scroll) => ListView(controller: scroll, children: [
          for (final s in spools) SpoolTile(s, onTap: () => Navigator.pop(c, s)),
        ]),
      ),
    );
    if (picked == null || !context.mounted) return;
    Navigator.pop(context);
    await assignSpoolToSlot(context, picked, serial, amsId, tray.trayId);
  }

  Future<void> _pickKProfile(BuildContext context) async {
    final pm = context.read<PrinterManager>();
    final conn = pm.connection(serial)!;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final profiles = await conn.getKProfiles(conn.nozzleDiameter());
    if (!context.mounted) return;
    if (profiles.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No K-profiles found on the printer for this nozzle.')));
      return;
    }
    final picked = await showModalBottomSheet<Calibration>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        builder: (c, scroll) => ListView(controller: scroll, children: [
          for (final p in profiles)
            ListTile(
              title: Text(p.name),
              subtitle: Text('K ${p.kValue.toStringAsFixed(3)} · ${p.filamentId}'
                  '${p.extruderId != null ? ' · extruder ${p.extruderId}' : ''}'),
              onTap: () => Navigator.pop(c, p),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    try {
      await pm.applyKProfile(serial, amsId, tray.trayId, picked);
      messenger.showSnackBar(SnackBar(content: Text('K-profile "${picked.name}" applied')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.read<PrinterManager>();
    final conn = pm.connection(serial)!;
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: ColorDot(tray.isEmpty ? null : tray.trayColor),
          title: Text(label, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text(spool != null ? 'Assigned: #${spool!.spoolNumber} ${spool!.displayName}' : 'No spool assigned'),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Assign spool from inventory'),
          onTap: () => _pickSpool(context),
        ),
        if (spool != null || pending)
          ListTile(
            leading: const Icon(Icons.link_off),
            title: Text(pending ? 'Cancel pending assignment' : 'Unassign spool'),
            onTap: () async {
              final nav = Navigator.of(context);
              await pm.unassign(serial, amsId, tray.trayId);
              nav.pop();
            },
          ),
        if (!tray.isEmpty)
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Select K-profile'),
            onTap: () => _pickKProfile(context),
          ),
        if (amsId <= 135)
          ListTile(
            leading: const Icon(Icons.nfc),
            title: const Text('Re-read RFID'),
            onTap: () {
              conn.resetSlot(amsId, tray.trayId);
              Navigator.pop(context);
            },
          ),
      ]),
    );
  }
}
