import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bambuddy/api_models.dart';
import '../../bambuddy/bambuddy_store.dart';
import '../../bambuddy/companion.dart';
import 'common.dart';
import 'quick_add_page.dart';
import 'spool_page.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late final BambuddyCompanion _companion = context.read<BambuddyCompanion>();
  DateTime? _shownAt;

  @override
  void initState() {
    super.initState();
    _companion.addListener(_onCompanion);
  }

  @override
  void dispose() {
    _companion.removeListener(_onCompanion);
    super.dispose();
  }

  /// Fetch the matched spool whenever a new scan result arrives.
  void _onCompanion() {
    final r = _companion.lastResult;
    if (r == null || r.at == _shownAt) return;
    _shownAt = r.at;
    if (r.spoolId != null) context.read<BambuddyStore>().loadSpool(r.spoolId!);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<BambuddyCompanion>();
    final store = context.watch<BambuddyStore>();
    final result = c.lastResult;
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      // Only say something about the connection when it needs attention.
      if (c.status != CompanionStatus.online)
        _Notice(icon: Icons.cloud_off, text: 'Not connected to Bambuddy', color: scheme.errorContainer),
      if (!c.nfcAvailable)
        _Notice(icon: Icons.nfc, text: 'NFC is off. Turn it on in your phone settings.', color: scheme.errorContainer),
      if (c.linkTarget != null)
        Card(
          color: scheme.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.link, color: scheme.onPrimaryContainer),
            title: Text('Next tag links to ${c.linkTarget!.title}'),
            subtitle: const Text('Tap the spool\'s other tag'),
            trailing: TextButton(onPressed: () => c.armLink(null), child: const Text('Cancel')),
          ),
        ),
      if (result == null)
        _Idle(nfcOn: c.nfcAvailable)
      else if (result.matched)
        _Matched(result: result, spool: store.spoolById(result.spoolId))
      else
        _Unknown(result: result),
    ]);
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        color: color,
        child: ListTile(leading: Icon(icon), title: Text(text)),
      );
}

class _Idle extends StatelessWidget {
  const _Idle({required this.nfcOn});
  final bool nfcOn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: Column(children: [
        Container(
          width: 168,
          height: 168,
          decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primaryContainer),
          child: Icon(Icons.nfc, size: 88, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(height: 32),
        Text(nfcOn ? 'Tap a spool' : 'Turn on NFC', style: t.headlineMedium),
        const SizedBox(height: 8),
        Text(
          nfcOn ? 'Hold the spool\'s tag against the back of your phone' : 'NFC is needed to scan spools',
          textAlign: TextAlign.center,
          style: t.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

/// Large spool header: disc, name, colour and chips, on a green-tinted card.
class _Hero extends StatelessWidget {
  const _Hero({required this.disc, required this.title, this.subtitle, this.chips = const [], this.onTap});
  final Widget disc;
  final String title;
  final String? subtitle;
  final List<Widget> chips;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), scheme.surfaceContainerHigh),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
          child: Column(children: [
            disc,
            const SizedBox(height: 16),
            Text(title, style: t.headlineSmall, textAlign: TextAlign.center),
            if (subtitle != null)
              Text(subtitle!, style: t.titleMedium?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: chips),
            ],
          ]),
        ),
      ),
    );
  }
}

