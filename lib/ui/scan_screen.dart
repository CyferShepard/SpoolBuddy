import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../data/spool_store.dart';
import '../models/spool.dart';
import '../tags/tag_models.dart';
import 'assign_flow.dart';
import 'nfc_dialogs.dart';
import 'spool_detail_screen.dart';
import 'spool_form_screen.dart';
import 'widgets.dart';

/// Scan a spool tag: open the matching spool, or add/link a new one.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  TagReadResult? _result;
  Spool? _match;

  Future<void> _scan() async {
    final res = await runNfcAction(context, 'Hold a spool tag to the back of your phone', (nfc) => nfc.readTag());
    if (res == null || !mounted) return;
    final match = await context.read<AppDatabase>().getSpoolByTag(res.tagId);
    setState(() {
      _result = res;
      _match = match;
    });
  }

  Future<void> _addFromTag() async {
    final r = _result!;
    final t = r.spool;
    final input = SpoolInput(
      tagId: r.tagId,
      tagType: r.tagType == TagType.unknown ? null : r.tagType,
      dataOrigin: t?.dataOrigin,
      material: t?.material ?? 'PLA',
      subtype: t?.subtype,
      colorName: t?.colorName,
      rgba: t?.rgba,
      brand: t?.brand,
      labelWeight: t?.labelWeight ?? 1000,
      coreWeight: t?.coreWeight ?? 250,
      weightNew: t?.weightNew,
      slicerFilament: t?.slicerFilament,
      slicerFilamentName: t?.slicerFilamentName,
      note: t?.note,
    );
    final created = await Navigator.push<Spool>(
        context, MaterialPageRoute(builder: (_) => SpoolFormScreen(initial: input)));
    if (created != null && mounted) setState(() => _match = created);
  }

  Future<void> _linkExisting() async {
    final r = _result!;
    final store = context.read<SpoolStore>();
    final untagged = await context.read<AppDatabase>().getUntaggedSpools();
    if (!mounted) return;
    if (untagged.isEmpty) {
      showSnack(context, 'All active spools already have tags.');
      return;
    }
    final picked = await showModalBottomSheet<Spool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, scroll) => ListView(controller: scroll, children: [
          const ListTile(title: Text('Link tag to spool')),
          for (final s in untagged) SpoolTile(s, onTap: () => Navigator.pop(c, s)),
        ]),
      ),
    );
    if (picked == null) return;
    await store.linkTag(picked.id, r.tagId, tagType: r.tagType, dataOrigin: 'nfc_link');
    if (mounted) setState(() => _match = store.byId(picked.id));
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final match = _match == null ? null : context.watch<SpoolStore>().byId(_match!.id);
    final t = r?.spool;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan tag')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20)),
            onPressed: _scan,
            icon: const Icon(Icons.nfc, size: 32),
            label: const Text('Scan spool tag', style: TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text('Supports SpoolEase, OpenSpool, OpenTag3D, OpenPrintTag\nand Bambu Lab RFID tags',
              textAlign: TextAlign.center),
        ),
        if (r != null) ...[
          const Divider(height: 40),
          Text('Tag', style: Theme.of(context).textTheme.titleMedium),
          Text('${r.tagType} · ${r.nfcType} · UID ${r.uid}'),
          if (t != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              ColorDot(t.rgba),
              const SizedBox(width: 12),
              Expanded(
                child: Text([t.brand, t.material, t.subtype, t.colorName]
                    .whereType<String>()
                    .where((s) => s.isNotEmpty)
                    .join(' · ')),
              ),
            ]),
            if (t.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(t.note!)),
          ],
          const SizedBox(height: 16),
          if (match != null) ...[
            Text('Matched spool', style: Theme.of(context).textTheme.titleMedium),
            Card(
              child: SpoolTile(
                match,
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => SpoolDetailScreen(spoolId: match.id))),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.scale),
                label: const Text('Weigh'),
                onPressed: () async {
                  final g = await promptInt(context, 'Weigh spool',
                      label: 'Gross weight (filament + empty spool)', initial: match.grossWeight.round());
                  if (g != null && context.mounted) {
                    await context.read<SpoolStore>().setWeight(match.id, g);
                  }
                },
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.print),
                label: const Text('Assign to AMS'),
                onPressed: () => assignSpoolFlow(context, match),
              ),
            ]),
          ] else ...[
            const Text('This tag is not in your inventory.'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                  onPressed: _addFromTag, icon: const Icon(Icons.add), label: const Text('Add as new spool')),
              OutlinedButton.icon(
                  onPressed: _linkExisting, icon: const Icon(Icons.link), label: const Text('Link to existing')),
            ]),
          ],
        ],
      ]),
    );
  }
}
