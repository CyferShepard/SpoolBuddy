import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bambuddy/api_models.dart';
import '../../bambuddy/bambuddy_store.dart';
import 'common.dart';
import 'spool_page.dart';

class AmsPage extends StatefulWidget {
  const AmsPage({super.key});

  @override
  State<AmsPage> createState() => _AmsPageState();
}

class _AmsPageState extends State<AmsPage> {
  @override
  void initState() {
    super.initState();
    final store = context.read<BambuddyStore>();
    if (store.printers.isEmpty) store.refreshPrinters();
    if (store.spools.isEmpty) store.refreshSpools();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final status = store.status;
    final t = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: () async {
        await store.refreshStatus();
        await store.refreshSpools();
      },
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (store.printerError != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(leading: const Icon(Icons.error_outline), title: Text(store.printerError!)),
          ),
        if (status == null && store.printerError == null)
          const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
        if (status != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(
              [
                status.connected ? _stateLabel(status.state) : 'Offline',
                if (status.state == 'RUNNING' && status.subtaskName != null)
                  '${status.subtaskName} · ${status.progress ?? 0}%',
              ].join(' · '),
              style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          if (status.ams.isEmpty && status.vtTrays.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('No AMS reported by this printer.')),
          for (final unit in status.ams) _AmsCard(unit: unit),
          if (status.vtTrays.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text('External', style: t.titleMedium),
                  ),
                  _SlotGrid(children: [
                    for (final tr in status.vtTrays)
                      _SlotTile(
                        label: externalLabel(tr.id, status.vtTrays.length),
                        tray: tr,
                        amsId: externalAmsId,
                        trayId: externalSlotIndex(tr.id),
                      ),
                  ]),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}

String _stateLabel(String? s) => switch (s) {
      'RUNNING' => 'Printing',
      'PAUSE' => 'Paused',
      'FINISH' => 'Finished',
      'FAILED' => 'Failed',
      'PREPARE' => 'Preparing',
      _ => 'Idle',
    };

class _AmsCard extends StatelessWidget {
  const _AmsCard({required this.unit});
  final BAmsUnit unit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(children: [
              Text(unit.label, style: t.titleMedium),
              const Spacer(),
              if (unit.humidity != null || unit.temp != null)
                Chip(
                  avatar: const Icon(Icons.water_drop_outlined, size: 16),
                  label: Text([
                    if (unit.humidity != null) '${unit.humidity}%',
                    if (unit.temp != null) '${unit.temp!.round()}°C',
                  ].join(' · ')),
                  visualDensity: VisualDensity.compact,
                ),
            ]),
          ),
          _SlotGrid(children: [
            for (final tr in unit.trays) _SlotTile(label: unit.slotLabel(tr), tray: tr, amsId: unit.id, trayId: tr.id),
          ]),
        ]),
      ),
    );
  }
}

class _SlotGrid extends StatelessWidget {
  const _SlotGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // Two slots per row on a phone, four when there's room.
        final perRow = box.maxWidth >= 600 ? 4 : 2;
        final w = (box.maxWidth - (perRow - 1) * 8) / perRow;
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in children) SizedBox(width: w, child: c),
        ]);
      });
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.label, required this.tray, required this.amsId, required this.trayId});
  final String label;
  final BTray tray;
  final int amsId;
  final int trayId;

  Future<void> _open(BuildContext context, BSpool? assigned) async {
    final store = context.read<BambuddyStore>();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: SpoolDisc(tray.color ?? assigned?.rgba, size: 40, empty: tray.isEmpty && assigned == null),
            title: Text('Slot $label'),
            subtitle: Text(assigned != null ? assigned.title : (tray.subBrands ?? tray.type ?? 'Empty')),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(assigned == null ? 'Assign spool' : 'Assign a different spool'),
            onTap: () => Navigator.pop(c, 'assign'),
          ),
          if (assigned != null) ...[
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Spool details'),
              onTap: () => Navigator.pop(c, 'details'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('Unassign'),
              onTap: () => Navigator.pop(c, 'unassign'),
            ),
          ],
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!context.mounted) return;
    try {
      switch (choice) {
        case 'assign':
          final spool = await pickSpool(context, title: 'Assign to $label');
          if (spool != null) {
            final msg = await store.assign(spool, store.selectedPrinterId!, amsId, trayId);
            if (context.mounted) snack(context, msg);
          }
        case 'details':
          openSpool(context, assigned!.id);
        case 'unassign':
          await store.unassign(assigned!.id, amsId, trayId);
          if (context.mounted) snack(context, 'Unassigned');
      }
    } catch (e) {
      if (context.mounted) snack(context, 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final assigned = store.spoolById(store.assignedSpoolId(amsId, trayId));
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // Slot tiles are narrow: the variant or colour alone ("Textured Silver") fits where the full title doesn't.
    final short = assigned == null
        ? null
        : [assigned.subtype, assigned.displayColorName].whereType<String>().toSet().join(' ');
    final name = (short != null && short.isNotEmpty ? short : assigned?.title) ??
        (tray.isEmpty ? 'Empty' : (tray.subBrands ?? tray.type ?? 'Unknown'));
    final remain = tray.remain != null && tray.remain! >= 0 ? tray.remain! / 100 : assigned?.remainingFraction;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(context, assigned),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: Column(children: [
            // The AMS reports no colour for spools without a Bambu tag; show the assigned spool's.
            SpoolDisc(tray.color ?? assigned?.rgba, size: 56, empty: tray.isEmpty && assigned == null),
            const SizedBox(height: 8),
            Text(label, style: t.titleSmall),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            Text(
              assigned != null ? '${assigned.remaining.round()} g left' : (tray.isEmpty ? 'Tap to assign' : 'Not assigned'),
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (remain != null) RemainingBar(remain, height: 4) else const SizedBox(height: 4),
          ]),
        ),
      ),
    );
  }
}
