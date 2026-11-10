import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../data/spool_store.dart';
import '../models/spool.dart';
import '../tags/bambulab.dart';
import 'widgets.dart';

const materials = ['PLA', 'PETG', 'ABS', 'TPU', 'ASA', 'PC', 'PA', 'PVA', 'HIPS', 'PA-CF', 'PETG-CF', 'PLA-CF'];
const quickColors = [
  ('Black', '000000'), ('White', 'FFFFFF'), ('Gray', '808080'), ('Red', 'FF0000'), //
  ('Orange', 'FFA500'), ('Yellow', 'FFFF00'), ('Green', '00AE42'), ('Blue', '0066FF'),
  ('Purple', '8B00FF'), ('Pink', 'FF69B4'), ('Brown', '8B4513'),
];

/// Create or edit a spool. Pass [spoolId] to edit, or [initial] to prefill a new spool.
class SpoolFormScreen extends StatefulWidget {
  const SpoolFormScreen({super.key, this.spoolId, this.initial});

  final String? spoolId;
  final SpoolInput? initial;

  @override
  State<SpoolFormScreen> createState() => _SpoolFormScreenState();
}

class _SpoolFormScreenState extends State<SpoolFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final SpoolInput _in;
  late final Map<String, TextEditingController> _c;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.spoolId == null ? null : context.read<SpoolStore>().byId(widget.spoolId!);
    _in = existing != null ? SpoolInput.fromSpool(existing) : (widget.initial ?? SpoolInput());
    _c = {
      'subtype': TextEditingController(text: _in.subtype),
      'brand': TextEditingController(text: _in.brand),
      'colorName': TextEditingController(text: _in.colorName),
      'rgba': TextEditingController(text: _in.rgba),
      'labelWeight': TextEditingController(text: _in.labelWeight?.toString()),
      'coreWeight': TextEditingController(text: _in.coreWeight?.toString()),
      'weightNew': TextEditingController(text: _in.weightNew?.toString()),
      'slicer': TextEditingController(text: _in.slicerFilament),
      'location': TextEditingController(text: _in.location),
      'note': TextEditingController(text: _in.note),
    };
    _c['rgba']!.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _t(String k) => _c[k]!.text.trim().isEmpty ? null : _c[k]!.text.trim();
  int? _n(String k) => int.tryParse(_c[k]!.text.trim());

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    var rgba = _t('rgba')?.replaceFirst('#', '').toUpperCase();
    if (rgba != null && rgba.length == 6) rgba = '${rgba}FF';
    final slicer = _t('slicer');
    _in
      ..subtype = _t('subtype')
      ..brand = _t('brand')
      ..colorName = _t('colorName')
      ..rgba = rgba
      ..labelWeight = _n('labelWeight')
      ..coreWeight = _n('coreWeight')
      ..weightNew = _n('weightNew')
      ..slicerFilament = slicer
      ..slicerFilamentName = BambuLab.materials[slicer]?.$1 ?? _in.slicerFilamentName
      ..location = _t('location')
      ..note = _t('note');
    final store = context.read<SpoolStore>();
    final nav = Navigator.of(context);
    if (widget.spoolId != null) {
      await store.update(widget.spoolId!, _in);
      nav.pop();
    } else {
      final s = await store.create(_in);
      nav.pop(s);
    }
  }

  Future<void> _pickCoreWeight() async {
    final db = context.read<AppDatabase>();
    final catalog = await db.getSpoolCatalog();
    if (!mounted) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _SearchList(
        title: 'Empty spool weight',
        items: [for (final e in catalog) ('${e['name']}', '${e['weight']} g', e['weight'] as int)],
      ),
    );
    if (picked != null) _c['coreWeight']!.text = '$picked';
  }

  Future<void> _pickColor() async {
    final db = context.read<AppDatabase>();
    final catalog = await db.getColorCatalog();
    if (!mounted) return;
    final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _SearchList(
        title: 'Color',
        items: [
          for (final (n, h) in quickColors) (n, 'Basic', (n, h)),
          for (final e in catalog)
            (
              '${e['color_name']}',
              '${e['manufacturer']}${e['material'] != null ? ' · ${e['material']}' : ''}',
              ('${e['color_name']}', (e['hex_color'] as String).replaceFirst('#', '')),
            ),
        ],
        leading: (item) => ColorDot(item.$2, size: 28),
      ),
    );
    if (picked != null) {
      _c['colorName']!.text = picked.$1;
      _c['rgba']!.text = picked.$2.toUpperCase();
    }
  }

  Future<void> _pickPreset() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _SearchList(
        title: 'Slicer filament preset',
        items: [for (final e in BambuLab.materials.entries) (e.value.$1, e.key, e.key)],
      ),
    );
    if (picked != null) {
      _c['slicer']!.text = picked;
      final mat = BambuLab.materials[picked]!.$2;
      if (materials.contains(mat)) setState(() => _in.material = mat);
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    InputDecoration dec(String label, {String? suffix, Widget? action}) => InputDecoration(
          labelText: label,
          suffixText: suffix,
          suffixIcon: action,
          border: const OutlineInputBorder(),
        );
    final materialOptions = {...materials, _in.material}.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.spoolId == null ? 'New spool' : 'Edit spool'),
        actions: [
          TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            key: ValueKey(_in.material), // re-init when a preset changes the material
            initialValue: _in.material,
            decoration: dec('Material'),
            items: [for (final m in materialOptions) DropdownMenuItem(value: m, child: Text(m))],
            onChanged: (v) => setState(() => _in.material = v ?? _in.material),
          ),
          gap,
          TextFormField(controller: _c['subtype'], decoration: dec('Variant (e.g. Basic, Matte, Silk)')),
          gap,
          TextFormField(controller: _c['brand'], decoration: dec('Brand')),
          gap,
          Row(children: [
            Padding(padding: const EdgeInsets.only(right: 12), child: ColorDot(_c['rgba']!.text, size: 40)),
            Expanded(
              child: TextFormField(
                controller: _c['colorName'],
                decoration: dec('Color name', action: IconButton(icon: const Icon(Icons.palette), onPressed: _pickColor)),
              ),
            ),
          ]),
          gap,
          TextFormField(
            controller: _c['rgba'],
            decoration: dec('Color hex (RRGGBB or RRGGBBAA)'),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              return colorFromHex(v.trim()) == null ? 'Invalid hex color' : null;
            },
          ),
          gap,
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _c['labelWeight'],
                keyboardType: TextInputType.number,
                decoration: dec('Filament weight', suffix: 'g'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _c['coreWeight'],
                keyboardType: TextInputType.number,
                decoration: dec('Empty spool', action: IconButton(icon: const Icon(Icons.list), onPressed: _pickCoreWeight)),
              ),
            ),
          ]),
          gap,
          TextFormField(
            controller: _c['weightNew'],
            keyboardType: TextInputType.number,
            decoration: dec('Weight when new (optional)', suffix: 'g'),
          ),
          gap,
          TextFormField(
            controller: _c['slicer'],
            decoration: dec('Slicer filament ID (e.g. GFA00)',
                action: IconButton(icon: const Icon(Icons.search), onPressed: _pickPreset)),
          ),
          gap,
          TextFormField(controller: _c['location'], decoration: dec('Location')),
          gap,
          TextFormField(controller: _c['note'], decoration: dec('Note'), maxLines: 3),
        ]),
      ),
    );
  }
}

/// Searchable bottom-sheet list of (title, subtitle, value) items.
class _SearchList<T> extends StatefulWidget {
  const _SearchList({required this.title, required this.items, this.leading});

  final String title;
  final List<(String, String, T)> items;
  final Widget Function(T)? leading;

  @override
  State<_SearchList<T>> createState() => _SearchListState<T>();
}

class _SearchListState<T> extends State<_SearchList<T>> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final items =
        widget.items.where((i) => i.$1.toLowerCase().contains(q) || i.$2.toLowerCase().contains(q)).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: InputDecoration(
              labelText: widget.title,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemCount: items.length,
            itemBuilder: (_, i) => ListTile(
              leading: widget.leading?.call(items[i].$3),
              title: Text(items[i].$1),
              subtitle: Text(items[i].$2),
              onTap: () => Navigator.pop(context, items[i].$3),
            ),
          ),
        ),
      ]),
    );
  }
}
