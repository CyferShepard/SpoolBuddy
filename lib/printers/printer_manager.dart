import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../models/printer.dart';
import '../models/spool.dart';
import 'printer_connection.dart';
import 'usage_tracker.dart';

/// Result of assigning a spool to an AMS slot.
class AssignResult {
  final bool staged;
  final String message;
  const AssignResult(this.staged, this.message);
}

/// Owns printer configs and their MQTT connections; tracks usage and
/// spool-to-slot assignments.
class PrinterManager extends ChangeNotifier {
  PrinterManager(this.db, {this.onSpoolsChanged});

  final AppDatabase db;

  /// Called when spool data changes as a side-effect (usage logged, assignment applied).
  final VoidCallback? onSpoolsChanged;

  List<Printer> printers = [];
  final Map<String, PrinterConnection> _connections = {};
  final Map<String, Map<(int, int), String>> _assignments = {};
  late final UsageTracker _usage = UsageTracker(_onUsage);

  /// Short messages for the UI (snackbar) about background events.
  final ValueNotifier<String?> events = ValueNotifier(null);

  PrinterConnection? connection(String serial) => _connections[serial];

  Map<(int, int), String> assignmentsFor(String serial) => _assignments[serial] ?? const {};

  bool _loaded = false;

  /// Load printers and auto-connect, once (standalone mode only).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    printers = await db.getPrinters();
    for (final p in printers) {
      _assignments[p.serial] = await db.getSlotAssignments(p.serial);
    }
    notifyListeners();
    for (final p in printers.where((p) => p.autoConnect)) {
      connect(p.serial);
    }
  }

  Future<void> savePrinter(Printer printer) async {
    final old = _connections[printer.serial];
    final needsReconnect =
        old != null && (old.ipAddress != printer.ipAddress || old.accessCode != printer.accessCode);
    await db.upsertPrinter(printer);
    printers = await db.getPrinters();
    _assignments[printer.serial] ??= {};
    notifyListeners();
    if (needsReconnect) {
      disconnect(printer.serial);
      await connect(printer.serial);
    }
  }

  Future<void> deletePrinter(String serial) async {
    disconnect(serial);
    _connections.remove(serial);
    await db.deletePrinter(serial);
    printers = await db.getPrinters();
    notifyListeners();
  }

  Future<void> connect(String serial) async {
    final printer = printers.where((p) => p.serial == serial).firstOrNull;
    if (printer == null || printer.ipAddress == null || printer.accessCode == null) return;
    _connections[serial]?.disconnect();
    final conn = PrinterConnection(
      serial: serial,
      ipAddress: printer.ipAddress!,
      accessCode: printer.accessCode!,
      onChanged: _onConnectionChanged,
      onAssignmentComplete: (amsId, trayId, spoolId, ok) async {
        if (ok) {
          await db.assignSpoolToSlot(spoolId, serial, amsId, trayId);
          _assignments[serial] = await db.getSlotAssignments(serial);
          events.value = 'Slot configured on ${printer.displayName}';
        } else {
          events.value = 'Failed to configure slot on ${printer.displayName}';
        }
        notifyListeners();
      },
    );
    _connections[serial] = conn;
    await conn.connect();
  }

  void disconnect(String serial) {
    _connections[serial]?.disconnect();
  }

  /// Drop all printer connections (entering Bambuddy companion mode). [load] may run again later.
  void disconnectAll() {
    for (final c in _connections.values) {
      c.disconnect();
    }
    _connections.clear();
    _loaded = false;
  }

  @override
  void dispose() {
    for (final c in _connections.values) {
      c.disconnect();
    }
    super.dispose();
  }

  bool _nozzleSaved(String serial) => printers.any((p) => p.serial == serial && p.nozzleCount == 2);

  void _onConnectionChanged(PrinterConnection conn) {
    final state = conn.state;
    if (conn.connected) {
      _usage.onStateUpdate(conn.serial, state);
      if (state.nozzleCount == 2 && !_nozzleSaved(conn.serial)) {
        db.updateNozzleCount(conn.serial, 2).then((_) async {
          printers = await db.getPrinters();
          notifyListeners();
        });
      }
    }
    notifyListeners();
  }

  Future<void> _onUsage(String serial, String printName, Map<(int, int), int> trayUsage) async {
    var logged = 0;
    for (final MapEntry(key: (amsId, trayId), value: percent) in trayUsage.entries) {
      final spoolId = await db.getSpoolForSlot(serial, amsId, trayId);
      if (spoolId == null) continue;
      final spool = await db.getSpool(spoolId);
      if (spool == null) continue;
      final grams = estimateWeightFromPercent(percent, spool.labelWeight ?? 1000);
      await db.logUsage(spoolId, serial, printName, grams);
      await db.updateSpoolConsumption(spoolId, grams);
      logged++;
    }
    if (logged > 0) {
      events.value = 'Logged filament usage for "$printName"';
      onSpoolsChanged?.call();
    }
  }

  static const _tempRanges = {
    'PLA': (190, 230),
    'PETG': (220, 260),
    'ABS': (240, 270),
    'ASA': (240, 270),
    'TPU': (200, 230),
    'PA': (260, 290),
    'PC': (260, 280),
    'PVA': (190, 210),
  };

  static const _genericFilamentIds = {
    'PLA': 'GFL99',
    'PETG': 'GFG99',
    'ABS': 'GFB99',
    'ASA': 'GFB98',
    'TPU': 'GFU99',
    'PA': 'GFN99',
    'PC': 'GFC99',
    'PVA': 'GFS99',
  };

  /// Build the AMS filament setting for a spool (upstream `assign_spool_to_tray`).
  static FilamentSetting filamentSettingFor(Spool spool) {
    var trayColor = spool.rgba ?? 'FFFFFFFF';
    if (trayColor.length == 6) trayColor = '${trayColor}FF';
    final material = spool.material.toUpperCase();
    final (tMin, tMax) = _tempRanges[material] ?? (190, 250);

    final slicer = spool.slicerFilament ?? '';
    var settingId = slicer.contains('_') ? slicer.split('_').first : slicer;
    String trayInfoIdx;
    if (settingId.startsWith('GFS')) {
      trayInfoIdx = 'GF${settingId.substring(3)}';
    } else if (settingId.startsWith('PFUS') || settingId.startsWith('PFSP')) {
      // Custom cloud presets need a Bambu Cloud lookup, which this app does not do.
      trayInfoIdx = _genericFilamentIds[material] ?? 'GFL99';
      settingId = slicer;
    } else if (settingId.isEmpty) {
      trayInfoIdx = _genericFilamentIds[material] ?? 'GFL99';
    } else {
      trayInfoIdx = settingId;
    }
    return FilamentSetting(
      trayInfoIdx: trayInfoIdx,
      settingId: settingId,
      trayType: spool.material,
      traySubBrands: spool.slicerFilamentName ?? '',
      trayColor: trayColor,
      nozzleTempMin: tMin,
      nozzleTempMax: tMax,
    );
  }

  /// Assign a spool to a slot. Configures immediately; if the slot is empty or
  /// holds a different spool, also stages the assignment for insertion.
  Future<AssignResult> assignSpool(String serial, int amsId, int trayId, Spool spool) async {
    final conn = _connections[serial];
    if (conn == null || !conn.connected) throw StateError('Printer not connected');

    final setting = filamentSettingFor(spool);
    final nozzle = conn.nozzleDiameter();
    var caliIdx = -1;
    for (final kp in await db.getSpoolKProfiles(spool.id)) {
      if (kp['printer_serial'] == serial && kp['nozzle_diameter'] == nozzle) {
        caliIdx = kp['cali_idx'] as int? ?? -1;
        break;
      }
    }

    AmsTray? tray;
    for (final u in conn.state.amsUnits) {
      if (u.id != amsId) continue;
      tray = u.trays.where((t) => t.trayId == trayId).firstOrNull;
    }
    if (amsId == 255 || amsId == 254) tray = conn.state.vtTray;
    final hasSpool = tray != null && !tray.isEmpty;
    var matches = false;
    if (hasSpool) {
      final currentIdx = tray.trayInfoIdx ?? '';
      if (setting.trayInfoIdx.isNotEmpty && currentIdx.isNotEmpty) {
        matches = currentIdx == setting.trayInfoIdx;
      } else {
        matches = (tray.trayType ?? '').toUpperCase() == spool.material.toUpperCase() &&
            (tray.trayColor ?? '').toUpperCase() == setting.trayColor.toUpperCase();
      }
    }

    final ok = conn.setFilament(amsId, trayId, setting);
    conn.setCalibration(amsId, trayId, caliIdx: caliIdx, filamentId: setting.trayInfoIdx, nozzleDiameter: nozzle);

    if (hasSpool && matches) {
      if (!ok) throw StateError('Failed to configure slot');
      await db.assignSpoolToSlot(spool.id, serial, amsId, trayId);
      _assignments[serial] = await db.getSlotAssignments(serial);
      notifyListeners();
      return const AssignResult(false, 'Slot configured');
    }
    conn.stageAssignment(amsId, trayId, PendingAssignment(spool.id, setting, caliIdx, nozzle));
    return AssignResult(true, hasSpool ? 'Replace spool to configure slot' : 'Insert spool to configure slot');
  }

  Future<void> unassign(String serial, int amsId, int trayId) async {
    _connections[serial]?.cancelAssignment(amsId, trayId);
    await db.unassignSlot(serial, amsId, trayId);
    _assignments[serial] = await db.getSlotAssignments(serial);
    notifyListeners();
  }

  /// Apply a K-profile to a slot and remember it for the assigned spool.
  Future<void> applyKProfile(String serial, int amsId, int trayId, Calibration cal) async {
    final conn = _connections[serial];
    if (conn == null || !conn.connected) throw StateError('Printer not connected');
    final nozzle = cal.nozzleDiameter ?? conn.nozzleDiameter();
    conn.setCalibration(amsId, trayId,
        caliIdx: cal.caliIdx, filamentId: cal.filamentId, nozzleDiameter: nozzle, settingId: cal.settingId ?? '');
    final spoolId = assignmentsFor(serial)[(amsId, trayId)];
    if (spoolId != null) await db.saveSpoolKProfile(spoolId, serial, nozzle, cal);
  }
}
