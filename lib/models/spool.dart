/// A filament spool in the inventory. Mirrors upstream `models.Spool`.
class Spool {
  final String id;
  final int? spoolNumber;
  final String? tagId;
  final String material;
  final String? subtype;
  final String? colorName;
  final String? rgba;
  final String? brand;
  final int? labelWeight;
  final int? coreWeight;
  final int? weightNew;
  final int? weightCurrent;
  final double weightUsed;
  final String? slicerFilament;
  final String? slicerFilamentName;
  final String? location;
  final String? note;
  final int? addedTime;
  final int? encodeTime;
  final double consumedSinceAdd;
  final double consumedSinceWeight;
  final String? dataOrigin;
  final String? tagType;
  final bool extHasK;
  final int? archivedAt;
  final int? createdAt;
  final int? updatedAt;

  const Spool({
    required this.id,
    this.spoolNumber,
    this.tagId,
    required this.material,
    this.subtype,
    this.colorName,
    this.rgba,
    this.brand,
    this.labelWeight = 1000,
    this.coreWeight = 250,
    this.weightNew,
    this.weightCurrent,
    this.weightUsed = 0,
    this.slicerFilament,
    this.slicerFilamentName,
    this.location,
    this.note,
    this.addedTime,
    this.encodeTime,
    this.consumedSinceAdd = 0,
    this.consumedSinceWeight = 0,
    this.dataOrigin,
    this.tagType,
    this.extHasK = false,
    this.archivedAt,
    this.createdAt,
    this.updatedAt,
  });

  bool get isArchived => archivedAt != null;

  /// Total used weight (weight_used + consumed_since_weight), as in upstream frontend.
  double get totalUsed => weightUsed + consumedSinceWeight;

  /// Remaining filament (net) in grams.
  double get netWeight {
    final v = (labelWeight ?? 0) - totalUsed;
    return v < 0 ? 0 : v;
  }

  /// Gross weight including the empty spool core.
  double get grossWeight => netWeight + (coreWeight ?? 0);

  double get remainingPercent {
    final lw = labelWeight ?? 0;
    if (lw <= 0) return 100;
    final used = (totalUsed / lw * 100).clamp(0, 100);
    return 100 - used.toDouble();
  }

  String get displayName {
    final parts = [brand, material, subtype].where((s) => s != null && s.isNotEmpty);
    return parts.join(' ');
  }

  factory Spool.fromMap(Map<String, Object?> m) => Spool(
        id: m['id'] as String,
        spoolNumber: m['spool_number'] as int?,
        tagId: m['tag_id'] as String?,
        material: m['material'] as String,
        subtype: m['subtype'] as String?,
        colorName: m['color_name'] as String?,
        rgba: m['rgba'] as String?,
        brand: m['brand'] as String?,
        labelWeight: m['label_weight'] as int?,
        coreWeight: m['core_weight'] as int?,
        weightNew: m['weight_new'] as int?,
        weightCurrent: m['weight_current'] as int?,
        weightUsed: (m['weight_used'] as num?)?.toDouble() ?? 0,
        slicerFilament: m['slicer_filament'] as String?,
        slicerFilamentName: m['slicer_filament_name'] as String?,
        location: m['location'] as String?,
        note: m['note'] as String?,
        addedTime: m['added_time'] as int?,
        encodeTime: m['encode_time'] as int?,
        consumedSinceAdd: (m['consumed_since_add'] as num?)?.toDouble() ?? 0,
        consumedSinceWeight: (m['consumed_since_weight'] as num?)?.toDouble() ?? 0,
        dataOrigin: m['data_origin'] as String?,
        tagType: m['tag_type'] as String?,
        extHasK: (m['ext_has_k'] as int? ?? 0) != 0,
        archivedAt: m['archived_at'] as int?,
        createdAt: m['created_at'] as int?,
        updatedAt: m['updated_at'] as int?,
      );
}

/// Editable spool fields (create/update). Mirrors upstream `SpoolBase`.
class SpoolInput {
  String? tagId;
  String material;
  String? subtype;
  String? colorName;
  String? rgba;
  String? brand;
  int? labelWeight;
  int? coreWeight;
  int? weightNew;
  int? weightCurrent;
  String? slicerFilament;
  String? slicerFilamentName;
  String? location;
  String? note;
  String? dataOrigin;
  String? tagType;

  SpoolInput({
    this.tagId,
    this.material = 'PLA',
    this.subtype,
    this.colorName,
    this.rgba,
    this.brand,
    this.labelWeight = 1000,
    this.coreWeight = 250,
    this.weightNew,
    this.weightCurrent,
    this.slicerFilament,
    this.slicerFilamentName,
    this.location,
    this.note,
    this.dataOrigin,
    this.tagType,
  });

  factory SpoolInput.fromSpool(Spool s) => SpoolInput(
        tagId: s.tagId,
        material: s.material,
        subtype: s.subtype,
        colorName: s.colorName,
        rgba: s.rgba,
        brand: s.brand,
        labelWeight: s.labelWeight,
        coreWeight: s.coreWeight,
        weightNew: s.weightNew,
        weightCurrent: s.weightCurrent,
        slicerFilament: s.slicerFilament,
        slicerFilamentName: s.slicerFilamentName,
        location: s.location,
        note: s.note,
        dataOrigin: s.dataOrigin,
        tagType: s.tagType,
      );

  Map<String, Object?> toMap() => {
        'tag_id': tagId,
        'material': material,
        'subtype': subtype,
        'color_name': colorName,
        'rgba': rgba,
        'brand': brand,
        'label_weight': labelWeight,
        'core_weight': coreWeight,
        'weight_new': weightNew,
        'weight_current': weightCurrent,
        'slicer_filament': slicerFilament,
        'slicer_filament_name': slicerFilamentName,
        'location': location,
        'note': note,
        'data_origin': dataOrigin,
        'tag_type': tagType,
      };
}
