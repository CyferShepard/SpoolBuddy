import 'package:flutter/foundation.dart';

import 'api_models.dart';
import 'bambuddy_client.dart';
import 'companion.dart';

/// Cached Bambuddy data shared by the companion screens. Screens call the
/// refresh methods; actions refresh what they changed.
class BambuddyStore extends ChangeNotifier {
  BambuddyStore(this.companion);

  final BambuddyCompanion companion;

  List<BSpool> spools = [];
  bool spoolsLoading = false;
  String? spoolsError;

  List<BPrinter> printers = [];
  int? selectedPrinterId;
  BPrinterStatus? status;
  List<BSlotAssignment> assignments = [];
  bool printerLoading = false;
  String? printerError;

  BambuddyClient get _api {
    final a = companion.api;
    if (a == null) throw StateError('Not paired with Bambuddy');
    return a;
  }

  bool get _spoolman => companion.spoolman;

  BSpool? spoolById(int? id) => id == null ? null : spools.where((s) => s.id == id).firstOrNull;

  /// Slots a spool is assigned to, as labels like "P2S · A1".
  List<String> slotsOf(int spoolId) => [
        for (final a in assignments.where((a) => a.spoolId == spoolId)) _slotLabel(a.amsId, a.trayId),
      ];

  String _slotLabel(int amsId, int trayId) {
    if (amsId == externalAmsId) return trayId == 0 ? 'Ext' : 'Ext ${trayId + 1}';
    final unit = status?.ams.where((u) => u.id == amsId).firstOrNull;
    if (unit != null && unit.isHt) return unit.label;
    return amsSlotLabel(amsId, trayId);
  }

  Future<void> refreshSpools() async {
    spoolsLoading = true;
    notifyListeners();
    try {
      await companion.ensureMode();
      spools = await _api.spools(spoolman: _spoolman)
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      spoolsError = null;
    } catch (e) {
      spoolsError = '$e';
    }
    spoolsLoading = false;
    notifyListeners();
  }

  /// Fetch one spool (e.g. a scan match) and merge it into the cache.
  Future<BSpool?> loadSpool(int id) async {
    try {
      await companion.ensureMode();
      final s = await _api.spool(id, spoolman: _spoolman);
      final i = spools.indexWhere((x) => x.id == id);
      i >= 0 ? spools[i] = s : spools.add(s);
      notifyListeners();
      return s;
    } catch (_) {
      return spoolById(id);
    }
  }

  Future<void> refreshPrinters() async {
    printerLoading = true;
    notifyListeners();
    try {
      printers = await _api.printers();
      if (printers.isNotEmpty && !printers.any((p) => p.id == selectedPrinterId)) {
        selectedPrinterId = printers.first.id;
      }
      printerError = null;
      await refreshStatus(notify: false);
    } catch (e) {
      printerError = '$e';
    }
    printerLoading = false;
    notifyListeners();
  }

  Future<void> selectPrinter(int id) async {
    selectedPrinterId = id;
    status = null;
    assignments = [];
    notifyListeners();
    await refreshStatus();
  }

  Future<void> refreshStatus({bool notify = true}) async {
    final id = selectedPrinterId;
    if (id == null) return;
    try {
      await companion.ensureMode();
      final results = await Future.wait([
        _api.printerStatus(id),
        _api.slotAssignments(id, spoolman: _spoolman),
      ]);
      status = results[0] as BPrinterStatus;
      assignments = results[1] as List<BSlotAssignment>;
      printerError = null;
    } catch (e) {
      printerError = '$e';
    }
    if (notify) notifyListeners();
  }

  int? assignedSpoolId(int amsId, int trayId) =>
      assignments.where((a) => a.amsId == amsId && a.trayId == trayId).firstOrNull?.spoolId;

  /// Assign and refresh. Returns a message for the user.
  Future<String> assign(BSpool spool, int printerId, int amsId, int trayId) async {
    final pending = await _api.assignSlot(spool.id, printerId, amsId, trayId, spoolman: _spoolman);
    if (printerId == selectedPrinterId) await refreshStatus();
    return pending ? 'Assigned. The slot configures when the spool is inserted.' : 'Assigned to ${_slotLabel(amsId, trayId)}';
  }

  Future<void> unassign(int spoolId, int amsId, int trayId) async {
    final printerId = selectedPrinterId!;
    await _api.unassignSlot(spoolId: spoolId, printerId: printerId, amsId: amsId, trayId: trayId, spoolman: _spoolman);
    await refreshStatus();
  }

  /// Create a spool. Print temperatures go where the inventory keeps them:
  /// Bambuddy's own inventory has a nozzle temperature on the spool (and no bed
  /// field); with Spoolman they go on the spool's filament.
  Future<BSpool> createSpool(Map<String, Object?> fields, {int? nozzleTemp}) async {
    await companion.ensureMode();
    final s = await _api.createSpool({
      ...fields,
      if (!_spoolman && nozzleTemp != null) 'nozzle_temp_min': nozzleTemp,
    }, spoolman: _spoolman);
    spools.add(s);
    notifyListeners();
    return s;
  }

  /// Set a Spoolman spool's filament temperatures. Nothing to do for
  /// Bambuddy's own inventory, where [createSpool] already stored the nozzle's.
  Future<void> setFilamentTemps(BSpool spool, {int? nozzleTemp, int? bedTemp}) async {
    if (!_spoolman) return;
    await _api.setSpoolmanFilamentTemps(spool.id, extruder: nozzleTemp, bed: bedTemp);
  }

  Future<void> linkTag(BSpool spool, {String? tagUid, String? trayUuid}) async {
    await _api.linkTag(spool.id, tagUid: tagUid, trayUuid: trayUuid, spoolman: _spoolman);
    await loadSpool(spool.id);
  }

  Future<void> setWeight(BSpool spool, double grams) async {
    await _api.updateSpoolWeight(spool.id, grams);
    await loadSpool(spool.id);
  }
}
