import 'dart:typed_data';

import 'cbor_lite.dart';
import 'tag_models.dart';

/// OpenPrintTag CBOR NDEF records (upstream `openprinttag.py`). Read-only.
class OpenPrintTag {
  static const recordType = 'application/vnd.openprinttag';

  static const materialTypes = [
    'PLA', 'PETG', 'TPU', 'ABS', 'ASA', 'PC', 'PCTG', 'PP', 'PA6', 'PA11', //
    'PA12', 'PA66', 'CPE', 'TPE', 'HIPS', 'PHA', 'PET', 'PEI', 'PBT', 'PVB',
    'PVA', 'PEKK', 'PEEK', 'BVOH', 'TPC', 'PPS', 'PPSU', 'PVC', 'PEBA', 'PVDF',
    'PPA', 'PCL', 'PES', 'PMMA', 'POM', 'PPE', 'PS', 'PSU', 'TPI', 'SBS',
  ];

  static SpoolFromTag? decode(String uidHex, Uint8List payload) {
    try {
      final meta = CborLite.decode(payload);
      if (meta is! Map) return null;
      final mainOffset = meta[0];
      final main = (mainOffset is int && mainOffset > 0) ? CborLite.decode(payload, mainOffset) : meta;
      if (main is! Map) return null;

      final materialName = main[10] as String?;
      final brand = main[11] as String?;
      final typeIdx = main[9];
      final materialType =
          (typeIdx is int && typeIdx >= 0 && typeIdx < materialTypes.length) ? materialTypes[typeIdx] : null;
      int? asInt(Object? v) => v is int ? v : (v is double ? v.round() : null);
      final nominal = asInt(main[16]);
      final actual = asInt(main[17]);
      final empty = asInt(main[18]);

      String? color(Object? v) {
        if (v is! Uint8List) return null;
        if (v.length == 3) return '${bytesToHex(v)}FF';
        if (v.length == 4) return bytesToHex(v);
        return null;
      }

      final primary = color(main[19]);

      var colorName = materialName ?? '';
      if (materialType != null && colorName.isNotEmpty) {
        colorName = colorName.split(RegExp(r'\s+')).where((w) => w.toUpperCase() != materialType).join(' ');
      }
      final slicer = materialToSlicerBase[materialType ?? ''] ?? '';

      final missing = [
        if (materialType == null) 'Material',
        if (slicer.isEmpty) 'Slicer Filament',
        if (colorName.isEmpty) 'Color Name',
        if (primary == null) 'RGBA Color',
        if (brand == null || brand.isEmpty) 'Brand',
        if (nominal == null || nominal == 0) 'Label Weight',
        if (empty == null || empty == 0) 'Empty Weight',
      ];

      return SpoolFromTag(
        tagId: uidToBase64(uidHex),
        tagType: TagType.openPrintTag,
        material: materialType,
        colorName: colorName.isEmpty ? null : colorName,
        rgba: primary,
        brand: brand,
        labelWeight: nominal,
        coreWeight: empty,
        weightNew: actual,
        slicerFilament: slicer.isEmpty ? null : slicer,
        note: missing.isEmpty ? null : 'Missing: ${missing.join(', ')}',
        dataOrigin: TagType.openPrintTag,
      );
    } catch (_) {
      return null;
    }
  }
}
