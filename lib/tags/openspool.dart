import 'dart:convert';
import 'dart:typed_data';

import '../models/spool.dart';
import 'tag_models.dart';

/// OpenSpool NDEF JSON records (upstream `openspool.py`).
class OpenSpool {
  static const recordType = 'application/json';
  static const protocolId = 'openspool';

  static const _materialToSlicer = {
    ...materialToSlicerBase,
    'PA': 'GFL07',
    'PAHT-CF': 'GFL08',
    'PET-CF': 'GFL09',
    'PA-CF': 'GFL10',
    'PLA-CF': 'GFL11',
  };

  static Map<String, dynamic>? _parse(Uint8List payload) {
    try {
      final data = jsonDecode(utf8.decode(payload));
      if (data is Map<String, dynamic> && data['protocol'] == protocolId) return data;
    } catch (_) {}
    return null;
  }

  static bool canDecode(Uint8List payload) => _parse(payload) != null;

  static SpoolFromTag? decode(String uidHex, Uint8List payload) {
    final data = _parse(payload);
    if (data == null) return null;

    int? temp(String k) => data[k] == null ? null : int.tryParse(data[k].toString());
    final minTemp = temp('min_temp');
    final maxTemp = temp('max_temp');
    final materialType = data['type'] as String?;
    final brand = data['brand'] as String?;

    String? rgba;
    final colorHex = (data['color_hex'] as String?)?.toUpperCase().replaceFirst(RegExp('^#+'), '');
    if (colorHex != null) {
      if (colorHex.length == 6) rgba = '${colorHex}FF';
      if (colorHex.length == 8) rgba = colorHex;
    }
    final slicer = _materialToSlicer[(materialType ?? '').toUpperCase()] ?? '';

    final notes = <String>[];
    if (minTemp != null && maxTemp != null && minTemp != 0 && maxTemp != 0) {
      notes.add('Temp: $minTemp-${maxTemp}C');
    } else if (minTemp != null && minTemp != 0) {
      notes.add('Min temp: ${minTemp}C');
    } else if (maxTemp != null && maxTemp != 0) {
      notes.add('Max temp: ${maxTemp}C');
    }
    final missing = [
      if (materialType == null || materialType.isEmpty) 'Material',
      if (slicer.isEmpty) 'Slicer Filament',
      if (rgba == null) 'Color',
      if (brand == null || brand.isEmpty) 'Brand',
    ];
    if (missing.isNotEmpty) notes.add('Missing: ${missing.join(', ')}');

    return SpoolFromTag(
      tagId: uidToBase64(uidHex),
      tagType: TagType.openSpool,
      material: materialType,
      rgba: rgba,
      brand: brand,
      slicerFilament: slicer.isEmpty ? null : slicer,
      note: notes.isEmpty ? null : notes.join('; '),
      dataOrigin: TagType.openSpool,
    );
  }

  /// Encode a spool to OpenSpool JSON bytes.
  static Uint8List encode(Spool spool) {
    final obj = <String, String>{'protocol': protocolId, 'version': '1.0'};
    obj['type'] = spool.material;
    final rgba = spool.rgba;
    if (rgba != null && rgba.length >= 6) obj['color_hex'] = rgba.substring(0, 6);
    if (spool.brand != null && spool.brand!.isNotEmpty) obj['brand'] = spool.brand!;
    return Uint8List.fromList(utf8.encode(jsonEncode(obj)));
  }
}
