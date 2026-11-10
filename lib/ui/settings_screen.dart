import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import 'companion_pair_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final db = context.read<AppDatabase>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        FutureBuilder(
          future: db.getSetting(AppDatabase.defaultCoreWeightKey),
          builder: (context, snap) {
            final value = int.tryParse(snap.data ?? '') ?? 250;
            return ListTile(
              leading: const Icon(Icons.scale),
              title: const Text('Default empty spool weight'),
              subtitle: Text('$value g · used when a spool has no empty weight set'),
              onTap: () async {
                final v = await promptInt(context, 'Default empty spool weight', initial: value);
                if (v != null) {
                  await db.setSetting(AppDatabase.defaultCoreWeightKey, '$v');
                  if (mounted) setState(() {});
                }
              },
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('Bambuddy companion'),
          subtitle: const Text('Use this phone as a SpoolBuddy for Bambuddy'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CompanionPairScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.album_outlined),
          title: const Text('Empty spool weights'),
          subtitle: const Text('Catalog of empty spool weights by brand'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SpoolCatalogScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Filament colors'),
          subtitle: const Text('Catalog of colors by manufacturer'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ColorCatalogScreen())),
        ),
        const AboutListTile(
          icon: Icon(Icons.info_outline),
          applicationName: 'SpoolBuddy',
          aboutBoxChildren: [
            Text('Standalone Android port of SpoolBuddy: filament inventory, NFC spool tags and '
                'Bambu Lab AMS integration over LAN MQTT.'),
          ],
        ),
      ]),
    );
  }
}

class SpoolCatalogScreen extends StatefulWidget {
  const SpoolCatalogScreen({super.key});

  @override
  State<SpoolCatalogScreen> createState() => _SpoolCatalogScreenState();
}

class _SpoolCatalogScreenState extends State<SpoolCatalogScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await context.read<AppDatabase>().getSpoolCatalog();
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _edit([Map<String, Object?>? row]) async {
    final name = TextEditingController(text: row?['name'] as String?);
    final weight = TextEditingController(text: row?['weight']?.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(row == null ? 'Add entry' : 'Edit entry'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (Brand - Type)')),
          TextField(
            controller: weight,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Empty weight', suffixText: 'g'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    final w = int.tryParse(weight.text.trim());
    if (ok != true || name.text.trim().isEmpty || w == null || !mounted) return;
    final db = context.read<AppDatabase>();
    if (row == null) {
      await db.addSpoolCatalogEntry(name.text.trim(), w);
    } else {
      await db.updateSpoolCatalogEntry(row['id'] as int, name.text.trim(), w);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final db = context.read<AppDatabase>();
    return Scaffold(
      appBar: AppBar(title: const Text('Empty spool weights'), actions: [
        IconButton(
          tooltip: 'Reset to defaults',
          icon: const Icon(Icons.restore),
          onPressed: () async {
            if (await confirm(context, 'Reset catalog?', 'Custom entries will be removed.', action: 'Reset')) {
              await db.resetSpoolCatalog();
              await _load();
            }
          },
        ),
      ]),
      floatingActionButton: FloatingActionButton(onPressed: _edit, child: const Icon(Icons.add)),
      body: ListView.builder(
        itemCount: _rows.length,
        itemBuilder: (_, i) {
          final r = _rows[i];
          return ListTile(
            title: Text('${r['name']}'),
            trailing: Text('${r['weight']} g'),
            onTap: () => _edit(r),
            onLongPress: () async {
              if (await confirm(context, 'Delete entry?', '${r['name']}', action: 'Delete')) {
                await db.deleteSpoolCatalogEntry(r['id'] as int);
                await _load();
              }
            },
          );
        },
      ),
    );
  }
}

class ColorCatalogScreen extends StatefulWidget {
  const ColorCatalogScreen({super.key});

  @override
  State<ColorCatalogScreen> createState() => _ColorCatalogScreenState();
}

class _ColorCatalogScreenState extends State<ColorCatalogScreen> {
  List<Map<String, Object?>> _rows = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await context.read<AppDatabase>().getColorCatalog();
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _add() async {
    final mfr = TextEditingController();
    final name = TextEditingController();
    final hex = TextEditingController();
    final material = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add color'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: mfr, decoration: const InputDecoration(labelText: 'Manufacturer')),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Color name')),
          TextField(controller: hex, decoration: const InputDecoration(labelText: 'Hex (#RRGGBB)')),
          TextField(controller: material, decoration: const InputDecoration(labelText: 'Material (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final h = hex.text.trim().replaceFirst('#', '');
    if (mfr.text.trim().isEmpty || name.text.trim().isEmpty || colorFromHex(h) == null) {
      showSnack(context, 'Manufacturer, name and a valid hex color are required');
      return;
    }
    await context.read<AppDatabase>().addColorCatalogEntry(
        mfr.text.trim(), name.text.trim(), '#${h.toUpperCase()}', material.text.trim().isEmpty ? null : material.text.trim());
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final db = context.read<AppDatabase>();
    final q = _q.toLowerCase();
    final rows = _rows
        .where((r) => '${r['manufacturer']} ${r['color_name']} ${r['material'] ?? ''}'.toLowerCase().contains(q))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Filament colors'), actions: [
        IconButton(
          tooltip: 'Reset to defaults',
          icon: const Icon(Icons.restore),
          onPressed: () async {
            if (await confirm(context, 'Reset colors?', 'Custom colors will be removed.', action: 'Reset')) {
              await db.resetColorCatalog();
              await _load();
            }
          },
        ),
      ]),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), border: OutlineInputBorder(), isDense: true),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i];
              return ListTile(
                leading: ColorDot(r['hex_color'] as String?),
                title: Text('${r['color_name']}'),
                subtitle: Text('${r['manufacturer']}${r['material'] != null ? ' · ${r['material']}' : ''}'),
                trailing: Text('${r['hex_color']}'),
                onLongPress: () async {
                  if (await confirm(context, 'Delete color?', '${r['color_name']}', action: 'Delete')) {
                    await db.deleteColorCatalogEntry(r['id'] as int);
                    await _load();
                  }
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
