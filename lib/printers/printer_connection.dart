import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/printer.dart';

/// Stage names from BambuStudio DeviceManager.cpp (upstream `STAGE_NAMES`).
const stageNames = {
  0: 'Printing', 1: 'Auto bed leveling', 2: 'Heatbed preheating', 3: 'Vibration compensation', //
  4: 'Changing filament', 5: 'M400 pause', 6: 'Paused (filament ran out)', 7: 'Heating nozzle',
  8: 'Calibrating dynamic flow', 9: 'Scanning bed surface', 10: 'Inspecting first layer',
  11: 'Identifying build plate type', 12: 'Calibrating Micro Lidar', 13: 'Homing toolhead',
  14: 'Cleaning nozzle tip', 15: 'Checking extruder temperature', 16: 'Paused by the user',
  17: 'Pause (front cover fall off)', 18: 'Calibrating the micro lidar', 19: 'Calibrating flow ratio',
  20: 'Pause (nozzle temperature malfunction)', 21: 'Pause (heatbed temperature malfunction)',
  22: 'Filament unloading', 23: 'Pause (step loss)', 24: 'Filament loading', 25: 'Motor noise cancellation',
  26: 'Pause (AMS offline)', 27: 'Pause (low speed of the heatbreak fan)',
  28: 'Pause (chamber temperature control problem)', 29: 'Cooling chamber',
  30: 'Paused (toolhead not returning)', 31: 'Pause (first layer problem)', 32: 'Inspecting Z seam',
  33: 'Pause (spaghetti detected)', 34: 'Pause (auto recover failed)', 35: 'Nozzle offset calibration',
  36: 'Nozzle cleaning', 37: 'Pause (pressure advance)', 38: 'Nozzle offset preheating',
  39: 'Pause (nozzle clog detected)', 40: 'High temperature auto bed leveling',
  41: 'Auto Check: Quick Release Lever', 42: 'Auto Check: Door and Upper Cover', 43: 'Laser Calibration',
  44: 'Auto Check: Platform', 45: 'Confirming BirdsEye Camera location', 46: 'Calibrating BirdsEye Camera',
  47: 'Auto bed leveling - phase 1', 48: 'Auto bed leveling - phase 2', 49: 'Heating chamber',
  50: 'Cooling heatbed', 51: 'Printing calibration lines', 52: 'Auto Check: Material',
  53: 'Live View Camera Calibration', 54: 'Waiting for heatbed temperature',
  55: 'Auto Check: Material Position', 56: 'Cutting Module Offset Calibration', 57: 'Measuring Surface',
  58: 'Thermal Preconditioning',
};

String? stageName(int stg) {
  if (stg < 0 || stg >= 255) return null;
  return stageNames[stg] ?? 'Unknown stage ($stg)';
}

/// Filament setting to apply to an AMS slot.
class FilamentSetting {
  final String trayInfoIdx;
  final String settingId;
  final String trayType;
  final String traySubBrands;
  final String trayColor;
  final int nozzleTempMin;
  final int nozzleTempMax;

  const FilamentSetting({
    this.trayInfoIdx = '',
    this.settingId = '',
    this.trayType = '',
    this.traySubBrands = '',
    this.trayColor = 'FFFFFFFF',
    this.nozzleTempMin = 190,
    this.nozzleTempMax = 230,
  });
}

/// Assignment staged for an empty slot, applied when a spool is inserted.
class PendingAssignment {
  final String spoolId;
  final FilamentSetting setting;
  final int caliIdx;
  final String nozzleDiameter;
  const PendingAssignment(this.spoolId, this.setting, this.caliIdx, this.nozzleDiameter);
}

enum ConnectionStatus { disconnected, connecting, connected, error }

/// MQTT connection to a single Bambu Lab printer in LAN / Developer Mode.
class PrinterConnection {
  PrinterConnection({
    required this.serial,
    required this.ipAddress,
    required this.accessCode,
    required this.onChanged,
    this.onAssignmentComplete,
  });

