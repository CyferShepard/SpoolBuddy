import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/printer.dart';
import '../models/spool.dart';
import '../printers/printer_manager.dart';
import 'widgets.dart';

String slotLabel(AmsUnit unit, AmsTray tray) => unit.isHt ? unit.label : '${unit.label}${tray.trayId + 1}';

/// Choose a connected printer and AMS slot, then assign [spool] to it.
Future<void> assignSpoolFlow(BuildContext context, Spool spool) async {
  final pm = context.read<PrinterManager>();
  final connected = pm.printers.where((p) => pm.connection(p.serial)?.connected ?? false).toList();
  if (connected.isEmpty) {
    showSnack(context, 'No printer connected. Connect one in the Printers tab.');
    return;
  }
  final target = await showModalBottomSheet<(String, int, int)>(
    context: context,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (c, scroll) => ListView(controller: scroll, children: [
        for (final p in connected) ...[
          ListTile(title: Text(p.displayName, style: Theme.of(c).textTheme.titleMedium)),
          for (final u in pm.connection(p.serial)!.state.amsUnits)
            for (final t in u.trays)
              ListTile(
                leading: ColorDot(t.trayColor, size: 28),
                title: Text(slotLabel(u, t)),
                subtitle: Text(t.isEmpty ? 'Empty' : [t.trayType, t.traySubBrands].whereType<String>().join(' · ')),
                onTap: () => Navigator.pop(c, (p.serial, u.id, t.trayId)),
              ),
          ListTile(
            leading: ColorDot(pm.connection(p.serial)!.state.vtTray?.trayColor, size: 28),
            title: const Text('External spool'),
            onTap: () => Navigator.pop(c, (p.serial, 255, 0)),
          ),
        ],
      ]),
    ),
  );
  if (target == null || !context.mounted) return;
  await assignSpoolToSlot(context, spool, target.$1, target.$2, target.$3);
}

Future<void> assignSpoolToSlot(BuildContext context, Spool spool, String serial, int amsId, int trayId) async {
  try {
    final r = await context.read<PrinterManager>().assignSpool(serial, amsId, trayId, spool);
    if (context.mounted) showSnack(context, r.message);
  } catch (e) {
    if (context.mounted) showSnack(context, 'Assign failed: $e');
  }
}
