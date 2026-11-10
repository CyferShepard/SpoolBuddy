import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../data/spool_store.dart';
import '../models/spool.dart';
import '../nfc/nfc_service.dart';
import 'assign_flow.dart';
import 'nfc_dialogs.dart';
import 'spool_form_screen.dart';
import 'widgets.dart';

class SpoolDetailScreen extends StatelessWidget {
  const SpoolDetailScreen({super.key, required this.spoolId});

  final String spoolId;

  Future<void> _setWeight(BuildContext context, Spool spool) async {
    final grams = await promptInt(context, 'Weigh spool',
        label: 'Gross weight (filament + empty spool)', initial: spool.grossWeight.round());
    if (grams == null || !context.mounted) return;
    await context.read<SpoolStore>().setWeight(spool.id, grams);
    if (context.mounted) showSnack(context, 'Weight updated');
  }

  Future<void> _writeTag(BuildContext context, Spool spool) async {
    final format = await showDialog<TagWriteFormat>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Tag format'),
        children: [
          for (final f in TagWriteFormat.values)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, f), child: Text(f.label)),
        ],
      ),
    );
    if (format == null || !context.mounted) return;
    final res = await runNfcAction(
        context, 'Hold a blank NTAG tag to the back of your phone', (nfc) => nfc.writeSpool(spool, format));
    if (res == null || !context.mounted) return;
    final store = context.read<SpoolStore>();
    await context.read<AppDatabase>().setEncodeTime(spool.id);
    await store.linkTag(spool.id, res.$2, tagType: format.label);
    if (context.mounted) showSnack(context, 'Tag written and linked');
  }

  Future<void> _linkTag(BuildContext context, Spool spool) async {
    final res = await runNfcAction(context, 'Hold the spool\'s tag to the back of your phone', (nfc) => nfc.readTag());
    if (res == null || !context.mounted) return;
    final store = context.read<SpoolStore>();
    final existing = await context.read<AppDatabase>().getSpoolByTag(res.tagId);
    if (!context.mounted) return;
    if (existing != null && existing.id != spool.id) {
      final ok = await confirm(context, 'Tag already linked',
          'This tag is linked to spool #${existing.spoolNumber} (${existing.displayName}). Move it to this spool?',
          action: 'Move');
      if (!ok) return;
    }
    await store.linkTag(spool.id, res.tagId, tagType: res.tagType, dataOrigin: 'nfc_link');
    if (context.mounted) showSnack(context, 'Tag linked');
  }

  Future<void> _delete(BuildContext context, Spool spool) async {
    final ok = await confirm(context, 'Delete spool?',
        'Spool #${spool.spoolNumber} and its usage history will be permanently deleted. Archive it instead to keep the history.',
        action: 'Delete');
    if (!ok || !context.mounted) return;
    final nav = Navigator.of(context);
    await context.read<SpoolStore>().delete(spool.id);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final spool = context.watch<SpoolStore>().byId(spoolId);
    if (spool == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Spool not found')));
    }
    final store = context.read<SpoolStore>();

    Widget row(String label, String? value) => (value == null || value.isEmpty)
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 140, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.outline))),
              Expanded(child: Text(value)),
            ]),
          );

    return Scaffold(
      appBar: AppBar(
        title: Text('Spool #${spool.spoolNumber ?? ''}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => SpoolFormScreen(spoolId: spool.id))),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'archive') await store.setArchived(spool.id, !spool.isArchived);
              if (v == 'delete' && context.mounted) await _delete(context, spool);
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'archive', child: Text(spool.isArchived ? 'Restore' : 'Archive')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          ColorDot(spool.rgba, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(spool.displayName, style: Theme.of(context).textTheme.titleLarge),
              if (spool.colorName != null) Text(spool.colorName!),
              if (spool.isArchived) const Chip(label: Text('Archived')),
            ]),
          ),
        ]),
        const SizedBox(height: 24),
        Text('${spool.netWeight.round()} g remaining (${spool.remainingPercent.round()}%)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RemainingBar(spool),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: () => _setWeight(context, spool), icon: const Icon(Icons.scale), label: const Text('Weigh')),
          FilledButton.tonalIcon(
              onPressed: () => assignSpoolFlow(context, spool),
              icon: const Icon(Icons.print),
              label: const Text('Assign to AMS')),
          OutlinedButton.icon(
              onPressed: () => _writeTag(context, spool), icon: const Icon(Icons.edit_note), label: const Text('Write tag')),
          OutlinedButton.icon(
              onPressed: () => _linkTag(context, spool), icon: const Icon(Icons.nfc), label: const Text('Link tag')),
        ]),
        const Divider(height: 32),
        row('Material', spool.material),
        row('Variant', spool.subtype),
        row('Brand', spool.brand),
        row('Color', spool.rgba),
        row('Filament weight', spool.labelWeight == null ? null : '${spool.labelWeight} g'),
        row('Empty spool', spool.coreWeight == null ? null : '${spool.coreWeight} g'),
        row('Last weighed', spool.weightCurrent == null ? null : '${spool.weightCurrent} g'),
        row('Used', '${spool.totalUsed.toStringAsFixed(1)} g'),
        row('Slicer preset', [spool.slicerFilament, spool.slicerFilamentName].whereType<String>().join(' · ')),
        row('Location', spool.location),
        row('Tag', spool.tagId == null ? null : '${spool.tagType ?? 'Linked'} (${spool.tagId})'),
        row('Note', spool.note),
        const Divider(height: 32),
        Text('Usage history', style: Theme.of(context).textTheme.titleMedium),
        FutureBuilder(
          future: context.read<AppDatabase>().getUsageHistory(spool.id),
          builder: (context, snap) {
            final rows = snap.data ?? const [];
            if (rows.isEmpty) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No prints logged yet.'));
            }
            return Column(children: [
              for (final r in rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${r['print_name']}'),
                  subtitle: Text(DateTime.fromMillisecondsSinceEpoch((r['timestamp'] as int) * 1000)
                      .toLocal()
                      .toString()
                      .substring(0, 16)),
                  trailing: Text('${(r['weight_used'] as num).toStringAsFixed(1)} g'),
                ),
            ]);
          },
        ),
      ]),
    );
  }
}