  final String serial;
  final String ipAddress;
  final String accessCode;

  /// Called after every state change (including connection status).
  final void Function(PrinterConnection) onChanged;

  /// Called when a staged assignment is applied: (amsId, trayId, spoolId, success).
  final void Function(int, int, String, bool)? onAssignmentComplete;

  MqttServerClient? _client;
  StreamSubscription? _sub;
  ConnectionStatus status = ConnectionStatus.disconnected;
  String? lastError;
  final PrinterState state = PrinterState();

  final Map<int, Calibration> calibrations = {};
  final Map<int, String> _nozzleDiameters = {};
  bool _nozzleCountDetected = false;
  final Map<int, int> _amsExtruderMap = {};
  final Map<(int, int), String?> _prevTrayTypes = {};
  final Map<(int, int), PendingAssignment> pendingAssignments = {};

  final Map<String, (List<Calibration>, DateTime)> _kprofileCache = {};
  Completer<List<Calibration>>? _kprofileWaiter;
  String? _expectedKprofileNozzle;

  String get _requestTopic => 'device/$serial/request';
  bool get connected => status == ConnectionStatus.connected;

  String nozzleDiameter([int extruderId = 0]) => _nozzleDiameters[extruderId] ?? '0.4';

  Future<void> connect() async {
    if (status == ConnectionStatus.connecting || connected) return;
    status = ConnectionStatus.connecting;
    lastError = null;
    onChanged(this);

    final client = MqttServerClient.withPort(ipAddress, 'spoolbuddy_android_$serial', 8883)
      ..secure = true
      // Bambu printers use self-signed certificates.
      ..securityContext = SecurityContext(withTrustedRoots: false)
      ..onBadCertificate = ((X509Certificate _) => true)
      ..keepAlivePeriod = 60
      ..autoReconnect = true
      ..logging(on: false)
      ..setProtocolV311()
      ..connectionMessage = MqttConnectMessage()
          .withClientIdentifier('spoolbuddy_android_$serial')
          .authenticateAs('bblp', accessCode)
          .startClean();
    client.onConnected = _onConnected;
    client.onAutoReconnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.onAutoReconnect = () {
      status = ConnectionStatus.connecting;
      onChanged(this);
    };
    _client = client;

    try {
      await client.connect();
    } catch (e) {
      status = ConnectionStatus.error;
      lastError = 'Connection failed: $e';
      client.disconnect();
      _client = null;
      onChanged(this);
      return;
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      status = ConnectionStatus.error;
      lastError = 'Connection refused (${client.connectionStatus?.returnCode}). Check the access code.';
      client.disconnect();
      _client = null;
      onChanged(this);
      return;
    }
    _sub = client.updates?.listen(_onMessages);
    _onConnected();
  }

  void disconnect() {
    _sub?.cancel();
    _sub = null;
    final c = _client;
    _client = null;
    c?.autoReconnect = false;
    c?.disconnect();
    status = ConnectionStatus.disconnected;
    onChanged(this);
  }

  void _onConnected() {
    final client = _client;
    if (client == null || client.connectionStatus?.state != MqttConnectionState.connected) return;
    if (status == ConnectionStatus.connected) return;
    status = ConnectionStatus.connected;
    client.subscribe('device/$serial/report', MqttQos.atMostOnce);
    for (final d in const ['0.2', '0.4', '0.6', '0.8']) {
      _fetchCalibrations(d);
    }
    refreshState();
    onChanged(this);
  }

  void _onDisconnected() {
    if (_client == null) return; // intentional disconnect already handled
    status = (_client?.autoReconnect ?? false) ? ConnectionStatus.connecting : ConnectionStatus.disconnected;
    onChanged(this);
  }

  bool _publish(Map<String, Object?> payload) {
    final client = _client;
    if (client == null || !connected) return false;
    final builder = MqttClientPayloadBuilder()..addUTF8String(jsonEncode(payload));
    try {
      client.publishMessage(_requestTopic, MqttQos.atMostOnce, builder.payload!);
      return true;
    } catch (e) {
      debugPrint('[$serial] publish failed: $e');
      return false;
    }
  }

