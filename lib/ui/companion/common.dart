import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bambuddy/api_models.dart';
import '../../bambuddy/bambuddy_store.dart';
import '../widgets.dart' show colorFromHex;

/// A spool seen from the side: filament colour with a hub, like the kiosk's.
class SpoolDisc extends StatelessWidget {
  const SpoolDisc(this.rgba, {super.key, this.size = 48, this.empty = false});

  final String? rgba;
  final double size;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = empty ? null : colorFromHex(rgba);
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c ?? Colors.transparent,
          border: Border.all(
            // Dark filament would vanish on the dark theme; outline it instead.
            color: c == null || c.computeLuminance() < 0.08 ? scheme.outline : Color.lerp(c, Colors.black, 0.25)!,
            width: size * 0.06,
          ),
        ),
        child: Center(
          child: Container(
            width: size * 0.3,
            height: size * 0.3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c == null ? Colors.transparent : scheme.surface,
              border: c == null ? Border.all(color: scheme.outlineVariant) : null,
            ),
          ),
        ),
      ),
    );
  }
}

class RemainingBar extends StatelessWidget {
  const RemainingBar(this.fraction, {super.key, this.height = 6});

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = fraction > 0.5 ? Colors.green : (fraction > 0.2 ? Colors.orange : Colors.red);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(value: fraction, minHeight: height, color: color),
    );
  }
}

class BSpoolTile extends StatelessWidget {
  const BSpoolTile(this.spool, {super.key, this.onTap, this.trailing, this.slots = const []});

  final BSpool spool;
  final VoidCallback? onTap;
  final Widget? trailing;
  final List<String> slots;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final sub = [
      if (spool.displayColorName != null) spool.displayColorName!,
      '${spool.remaining.round()} g',
      ...slots,
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SpoolDisc(spool.rgba, size: 44),
      title: Text(spool.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleMedium),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        RemainingBar(spool.remainingFraction, height: 4),
      ]),
      // Same width with or without the tag icon, so the fill bars line up.
      trailing: trailing ?? SizedBox(width: 24, child: spool.hasTag ? const Icon(Icons.nfc, size: 18) : null),
    );
  }
}

void snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// Pick a spool from Bambuddy's inventory, with search.
Future<BSpool?> pickSpool(BuildContext context, {String title = 'Choose spool'}) {
  final store = context.read<BambuddyStore>();
  if (store.spools.isEmpty) store.refreshSpools();
  return showModalBottomSheet<BSpool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider.value(value: store, child: _SpoolPicker(title: title)),
  );
}

class _SpoolPicker extends StatefulWidget {
  const _SpoolPicker({required this.title});
  final String title;

  @override
  State<_SpoolPicker> createState() => _SpoolPickerState();
}

class _SpoolPickerState extends State<_SpoolPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final q = _q.toLowerCase();
    final list = store.spools
        .where((s) => q.isEmpty || '${s.title} ${s.colorName ?? ''} #${s.id}'.toLowerCase().contains(q))
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SearchBar(
            hintText: 'Search brand, material, colour',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        const SizedBox(height: 8),
        if (store.spoolsLoading && store.spools.isEmpty) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemCount: list.length,
            itemBuilder: (_, i) => BSpoolTile(list[i], onTap: () => Navigator.pop(context, list[i])),
          ),
        ),
      ]),
    );
  }
}

/// Ask for a weighed gross weight (spool + filament) in grams.
Future<double?> askWeight(BuildContext context, BSpool spool) async {
  final ctrl = TextEditingController(text: (spool.remaining + spool.coreWeight).round().toString());
  return showDialog<double>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Weigh spool'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Put the spool on a scale and enter the total weight. '
            'The empty spool (${spool.coreWeight} g) is subtracted.'),
        const SizedBox(height: 16),
        TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Total weight', suffixText: 'g', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(c, double.tryParse(v.replaceAll(',', '.'))),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(c, double.tryParse(ctrl.text.replaceAll(',', '.'))),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Assign [spool] to an AMS slot: wait for it to be loaded and use the slot it
/// goes into, or let the user pick the slot by hand.
Future<void> assignToAms(BuildContext context, BSpool spool) async {
  final store = context.read<BambuddyStore>();
  if (store.printers.isEmpty) await store.refreshPrinters();
  if (!context.mounted) return;
  if (store.printers.isEmpty) {
    snack(context, store.printerError ?? 'No printers in Bambuddy');
    return;
  }
  final choice = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangeNotifierProvider.value(value: store, child: _LoadWaitDialog(spool: spool)),
  );
  if (!context.mounted || choice == null) return;
  final target = choice is (int, int, int)
      ? choice
      : await showModalBottomSheet<(int, int, int)>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => ChangeNotifierProvider.value(value: store, child: _SlotPicker(spool: spool)),
        );
  if (target == null || !context.mounted) return;
  try {
    final msg = await store.assign(spool, target.$1, target.$2, target.$3);
    if (context.mounted) snack(context, msg);
  } catch (e) {
    if (context.mounted) snack(context, 'Assign failed: $e');
  }
}

