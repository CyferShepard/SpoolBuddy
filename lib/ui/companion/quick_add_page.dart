import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bambuddy/bambuddy_store.dart';
import '../../bambuddy/companion.dart';
import '../../nfc/nfc_service.dart';
import '../widgets.dart' show colorFromHex;
import 'common.dart';

const _materials = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'PC', 'PA', 'PVA', 'HIPS', 'PLA-CF', 'PETG-CF', 'PA-CF'];
const _swatches = [
  ('Black', '000000'), ('White', 'FFFFFF'), ('Grey', '8E9089'), ('Red', 'C12E1F'), //
  ('Orange', 'FF6A13'), ('Yellow', 'F4EE2A'), ('Green', '00AE42'), ('Blue', '0A2989'),
  ('Purple', '5E43B7'), ('Pink', 'F55A74'), ('Brown', '9D432C'), ('Silver', 'A6A9AA'),
];

/// Create a spool in Bambuddy. With a scanned tag, the fields are pre-filled
/// from whatever the tag says and the tag is linked to the new spool.
class QuickAddPage extends StatefulWidget {
  const QuickAddPage({super.key, this.scan});
  final RawTagScan? scan;

  @override
  State<QuickAddPage> createState() => _QuickAddPageState();
}

class _QuickAddPageState extends State<QuickAddPage> {
  late final _d = widget.scan?.decoded;
  late String _material = (_d?.material?.isNotEmpty ?? false) ? _d!.material!.toUpperCase() : 'PLA';
  late final _subtype = TextEditingController(text: _d?.subtype);
  late final _brand = TextEditingController(text: _d?.brand);
  late final _colorName = TextEditingController(text: _d?.colorName == '(Unknown Color)' ? null : _d?.colorName);
  late final _hex = TextEditingController(text: _d?.rgba?.substring(0, 6));
  late final _label = TextEditingController(text: '${_d?.labelWeight ?? 1000}');
  // Bambu tags carry the filament weight where upstream reads a core weight; use the usual default.
  late final _core = TextEditingController(
      text: '${(_d?.coreWeight != null && widget.scan?.trayUuid == null) ? _d!.coreWeight : 250}');
  late final _nozzle = TextEditingController(text: _d?.nozzleTemp?.toString());
  late final _bed = TextEditingController(text: _d?.bedTemp?.toString());
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _hex.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_subtype, _brand, _colorName, _hex, _label, _core, _nozzle, _bed]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    final hex = _hex.text.trim().replaceFirst('#', '').toUpperCase();
    if (hex.isNotEmpty && colorFromHex(hex) == null) {
      snack(context, 'Colour must be 6 hex digits, e.g. FF0000');
      return;
    }
    setState(() => _saving = true);
    final store = context.read<BambuddyStore>();
    final companion = context.read<BambuddyCompanion>();
    final nav = Navigator.of(context);
    final nozzle = int.tryParse(_nozzle.text.trim());
    final bed = int.tryParse(_bed.text.trim());
    try {
      final spool = await store.createSpool(nozzleTemp: nozzle, {
        'material': _material,
        'subtype': _t(_subtype),
        'brand': _t(_brand),
        'color_name': _t(_colorName),
        'rgba': hex.isEmpty ? null : (hex.length == 6 ? '${hex}FF' : hex),
        'label_weight': int.tryParse(_label.text.trim()) ?? 1000,
        'core_weight': int.tryParse(_core.text.trim()) ?? 250,
        'slicer_filament': _d?.slicerFilament,
        'note': _d?.note,
      });
      final scan = widget.scan;
      if (scan != null) {
        await store.linkTag(spool, tagUid: scan.uidHex, trayUuid: scan.trayUuid);
        await companion.resendLastScan();
      }
      var added = 'Added ${spool.title}';
      try {
        await store.setFilamentTemps(spool, nozzleTemp: nozzle, bedTemp: bed);
      } catch (e) {
        added = "$added, but the temperatures weren't saved: $e";
      }
      if (mounted) snack(context, added);
      nav.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        snack(context, 'Could not add spool: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    InputDecoration dec(String label, {String? suffix}) =>
        InputDecoration(labelText: label, suffixText: suffix, border: const OutlineInputBorder());
    final materials = {..._materials, _material}.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Add spool')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(widget.scan == null ? 'Add spool' : 'Add and link tag'),
          ),
        ),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          SpoolDisc(_hex.text, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _d != null
                  ? 'Filled in from the ${_d.tagType} tag. Check and adjust.'
                  : widget.scan == null
                      ? 'Add a spool without a tag. You can link a tag to it later.'
                      : 'This tag has no spool data. Fill in what you know.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ]),
        gap,
        Text('Material', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in materials)
            ChoiceChip(label: Text(m), selected: _material == m, onSelected: (_) => setState(() => _material = m)),
        ]),
        gap,
        TextField(controller: _brand, decoration: dec('Brand')),
        gap,
        TextField(controller: _subtype, decoration: dec('Variant (Basic, Matte, Silk…)')),
        gap,
        Text('Colour', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (name, hex) in _swatches)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => setState(() {
                _hex.text = hex;
                if (_colorName.text.trim().isEmpty) _colorName.text = name;
              }),
              child: SpoolDisc(hex, size: 40),
            ),
        ]),
        gap,
        Row(children: [
          Expanded(child: TextField(controller: _colorName, decoration: dec('Colour name'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _hex, decoration: dec('Hex', suffix: 'RRGGBB'))),
        ]),
        gap,
        Row(children: [
          Expanded(
            child: TextField(
                controller: _label, keyboardType: TextInputType.number, decoration: dec('Filament', suffix: 'g')),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
                controller: _core, keyboardType: TextInputType.number, decoration: dec('Empty spool', suffix: 'g')),
          ),
        ]),
        gap,
        Row(children: [
          Expanded(
            child: TextField(
                controller: _nozzle, keyboardType: TextInputType.number, decoration: dec('Nozzle', suffix: '°C')),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(controller: _bed, keyboardType: TextInputType.number, decoration: dec('Bed', suffix: '°C')),
          ),
        ]),
      ]),
    );
  }
}
