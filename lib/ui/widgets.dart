import 'package:flutter/material.dart';

import '../models/spool.dart';

/// Parse an RRGGBB or RRGGBBAA hex string (optionally with '#') to a Color.
Color? colorFromHex(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(h)) return null;
  final rgb = int.parse(h.substring(0, 6), radix: 16);
  final a = h.length == 8 ? int.parse(h.substring(6, 8), radix: 16) : 0xFF;
  return Color((a << 24) | rgb);
}

class ColorDot extends StatelessWidget {
  const ColorDot(this.hex, {super.key, this.size = 32});

  final String? hex;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(hex);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c ?? Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: c == null ? Icon(Icons.question_mark, size: size * 0.5) : null,
    );
  }
}

class RemainingBar extends StatelessWidget {
  const RemainingBar(this.spool, {super.key});

  final Spool spool;

  @override
  Widget build(BuildContext context) {
    final pct = spool.remainingPercent;
    final color = pct > 50 ? Colors.green : (pct > 20 ? Colors.orange : Colors.red);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(value: pct / 100, minHeight: 6, color: color),
    );
  }
}

class SpoolTile extends StatelessWidget {
  const SpoolTile(this.spool, {super.key, this.onTap, this.trailing});

  final Spool spool;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = [
      if (spool.colorName != null && spool.colorName!.isNotEmpty) spool.colorName!,
      '${spool.netWeight.round()} g left',
      if (spool.location != null && spool.location!.isNotEmpty) spool.location!,
    ];
    return ListTile(
      onTap: onTap,
      leading: ColorDot(spool.rgba),
      title: Row(children: [
        if (spool.spoolNumber != null)
          Text('#${spool.spoolNumber} ', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        Expanded(child: Text(spool.displayName, overflow: TextOverflow.ellipsis)),
        if (spool.tagId != null && spool.tagId!.isNotEmpty) const Icon(Icons.nfc, size: 16),
      ]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(subtitleParts.join(' · ')),
        const SizedBox(height: 4),
        RemainingBar(spool),
      ]),
      trailing: trailing,
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'OK'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    ),
  );
  return r ?? false;
}

/// Prompt for an integer (e.g. a weight in grams).
Future<int?> promptInt(BuildContext context, String title, {String? label, int? initial}) async {
  final ctrl = TextEditingController(text: initial?.toString() ?? '');
  final r = await showDialog<int>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, suffixText: 'g'),
        onSubmitted: (v) => Navigator.pop(c, int.tryParse(v)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, int.tryParse(ctrl.text)), child: const Text('Save')),
      ],
    ),
  );
  return r;
}