/// Polls the printer until a slot goes from empty to holding a spool, then
/// closes with (printerId, amsId, trayId). Closes with [_manual] for the picker.
class _LoadWaitDialog extends StatefulWidget {
  const _LoadWaitDialog({required this.spool});
  final BSpool spool;

  @override
  State<_LoadWaitDialog> createState() => _LoadWaitDialogState();
}

const _manual = 'manual';

class _LoadWaitDialogState extends State<_LoadWaitDialog> {
  late final BambuddyStore _store = context.read<BambuddyStore>();
  Timer? _timer;
  BPrinterStatus? _last;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    await _store.refreshStatus();
    _polling = false;
    final now = _store.status;
    if (!mounted || now == null) return;
    // Compare with the previous poll, not the start, so taking a spool out and
    // loading this one into the same slot is still seen.
    final prev = _last;
    _last = now;
    if (prev == null || prev.id != now.id) return;
    final loaded = newlyLoadedSlots(prev, now);
    if (loaded.isNotEmpty) {
      _timer?.cancel();
      Navigator.pop(context, (now.id, loaded.first.$1, loaded.first.$2));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final status = store.status;
    final printer = status?.name ?? store.printers.firstOrNull?.name ?? 'the printer';
    final offline = status != null && !status.connected;
    return AlertDialog(
      icon: SpoolDisc(widget.spool.rgba, size: 72),
      title: const Text('Waiting for filament'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          'Load ${widget.spool.title} into an empty slot on $printer. '
          "It's assigned to the slot it goes into.",
          textAlign: TextAlign.center,
          style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        if (offline)
          Text('$printer is offline', style: t.bodyMedium?.copyWith(color: scheme.error))
        else
          const LinearProgressIndicator(),
      ]),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.pop(context, _manual),
          icon: const Icon(Icons.touch_app_outlined),
          label: const Text('Assign manually'),
        ),
      ],
    );
  }
}

class _SlotPicker extends StatelessWidget {
  const _SlotPicker({required this.spool});
  final BSpool spool;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final status = store.status;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (context, scroll) => ListView(controller: scroll, padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(
          leading: SpoolDisc(spool.rgba, size: 40),
          title: Text('Assign ${spool.title}'),
          subtitle: const Text('Choose a slot'),
        ),
        if (store.printers.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: [for (final p in store.printers) ButtonSegment(value: p.id, label: Text(p.name))],
              selected: {store.selectedPrinterId ?? store.printers.first.id},
              onSelectionChanged: (s) => store.selectPrinter(s.first),
            ),
          ),
        if (status == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (status != null && !status.connected)
          const ListTile(leading: Icon(Icons.cloud_off), title: Text('Printer is offline')),
        if (status != null)
          for (final unit in status.ams) ...[
            ListTile(
              dense: true,
              title: Text(unit.label, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final t in unit.trays)
              _slotTile(context, store, label: unit.slotLabel(t), tray: t, amsId: unit.id, trayId: t.id),
          ],
        if (status != null)
          for (final t in status.vtTrays)
            _slotTile(context, store,
                label: externalLabel(t.id, status.vtTrays.length, single: 'External spool'),
                tray: t,
                amsId: externalAmsId,
                trayId: externalSlotIndex(t.id)),
      ]),
    );
  }

  Widget _slotTile(BuildContext context, BambuddyStore store,
      {required String label, required BTray tray, required int amsId, required int trayId}) {
    final assigned = store.spoolById(store.assignedSpoolId(amsId, trayId));
    return ListTile(
      leading: SpoolDisc(tray.color ?? assigned?.rgba, size: 36, empty: tray.isEmpty && assigned == null),
      title: Text(label),
      subtitle: Text(
        assigned != null
            ? 'Assigned: ${assigned.title}'
            : tray.isEmpty
                ? 'Empty'
                : [tray.subBrands ?? tray.type, if (tray.remain != null && tray.remain! >= 0) '${tray.remain}%']
                    .whereType<String>()
                    .join(' · '),
      ),
      onTap: () => Navigator.pop(context, (store.selectedPrinterId!, amsId, trayId)),
    );
  }
}
