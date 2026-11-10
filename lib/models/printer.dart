/// Printer configuration stored in the database. Mirrors upstream `models.Printer`.
class Printer {
  final String serial;
  final String? name;
  final String? model;
  final String? ipAddress;
  final String? accessCode;
  final bool autoConnect;
  final int? lastSeen;
  final int nozzleCount;

  const Printer({
    required this.serial,
    this.name,
    this.model,
    this.ipAddress,
    this.accessCode,
    this.autoConnect = false,
    this.lastSeen,
    this.nozzleCount = 1,
  });

  String get displayName => (name != null && name!.isNotEmpty) ? name! : serial;

  factory Printer.fromMap(Map<String, Object?> m) => Printer(
        serial: m['serial'] as String,
        name: m['name'] as String?,
        model: m['model'] as String?,
        ipAddress: m['ip_address'] as String?,
        accessCode: m['access_code'] as String?,
        autoConnect: (m['auto_connect'] as int? ?? 0) != 0,
        lastSeen: m['last_seen'] as int?,
        nozzleCount: m['nozzle_count'] as int? ?? 1,
      );

  Map<String, Object?> toMap() => {
        'serial': serial,
        'name': name,
        'model': model,
        'ip_address': ipAddress,
        'access_code': accessCode,
        'auto_connect': autoConnect ? 1 : 0,
      };
}

/// Single AMS tray/slot.
class AmsTray {
  final int amsId;
  final int trayId;
  final String? trayType;
  final String? traySubBrands;
  final String? trayColor;
  final String? trayInfoIdx;
  final double? kValue;
  final int? nozzleTempMin;
  final int? nozzleTempMax;
  final int? remain;

  const AmsTray({
    required this.amsId,
    required this.trayId,
    this.trayType,
    this.traySubBrands,
    this.trayColor,
    this.trayInfoIdx,
    this.kValue,
    this.nozzleTempMin,
    this.nozzleTempMax,
    this.remain,
  });

  bool get isEmpty => trayType == null || trayType!.isEmpty;
}

/// AMS unit with humidity and trays.
class AmsUnit {
  final int id;
  final int? humidity;
  final double? temperature;
  final int? extruder;
  final List<AmsTray> trays;

  const AmsUnit({required this.id, this.humidity, this.temperature, this.extruder, this.trays = const []});

  bool get isHt => id >= 128 && id <= 135;

  String get label {
    if (isHt) return 'AMS HT ${String.fromCharCode(65 + id - 128)}';
    if (id >= 0 && id < 26) return 'AMS ${String.fromCharCode(65 + id)}';
    return 'AMS $id';
  }
}

/// Real-time printer state from MQTT. Mirrors upstream `models.PrinterState`.
class PrinterState {
  String? gcodeState;
  int? printProgress;
  int? layerNum;
  int? totalLayerNum;
  String? subtaskName;
  int? mcRemainingTime;
  String? gcodeFile;
  List<AmsUnit> amsUnits = [];
  AmsTray? vtTray;
  int? trayNow;
  int? trayNowLeft;
  int? trayNowRight;
  int? activeExtruder;
  int stgCur = -1;
  String? stgCurName;
  int? trayReadingBits;
  int nozzleCount = 1;

  PrinterState();

  PrinterState copy() => PrinterState()
    ..gcodeState = gcodeState
    ..printProgress = printProgress
    ..layerNum = layerNum
    ..totalLayerNum = totalLayerNum
    ..subtaskName = subtaskName
    ..mcRemainingTime = mcRemainingTime
    ..gcodeFile = gcodeFile
    ..amsUnits = List.of(amsUnits)
    ..vtTray = vtTray
    ..trayNow = trayNow
    ..trayNowLeft = trayNowLeft
    ..trayNowRight = trayNowRight
    ..activeExtruder = activeExtruder
    ..stgCur = stgCur
    ..stgCurName = stgCurName
    ..trayReadingBits = trayReadingBits
    ..nozzleCount = nozzleCount;
}

/// K-profile (pressure advance calibration) reported by the printer.
class Calibration {
  final int caliIdx;
  final String filamentId;
  final double kValue;
  final String name;
  final int? extruderId;
  final String? nozzleDiameter;
  final String? settingId;

  const Calibration({
    required this.caliIdx,
    required this.filamentId,
    required this.kValue,
    required this.name,
    this.extruderId,
    this.nozzleDiameter,
    this.settingId,
  });
}
