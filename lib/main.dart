import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bambuddy/bambuddy_store.dart';
import 'bambuddy/companion.dart';
import 'data/database.dart';
import 'data/spool_store.dart';
import 'nfc/nfc_service.dart';
import 'printers/printer_manager.dart';
import 'ui/companion_shell.dart';
import 'ui/inventory_screen.dart';
import 'ui/printers_screen.dart';
import 'ui/scan_screen.dart';
import 'ui/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  final spools = SpoolStore(db);
  await spools.refresh();
  final printers = PrinterManager(db, onSpoolsChanged: spools.refresh);
  final nfc = NfcService();
  final companion = BambuddyCompanion(db, nfc);
  await companion.load();

  runApp(MultiProvider(
    providers: [
      Provider.value(value: db),
      Provider.value(value: nfc),
      ChangeNotifierProvider.value(value: spools),
      ChangeNotifierProvider.value(value: printers),
      ChangeNotifierProvider.value(value: companion),
      ChangeNotifierProvider(create: (_) => BambuddyStore(companion)),
    ],
    child: const SpoolBuddyApp(),
  ));
}

class SpoolBuddyApp extends StatelessWidget {
  const SpoolBuddyApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00AE42), brightness: b),
          useMaterial3: true,
        );
    // Paired with Bambuddy: the phone is a SpoolBuddy device and Bambuddy owns the inventory.
    final paired = context.select<BambuddyCompanion, bool>((c) => c.paired);
    return MaterialApp(
      title: 'SpoolBuddy',
      theme: paired ? companionTheme : theme(Brightness.light),
      darkTheme: paired ? companionTheme : theme(Brightness.dark),
      home: paired ? const CompanionShell() : const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final ValueNotifier<String?> _events;

  @override
  void initState() {
    super.initState();
    _printers = context.read<PrinterManager>();
    _events = _printers.events;
    _events.addListener(_onEvent);
    _printers.load();
  }

  late final PrinterManager _printers;

  @override
  void dispose() {
    _events.removeListener(_onEvent);
    // Leaving standalone mode (paired with Bambuddy): stop talking to printers directly.
    _printers.disconnectAll();
    super.dispose();
  }

  void _onEvent() {
    final msg = _events.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    _events.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: const [
        InventoryScreen(),
        ScanScreen(),
        PrintersScreen(),
        SettingsScreen(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Inventory'),
          NavigationDestination(icon: Icon(Icons.nfc), label: 'Scan'),
          NavigationDestination(icon: Icon(Icons.print_outlined), selectedIcon: Icon(Icons.print), label: 'Printers'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
