import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bambuddy/bambuddy_store.dart';
import '../../bambuddy/companion.dart';
import 'common.dart';
import 'scan_page.dart' show weighSpool;

void openSpool(BuildContext context, int spoolId) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SpoolPage(spoolId: spoolId)),
    );

class SpoolPage extends StatelessWidget {
  const SpoolPage({super.key, required this.spoolId});
  final int spoolId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final companion = context.watch<BambuddyCompanion>();
    final s = store.spoolById(spoolId);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (s == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final slots = store.slotsOf(s.id);
    final linking = companion.linkTarget?.id == s.id;

    Widget row(String label, String? value) => value == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              SizedBox(width: 130, child: Text(label, style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))),
              Expanded(child: Text(value, style: t.bodyLarge)),
            ]),
          );

    return Scaffold(
      appBar: AppBar(title: Text('Spool #${s.id}')),
      body: RefreshIndicator(
        onRefresh: () => store.loadSpool(s.id),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Center(child: SpoolDisc(s.rgba, size: 140)),
          const SizedBox(height: 20),
          Text(s.title, style: t.headlineSmall, textAlign: TextAlign.center),
          if (s.displayColorName != null) Text(s.displayColorName!, style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Row(children: [
            Text('${s.remaining.round()} g', style: t.headlineMedium),
            Text('  remaining of ${s.labelWeight} g', style: t.titleSmall),
          ]),
          const SizedBox(height: 8),
          RemainingBar(s.remainingFraction, height: 10),
          const SizedBox(height: 24),
          Wrap(spacing: 12, runSpacing: 12, children: [
            FilledButton.icon(
                onPressed: () => assignToAms(context, s), icon: const Icon(Icons.inbox), label: const Text('Assign to AMS')),
            FilledButton.tonalIcon(
                onPressed: () => weighSpool(context, s), icon: const Icon(Icons.scale), label: const Text('Weigh')),
            FilledButton.tonalIcon(
              onPressed: () {
                companion.armLink(linking ? null : s);
                if (!linking) snack(context, 'Tap the tag you want to link to this spool');
              },
              icon: Icon(linking ? Icons.close : Icons.add_link),
              label: Text(linking ? 'Cancel linking' : 'Link a tag'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  await companion.requestTagWrite(s.id);
                } catch (e) {
                  if (context.mounted) snack(context, 'Could not start tag write: $e');
                }
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('Write new tag'),
            ),
          ]),
          if (linking)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Card(
                color: scheme.secondaryContainer,
                child: const ListTile(
                  leading: Icon(Icons.nfc),
                  title: Text('Waiting for a tag'),
                  subtitle: Text('Hold the tag against the back of the phone'),
                ),
              ),
            ),
          const Divider(height: 40),
          row('In AMS', slots.isEmpty ? 'Not assigned' : slots.join(', ')),
          row('Empty spool', '${s.coreWeight} g'),
          row('Used', '${s.weightUsed.round()} g'),
          row('Last weighed', s.lastScaleWeight == null ? null : '${s.lastScaleWeight!.round()} g'),
          row('Slicer preset', s.slicerFilamentName),
          row('Location', s.storageLocation),
          row('Tag', s.trayUuid != null ? 'Bambu Lab (${s.trayUuid})' : s.tagUid),
          row('Note', s.note),
        ]),
      ),
    );
  }
}