  void refreshState() => _publish({
        'pushing': {'command': 'pushall', 'sequence_id': '1'}
      });

  void _fetchCalibrations(String nozzleDiameter) => _publish({
        'print': {
          'command': 'extrusion_cali_get',
          'filament_id': '',
          'nozzle_diameter': nozzleDiameter,
          'sequence_id': '1',
        }
      });

  static int _slotId(int amsId, int trayId) => amsId <= 3 ? trayId : 0;

  /// Trigger an RFID re-read on a slot.
  bool resetSlot(int amsId, int trayId) => _publish({
        'print': {
          'command': 'ams_get_rfid',
          'ams_id': amsId,
          'slot_id': _slotId(amsId, trayId),
          'sequence_id': '1',
        }
      });

  bool setFilament(int amsId, int trayId, FilamentSetting s) => _publish({
        'print': {
          'command': 'ams_filament_setting',
          'ams_id': amsId,
          'tray_id': trayId,
          'slot_id': _slotId(amsId, trayId),
          'tray_info_idx': s.trayInfoIdx,
          'tray_type': s.trayType,
          'tray_sub_brands': s.traySubBrands,
          'tray_color': s.trayColor,
          'nozzle_temp_min': s.nozzleTempMin,
          'nozzle_temp_max': s.nozzleTempMax,
          'sequence_id': '1',
          if (s.settingId.isNotEmpty) 'setting_id': s.settingId,
        }
      });

  bool setCalibration(int amsId, int trayId,
          {int caliIdx = -1, String filamentId = '', String nozzleDiameter = '0.4', String settingId = ''}) =>
      _publish({
        'print': {
          'command': 'extrusion_cali_sel',
          'cali_idx': caliIdx,
          'filament_id': filamentId,
          'nozzle_diameter': nozzleDiameter,
          'ams_id': amsId,
          'tray_id': trayId,
          'slot_id': _slotId(amsId, trayId),
          'sequence_id': '1',
          if (settingId.isNotEmpty) 'setting_id': settingId,
        }
      });

  void stageAssignment(int amsId, int trayId, PendingAssignment a) {
    pendingAssignments[(amsId, trayId)] = a;
    onChanged(this);
  }

  void cancelAssignment(int amsId, int trayId) {
    if (pendingAssignments.remove((amsId, trayId)) != null) onChanged(this);
  }

  void _executePendingAssignment(int amsId, int trayId) {
    final a = pendingAssignments.remove((amsId, trayId));
    if (a == null) return;
    final ok = setFilament(amsId, trayId, a.setting);
    setCalibration(amsId, trayId,
        caliIdx: a.caliIdx, filamentId: a.setting.trayInfoIdx, nozzleDiameter: a.nozzleDiameter);
    onAssignmentComplete?.call(amsId, trayId, a.spoolId, ok);
  }

