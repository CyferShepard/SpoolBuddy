import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../bambuddy/bambuddy_store.dart';
import '../bambuddy/companion.dart';
import 'companion/ams_page.dart';
import 'companion/inventory_page.dart';
import 'companion/quick_add_page.dart';
import 'companion/scan_page.dart';
import 'companion_pair_screen.dart';

const _green = Color(0xFF00AE42);
const _greenContainer = Color(0xFF0F3D22);
const _onGreenContainer = Color(0xFF9FF2BF);

/// Material 3 in the SpoolBuddy kiosk's colours: its near-black greys and
/// Bambu green, with Android's rounded surfaces and pill indicators.
final companionTheme = () {
  final scheme = ColorScheme.fromSeed(seedColor: _green, brightness: Brightness.dark).copyWith(
    primary: _green,
    onPrimary: const Color(0xFF002910),
    primaryContainer: _greenContainer,
    onPrimaryContainer: _onGreenContainer,
    secondaryContainer: _greenContainer,
    onSecondaryContainer: _onGreenContainer,
    surface: const Color(0xFF1A1A1A),
    onSurface: const Color(0xFFE6E6E6),
    onSurfaceVariant: const Color(0xFFA0A0A0),
    surfaceContainerLowest: const Color(0xFF141414),
    surfaceContainerLow: const Color(0xFF1F1F1F),
    surfaceContainer: const Color(0xFF232323),
    surfaceContainerHigh: const Color(0xFF262626),
    surfaceContainerHighest: const Color(0xFF2D2D2D),
    outline: const Color(0xFF4A4A4A),
    outlineVariant: const Color(0xFF3D3D3D),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 24, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: _greenContainer,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide(color: scheme.outline),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: scheme.surfaceContainer),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surfaceContainer),
  );
}();

/// Companion mode: native phone screens on top of Bambuddy's API, with the
/// phone acting as a SpoolBuddy device (heartbeats, tag reports, tag writes)
/// while the app is open.
class CompanionShell extends StatefulWidget {
  const CompanionShell({super.key});

  @override
  State<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends State<CompanionShell> with WidgetsBindingObserver {
  late final BambuddyCompanion _companion = context.read<BambuddyCompanion>();
  late final BambuddyStore _store = context.read<BambuddyStore>();
  int _tab = 0;
  bool _writeDialogOpen = false;
  final Set<int> _visited = {0};
  DateTime? _lastResultSeen;

  static const _titles = ['Scan', 'AMS', 'Inventory'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _companion.addListener(_onCompanionChanged);
    _companion.messages.addListener(_onMessage);
    _companion.start();
    // The printer chip in the title bar needs the printer list on every tab.
    if (_store.printers.isEmpty) _store.refreshPrinters();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _companion.removeListener(_onCompanionChanged);
    _companion.messages.removeListener(_onMessage);
    _companion.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android only lets the foreground app read NFC; heartbeats stop with it so
    // Bambuddy shows the phone offline rather than idle.
    if (state == AppLifecycleState.resumed) {
      _companion.start();
    } else if (state == AppLifecycleState.paused) {
      _companion.stop();
    }
  }

  void _onMessage() {
    final m = _companion.messages.value;
    if (m == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
    _companion.messages.value = null;
    _store.refreshSpools();
  }

  void _onCompanionChanged() {
    // A new scan result: show it.
    if (_companion.lastResult != null && _tab != 0 && _lastResultSeen != _companion.lastResult!.at) {
      _lastResultSeen = _companion.lastResult!.at;
      setState(() => _tab = 0);
    }
    if (_companion.pendingWrite != null && !_writeDialogOpen && mounted) {
      _writeDialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _WriteDialog(),
      ).whenComplete(() => _writeDialogOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    final t = Theme.of(context).textTheme;
    final kg = store.spools.fold<double>(0, (a, s) => a + s.remaining) / 1000;
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_titles[_tab]),
          actions: [
            if (_tab == 2)
              Text('${store.spools.length} spools · ${kg.toStringAsFixed(1)} kg',
                  style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))
            else
              const _PrinterChip(),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CompanionPairScreen())),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: IndexedStack(index: _tab, children: [
          const ScanPage(),
          _visited.contains(1) ? const AmsPage() : const SizedBox.shrink(),
          _visited.contains(2) ? const InventoryPage() : const SizedBox.shrink(),
        ]),
        floatingActionButton: _tab == 2
            ? FloatingActionButton(
                tooltip: 'Add spool',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const QuickAddPage())),
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() {
            _tab = i;
            _visited.add(i);
          }),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.nfc), label: 'Scan'),
            NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox), label: 'AMS'),
            NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Inventory'),
          ],
        ),
      ),
    );
  }
}

/// The selected printer with an online dot; tap to switch printers.
class _PrinterChip extends StatelessWidget {
  const _PrinterChip();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BambuddyStore>();
    if (store.printers.isEmpty) return const SizedBox.shrink();
    final selected =
        store.printers.firstWhere((p) => p.id == store.selectedPrinterId, orElse: () => store.printers.first);
    final online = store.status?.connected ?? false;
    final chip = Chip(
      avatar: Icon(Icons.circle, size: 10, color: online ? Colors.green : Colors.grey),
      label: Text(selected.name),
      visualDensity: VisualDensity.compact,
    );
    if (store.printers.length < 2) return chip;
    return PopupMenuButton<int>(
      tooltip: 'Choose printer',
      onSelected: store.selectPrinter,
      itemBuilder: (_) => [for (final p in store.printers) PopupMenuItem(value: p.id, child: Text(p.name))],
      child: IgnorePointer(child: chip),
    );
  }
}

/// Shown while Bambuddy has a tag write queued for this device.
class _WriteDialog extends StatefulWidget {
  const _WriteDialog();

  @override
  State<_WriteDialog> createState() => _WriteDialogState();
}

class _WriteDialogState extends State<_WriteDialog> {
  String? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final msg = await context.read<BambuddyCompanion>().performWrite();
    if (mounted) setState(() => _result = msg);
  }

  @override
  Widget build(BuildContext context) {
    final done = _result != null;
    return AlertDialog(
      title: const Text('Write tag'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(done ? Icons.check_circle_outline : Icons.nfc, size: 56),
        const SizedBox(height: 12),
        Text(done ? _result! : 'Hold a blank NTAG tag to the back of the phone', textAlign: TextAlign.center),
      ]),
      actions: [
        if (!done)
          TextButton(
            onPressed: () {
              context.read<BambuddyCompanion>().cancelWrite();
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          )
        else
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
      ],
    );
  }
}
