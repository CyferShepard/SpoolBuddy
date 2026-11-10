import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bambuddy/bambuddy_store.dart';
import 'common.dart';
import 'spool_page.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  String _q = '';
  String? _material;
  bool _inAms = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<BambuddyStore>();
    if (store.spools.isEmpty) store.refreshSpools();
    // Slot labels in the list come from the selected printer's assignments.
    if (store.printers.isEmpty) store.refreshPrinters();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final materials = store.spools.map((s) => s.material).toSet().toList()..sort();
    final q = _q.toLowerCase();
    final list = store.spools
        .where((s) => _material == null || s.material == _material)
        .where((s) => !_inAms || store.slotsOf(s.id).isNotEmpty)
        .where((s) => q.isEmpty || '${s.title} ${s.colorName ?? ''} ${s.storageLocation ?? ''} #${s.id}'.toLowerCase().contains(q))
        .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: SearchBar(
          hintText: 'Search spools',
          leading: const Icon(Icons.search),
          onChanged: (v) => setState(() => _q = v.trim()),
        ),
      ),
      SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                label: const Text('All'),
                selected: _material == null && !_inAms,
                onSelected: (_) => setState(() {
                  _material = null;
                  _inAms = false;
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                label: const Text('In AMS'),
                selected: _inAms,
                onSelected: (sel) => setState(() => _inAms = sel),
              ),
            ),
            for (final m in materials)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(
                  label: Text(m),
                  selected: _material == m,
                  onSelected: (sel) => setState(() => _material = sel ? m : null),
                ),
              ),
          ],
        ),
      ),
      if (store.spoolsLoading) const LinearProgressIndicator(minHeight: 2),
      if (store.spoolsError != null)
        ListTile(leading: const Icon(Icons.error_outline), title: Text(store.spoolsError!)),
      Expanded(
        child: RefreshIndicator(
          onRefresh: store.refreshSpools,
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 88), // clear of the add button
            itemCount: list.length,
            itemBuilder: (_, i) => BSpoolTile(
              list[i],
              slots: store.slotsOf(list[i].id),
              onTap: () => openSpool(context, list[i].id),
            ),
          ),
        ),
      ),
    ]);
  }
}
