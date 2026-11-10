import '../models/printer.dart';

/// Estimate grams used from AMS remain% points consumed (upstream `estimate_weight_from_percent`).
double estimateWeightFromPercent(int percentUsed, int labelWeight) => percentUsed / 100.0 * labelWeight;

class _PrintSession {
  final String printName;
  final Map<(int, int), int> trayRemainStart;
  _PrintSession(this.printName, this.trayRemainStart);
}

/// Tracks print sessions and reports filament usage from AMS remain% deltas
/// when a print ends (upstream `usage_tracker.py`).
class UsageTracker {
  UsageTracker(this.onUsage);

  /// (serial, printName, {(amsId, trayId): percentUsed})
  final Future<void> Function(String, String, Map<(int, int), int>) onUsage;

  final Map<String, _PrintSession> _sessions = {};
  final Map<String, String?> _prevGcodeState = {};

  static Map<(int, int), int> _remains(PrinterState s) => {
        for (final u in s.amsUnits)
          for (final t in u.trays)
            if (t.remain != null) (u.id, t.trayId): t.remain!,
        if (s.vtTray?.remain != null) (255, 0): s.vtTray!.remain!,
      };

  void onStateUpdate(String serial, PrinterState state) {
    final gcode = state.gcodeState;
    final prev = _prevGcodeState[serial];
    _prevGcodeState[serial] = gcode;
    if (gcode == prev) return;

    if (gcode == 'RUNNING' && prev != 'RUNNING') {
      _sessions[serial] = _PrintSession(state.subtaskName ?? 'Unknown', _remains(state));
    } else if ((gcode == 'FINISH' || gcode == 'IDLE') && prev == 'RUNNING' ||
        gcode == 'FINISH' && prev == 'PAUSE') {
      final session = _sessions.remove(serial);
      if (session == null) return;
      final current = _remains(state);
      final usage = <(int, int), int>{};
      session.trayRemainStart.forEach((key, start) {
        final end = current[key];
        if (end != null && start > end) usage[key] = start - end;
      });
      if (usage.isNotEmpty) onUsage(serial, session.printName, usage);
    }
  }
}