  /// Request K-profiles for a nozzle diameter, retrying since printers
  /// sometimes ignore the first request. Cached for 30 seconds.
  Future<List<Calibration>> getKProfiles(String nozzleDiameter) async {
    if (!connected) return const [];
    final cached = _kprofileCache[nozzleDiameter];
    if (cached != null && DateTime.now().difference(cached.$2) < const Duration(seconds: 30)) {
      return cached.$1;
    }
    while (_kprofileWaiter != null) {
      await _kprofileWaiter!.future.catchError((_) => <Calibration>[]);
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final waiter = Completer<List<Calibration>>();
      _kprofileWaiter = waiter;
      _expectedKprofileNozzle = nozzleDiameter;
      _fetchCalibrations(nozzleDiameter);
      try {
        final profiles = await waiter.future.timeout(const Duration(seconds: 5));
        _kprofileCache[nozzleDiameter] = (profiles, DateTime.now());
        return profiles;
      } on TimeoutException {
        continue;
      } finally {
        _kprofileWaiter = null;
        _expectedKprofileNozzle = null;
      }
    }
    _kprofileCache[nozzleDiameter] = (const [], DateTime.now());
    return const [];
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final m in messages) {
      final msg = m.payload;
      if (msg is! MqttPublishMessage) continue;
      try {
        final payload = jsonDecode(utf8.decode(msg.payload.message, allowMalformed: true));
        if (payload is Map<String, dynamic>) handleMessage(payload);
      } catch (e) {
        debugPrint('[$serial] bad message: $e');
      }
    }
  }

  static int? _int(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? double.tryParse(v.toString())?.toInt();
  }

  static double? _double(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  /// Process one decoded report message. Public for tests.
  @visibleForTesting
  void handleMessage(Map<String, dynamic> payload) {
    final p = payload['print'];
    if (p is! Map<String, dynamic>) return;
    final command = p['command'];

    if (p.containsKey('filaments') || command == 'extrusion_cali_get') {
      _handleCalibrationResponse(p);
      return;
    }

    if (p.containsKey('nozzle_diameter')) _nozzleDiameters[0] = p['nozzle_diameter'].toString();
    if (p.containsKey('gcode_state')) state.gcodeState = p['gcode_state'] as String?;
    if (p.containsKey('stg_cur')) {
      state.stgCur = _int(p['stg_cur']) ?? -1;
      state.stgCurName = stageName(state.stgCur);
    }
    if (p.containsKey('mc_percent')) state.printProgress = _int(p['mc_percent']);
    if (p.containsKey('subtask_name')) state.subtaskName = p['subtask_name'] as String?;
    if (p.containsKey('mc_remaining_time')) state.mcRemainingTime = _int(p['mc_remaining_time']);
    if (p.containsKey('gcode_file')) state.gcodeFile = p['gcode_file'] as String?;

    final d3 = p['3D'] is Map ? p['3D'] as Map : const {};
    if (d3.containsKey('layer_num')) {
      state.layerNum = _int(d3['layer_num']);
    } else if (p.containsKey('layer_num')) {
      state.layerNum = _int(p['layer_num']);
    }
    if (d3.containsKey('total_layer_num')) {
      state.totalLayerNum = _int(d3['total_layer_num']);
    } else if (p.containsKey('total_layer_num')) {
      state.totalLayerNum = _int(p['total_layer_num']);
    }

    final ams = p['ams'];
    if (ams is Map<String, dynamic>) {
      _parseAms(ams);
      if (ams.containsKey('tray_now')) state.trayNow = _int(ams['tray_now']);
    }
    if (p['vt_tray'] is Map<String, dynamic>) {
      state.vtTray = _parseTray(p['vt_tray'] as Map<String, dynamic>, 255, 0);
    }

    final device = p['device'] is Map ? p['device'] as Map : const {};
    final extruder = device['extruder'] is Map ? device['extruder'] as Map : const {};
    final info = extruder['info'] is List ? extruder['info'] as List : const [];
    if (info.isNotEmpty) {
      if (info.length >= 2) {
        state.nozzleCount = 2;
        _nozzleCountDetected = true;
      }
      for (final e in info) {
        if (e is! Map) continue;
        final extId = _int(e['id']);
        if (e['dia'] != null && extId != null) _nozzleDiameters[extId] = e['dia'].toString();
        final snow = _int(e['snow']);
        if (snow == null) continue;
        int globalTray;
        if (snow != 0xFFFF && snow != 0xFEFF) {
          final amsId = (snow >> 8) & 0xFF;
          final slotId = snow & 0xFF;
          if (amsId <= 3) {
            globalTray = amsId * 4 + slotId;
          } else if (amsId >= 128) {
            globalTray = 16 + (amsId - 128);
          } else {
            globalTray = snow;
          }
        } else {
          globalTray = 255;
        }
        if (extId == 0) state.trayNowRight = globalTray;
        if (extId == 1) state.trayNowLeft = globalTray;
      }
    }
    final extState = _int(extruder['state']);
    if (extState != null) state.activeExtruder = (extState >> 4) & 0xF;

    onChanged(this);
  }

  void _handleCalibrationResponse(Map<String, dynamic> p) {
    final responseNozzle = p['nozzle_diameter']?.toString();
    final waiter = _kprofileWaiter;
    if (waiter != null && _expectedKprofileNozzle != null && responseNozzle != _expectedKprofileNozzle) {
      return; // broadcast for a different nozzle
    }
    final profiles = <Calibration>[];
    for (final f in (p['filaments'] as List? ?? const [])) {
      if (f is! Map) continue;
      final idx = _int(f['cali_idx']);
      if (idx == null) continue;
      final cal = Calibration(
        caliIdx: idx,
        filamentId: f['filament_id']?.toString() ?? '',
        kValue: _double(f['k_value']) ?? 0,
        name: f['name']?.toString() ?? '',
        extruderId: _int(f['extruder_id']),
        nozzleDiameter: responseNozzle,
        settingId: f['setting_id']?.toString(),
      );
      calibrations[idx] = cal;
      profiles.add(cal);
    }
    if (waiter != null && !waiter.isCompleted) waiter.complete(profiles);
  }

  void _parseAms(Map<String, dynamic> amsData) {
    final units = amsData['ams'];
    if (units is! List) return;

    final bits = amsData['tray_reading_bits'];
    if (bits != null) {
      state.trayReadingBits = bits is String ? int.tryParse(bits, radix: 16) : _int(bits);
    }

    if (_nozzleCountDetected) {
      for (final u in units) {
        if (u is! Map) continue;
        final infoVal = _int(u['info']);
        if (infoVal != null) {
          // bit 8: 0 = left extruder (id 1), 1 = right extruder (id 0)
          _amsExtruderMap[_int(u['id']) ?? 0] = 1 - ((infoVal >> 8) & 1);
        }
      }
    }

    final toExecute = <(int, int)>[];
    final parsed = <AmsUnit>[];
    for (final u in units) {
      if (u is! Map<String, dynamic>) continue;
      final unitId = _int(u['id']) ?? 0;
      final humidity = _int(u['humidity_raw']) ?? _int(u['humidity']);
      final trays = <AmsTray>[];
      for (final t in (u['tray'] as List? ?? const [])) {
        if (t is! Map<String, dynamic> || t.isEmpty) continue;
        final trayId = _int(t['id']) ?? 0;
        final tray = _parseTray(t, unitId, trayId);
        trays.add(tray);
        final key = (unitId, trayId);
        final wasEmpty = (_prevTrayTypes[key] ?? '').isEmpty;
        _prevTrayTypes[key] = tray.trayType;
        if (wasEmpty && !tray.isEmpty && pendingAssignments.containsKey(key)) toExecute.add(key);
      }
      parsed.add(AmsUnit(
        id: unitId,
        humidity: humidity,
        temperature: _double(u['temp']),
        extruder: _nozzleCountDetected ? _amsExtruderMap[unitId] : null,
        trays: trays,
      ));
    }
    state.amsUnits = parsed;
    for (final (a, t) in toExecute) {
      _executePendingAssignment(a, t);
    }
  }

  AmsTray _parseTray(Map<String, dynamic> t, int amsId, int trayId) {
    var k = _double(t['k']);
    if (k == null) {
      final idx = _int(t['cali_idx']);
      if (idx != null && idx > 0) k = calibrations[idx]?.kValue;
    }
    return AmsTray(
      amsId: amsId,
      trayId: trayId,
      trayType: t['tray_type'] as String?,
      traySubBrands: t['tray_sub_brands'] as String?,
      trayColor: t['tray_color'] as String?,
      trayInfoIdx: t['tray_info_idx'] as String?,
      kValue: k,
      nozzleTempMin: _int(t['nozzle_temp_min']),
      nozzleTempMax: _int(t['nozzle_temp_max']),
      remain: _int(t['remain']),
    );
  }
}
