/// Data returned by Bambuddy's REST API (shapes from frontend/src/api/client.ts).
library;

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
double? _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

/// A spool from Bambuddy's inventory (built-in or Spoolman-backed: same shape).
class BSpool {
  final int id;
  final String material;
  final String? subtype;
  final String? colorName;
  final bool colorNameSynthesized;
  final String? rgba;
  final String? brand;
  final int labelWeight;
  final int coreWeight;
  final double weightUsed;
  final String? slicerFilamentName;
  final String? note;
  final String? tagUid;
  final String? trayUuid;
  final String? storageLocation;
  final double? lastScaleWeight;

  const BSpool({
    required this.id,
    required this.material,
    this.subtype,
    this.colorName,
    this.colorNameSynthesized = false,
    this.rgba,
    this.brand,
    this.labelWeight = 1000,
    this.coreWeight = 250,
    this.weightUsed = 0,
    this.slicerFilamentName,
    this.note,
    this.tagUid,
    this.trayUuid,
    this.storageLocation,
    this.lastScaleWeight,
  });

  factory BSpool.fromJson(Map<String, dynamic> j) => BSpool(
        id: _int(j['id']) ?? 0,
        material: _str(j['material']) ?? '?',
        subtype: _str(j['subtype']),
        colorName: _str(j['color_name']),
        colorNameSynthesized: j['color_name_is_synthesized'] == true,
        rgba: _str(j['rgba']),
        brand: _str(j['brand']),
        labelWeight: _int(j['label_weight']) ?? 1000,
        coreWeight: _int(j['core_weight']) ?? 250,
        weightUsed: _double(j['weight_used']) ?? 0,
        slicerFilamentName: _str(j['slicer_filament_name']),
        note: _str(j['note']),
        tagUid: _str(j['tag_uid']),
        trayUuid: _str(j['tray_uuid']),
        storageLocation: _str(j['storage_location']),
        lastScaleWeight: _double(j['last_scale_weight']),
      );

  /// Remaining filament in grams (Bambuddy: label_weight - weight_used).
  double get remaining => (labelWeight - weightUsed).clamp(0, double.infinity).toDouble();

  double get remainingFraction => labelWeight <= 0 ? 0 : (remaining / labelWeight).clamp(0, 1).toDouble();

  String get title => [brand, material, subtype].whereType<String>().join(' ');

  /// Colour name worth showing next to [title]: Spoolman has no colour names,
  /// so Bambuddy fills one in from the variant, which would just repeat it.
  String? get displayColorName => colorNameSynthesized || colorName == subtype ? null : colorName;

  bool get hasTag => tagUid != null || trayUuid != null;
}

class BPrinter {
  final int id;
  final String name;
  final String? model;
  const BPrinter(this.id, this.name, this.model);

  factory BPrinter.fromJson(Map<String, dynamic> j) =>
      BPrinter(_int(j['id']) ?? 0, _str(j['name']) ?? 'Printer', _str(j['model']));
}

class BTray {
  final int id;
  final String? color;
  final String? type;
  final String? subBrands;
  final int? remain;
  final String? trayUuid;
  final String? tagUid;
  final int? state;
  final bool? exists;

  const BTray({
    required this.id,
    this.color,
    this.type,
    this.subBrands,
    this.remain,
    this.trayUuid,
    this.tagUid,
    this.state,
    this.exists,
  });

  factory BTray.fromJson(Map<String, dynamic> j) => BTray(
        id: _int(j['id']) ?? 0,
        color: _str(j['tray_color']),
        type: _str(j['tray_type']),
        subBrands: _str(j['tray_sub_brands']),
        remain: _int(j['remain']),
        trayUuid: _str(j['tray_uuid']),
        tagUid: _str(j['tag_uid']),
        state: _int(j['state']),
        exists: j['exists'] is bool ? j['exists'] as bool : null,
      );

  /// Empty when the AMS reports no filament type and no physical spool.
  bool get isEmpty => (type == null) && exists != true;

  /// A spool is physically in the slot. Uses the firmware's presence bit when
  /// Bambuddy has it, else the tray state (9 = empty), else the filament type.
  bool get present => exists ?? (state != null ? state != 9 : type != null);
}

class BAmsUnit {
  final int id;
  final int? humidity;
  final double? temp;
  final bool isHt;
  final List<BTray> trays;
  const BAmsUnit(this.id, this.humidity, this.temp, this.isHt, this.trays);

  factory BAmsUnit.fromJson(Map<String, dynamic> j) => BAmsUnit(
        _int(j['id']) ?? 0,
        _int(j['humidity']),
        _double(j['temp']),
        j['is_ams_ht'] == true,
        [for (final t in (j['tray'] as List? ?? const [])) if (t is Map<String, dynamic>) BTray.fromJson(t)],
      );

  String get label {
    if (isHt) return 'AMS HT ${String.fromCharCode(65 + (id >= 128 ? id - 128 : id))}';
    return 'AMS ${String.fromCharCode(65 + id)}';
  }

  String slotLabel(BTray t) => isHt ? label : '${String.fromCharCode(65 + id)}${t.id + 1}';
}

class BPrinterStatus {
  final int id;
  final String name;
  final bool connected;
  final String? state;
  final String? subtaskName;
  final int? progress;
  final List<BAmsUnit> ams;
  final List<BTray> vtTrays;

  const BPrinterStatus({
    required this.id,
    required this.name,
    required this.connected,
    this.state,
    this.subtaskName,
    this.progress,
    this.ams = const [],
    this.vtTrays = const [],
  });

  factory BPrinterStatus.fromJson(Map<String, dynamic> j) => BPrinterStatus(
        id: _int(j['id']) ?? 0,
        name: _str(j['name']) ?? 'Printer',
        connected: j['connected'] == true,
        state: _str(j['state']),
        subtaskName: _str(j['subtask_name']),
        progress: _int(j['progress']),
        ams: [for (final u in (j['ams'] as List? ?? const [])) if (u is Map<String, dynamic>) BAmsUnit.fromJson(u)],
        vtTrays: [for (final t in (j['vt_tray'] as List? ?? const [])) if (t is Map<String, dynamic>) BTray.fromJson(t)],
      );
}

/// A spool assigned to an AMS slot (local: /inventory/assignments, Spoolman: slot-assignments/all).
class BSlotAssignment {
  final int printerId;
  final int amsId;
  final int trayId;
  final int spoolId;
  const BSlotAssignment(this.printerId, this.amsId, this.trayId, this.spoolId);
}

/// What the AMS external-spool holder uses as its AMS id in Bambuddy.
const externalAmsId = 255;

/// Slots, as (amsId, trayId) in Bambuddy's assignment terms, that hold a spool
/// in [now] but were empty in [before]: where a spool was just loaded.
List<(int, int)> newlyLoadedSlots(BPrinterStatus before, BPrinterStatus now) {
  Map<(int, int), bool> presence(BPrinterStatus s) => {
        for (final u in s.ams)
          for (final t in u.trays) (u.id, t.id): t.present,
        for (final t in s.vtTrays) (externalAmsId, (t.id - 254).clamp(0, 1)): t.present,
      };
  final was = presence(before);
  return [
    for (final e in presence(now).entries)
      if (e.value && was[e.key] == false) e.key,
  ];
}
