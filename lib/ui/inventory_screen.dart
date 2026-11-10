import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/spool_store.dart';
import '../models/spool.dart';
import 'spool_detail_screen.dart';
import 'spool_form_screen.dart';
import 'widgets.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String _query = '';
  bool _showArchived = false;
  String? _material;

  bool _matches(Spool s) {
    if (s.isArchived != _showArchived) return false;
    if (_material != null && s.material != _material) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return [s.material, s.subtype, s.brand, s.colorName, s.location, s.note, '#${s.spoolNumber}']
        .any((f) => f != null && f.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SpoolStore>();
    final materials = store.spools.map((s) => s.material).toSet().toList()..sort();
    final list = store.spools.where(_matches).toList();
    final active = store.spools.where((s) => !s.isArchived);
    final totalKg = active.fold<double>(0, (a, s) => a + s.netWeight) / 1000;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show active' : 'Show archived',
            icon: Icon(_showArchived ? Icons.inventory_2 : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add spool'),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SpoolFormScreen())),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search material, brand, color, location…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text(
              _showArchived
                  ? '${list.length} archived'
                  : '${active.length} spools · ${totalKg.toStringAsFixed(1)} kg remaining',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(child: Text(store.spools.isEmpty ? 'No spools yet. Add one or scan a tag.' : 'No matches'))
              : RefreshIndicator(
                  onRefresh: store.refresh,
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => SpoolTile(
                      list[i],
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => SpoolDetailScreen(spoolId: list[i].id)),
                      ),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}