Widget _chip(BuildContext context, IconData icon, String label, {bool accent = false}) {
  final scheme = Theme.of(context).colorScheme;
  return Chip(
    avatar: Icon(icon, size: 16, color: accent ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
    label: Text(label),
    labelStyle: TextStyle(color: accent ? scheme.onPrimaryContainer : null),
    backgroundColor: accent ? scheme.primaryContainer : null,
    side: accent ? BorderSide.none : null,
    visualDensity: VisualDensity.compact,
  );
}

String _tagKind(ScanResult r) {
  final s = r.scan;
  return s.trayUuid != null ? 'Bambu Lab' : (s.decoded?.tagType ?? (s.tagType == 'ntag' ? 'NTAG' : s.tagType));
}

class _Matched extends StatelessWidget {
  const _Matched({required this.result, required this.spool});
  final ScanResult result;
  final BSpool? spool;

  @override
  Widget build(BuildContext context) {
    final s = spool;
    if (s == null) {
      return const Padding(padding: EdgeInsets.all(64), child: Center(child: CircularProgressIndicator()));
    }
    final store = context.read<BambuddyStore>();
    final companion = context.read<BambuddyCompanion>();
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final slots = store.slotsOf(s.id);
    const tall = Size.fromHeight(52);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Hero(
        disc: SpoolDisc(s.rgba, size: 104),
        title: s.title,
        subtitle: s.displayColorName,
        onTap: () => openSpool(context, s.id),
        chips: [
          for (final l in slots) _chip(context, Icons.inbox, l, accent: true),
          _chip(context, Icons.nfc, _tagKind(result)),
        ],
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text('${s.remaining.round()} g', style: t.headlineMedium),
              const Spacer(),
              Text('of ${s.labelWeight} g · ${(s.remainingFraction * 100).round()}%',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 10),
            RemainingBar(s.remainingFraction, height: 8),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: tall),
        onPressed: () => assignToAms(context, s),
        icon: const Icon(Icons.inbox),
        label: const Text('Assign to AMS'),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: tall),
            onPressed: () => weighSpool(context, s),
            icon: const Icon(Icons.scale),
            label: const Text('Weigh'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: tall),
            onPressed: () => companion.armLink(s),
            icon: const Icon(Icons.add_link),
            label: const Text('Link tag'),
          ),
        ),
      ]),
    ]);
  }
}

class _Unknown extends StatelessWidget {
  const _Unknown({required this.result});
  final ScanResult result;

  Future<void> _link(BuildContext context) async {
    final spool = await pickSpool(context, title: 'Link tag to spool');
    if (spool == null || !context.mounted) return;
    final store = context.read<BambuddyStore>();
    final companion = context.read<BambuddyCompanion>();
    try {
      await store.linkTag(spool, tagUid: result.scan.uidHex, trayUuid: result.scan.trayUuid);
      await companion.resendLastScan();
      if (context.mounted) snack(context, 'Tag linked to ${spool.title}');
    } catch (e) {
      if (context.mounted) snack(context, 'Could not link: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = result.scan.decoded;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final described =
        d == null ? null : [d.brand, d.material, d.subtype].whereType<String>().where((x) => x.isNotEmpty).join(' ');
    const tall = Size.fromHeight(52);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Hero(
        disc: d?.rgba != null
            ? SpoolDisc(d!.rgba, size: 104)
            : Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
                child: Icon(Icons.help_outline, size: 48, color: scheme.onSurfaceVariant),
              ),
        title: 'New tag',
        subtitle: (described != null && described.isNotEmpty) ? described : 'Not in your inventory yet',
        chips: [_chip(context, Icons.nfc, '${_tagKind(result)} · ${result.scan.uidHex}')],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
        child: Text(
          'Add it as a new spool, or link it to a spool you already have, '
          'for example the second tag of a spool you scanned before.',
          style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: tall),
        icon: const Icon(Icons.add),
        label: const Text('Add spool'),
        onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => QuickAddPage(scan: result.scan))),
      ),
      const SizedBox(height: 10),
      FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: tall),
        icon: const Icon(Icons.link),
        label: const Text('Link to existing spool'),
        onPressed: () => _link(context),
      ),
    ]);
  }
}

Future<void> weighSpool(BuildContext context, BSpool spool) async {
  final grams = await askWeight(context, spool);
  if (grams == null || !context.mounted) return;
  try {
    await context.read<BambuddyStore>().setWeight(spool, grams);
    if (context.mounted) snack(context, 'Weight saved');
  } catch (e) {
    if (context.mounted) snack(context, 'Could not save weight: $e');
  }
}
