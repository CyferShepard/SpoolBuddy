import 'dart:convert';
import 'dart:typed_data';

import '../models/spool.dart';
import 'tag_models.dart';

/// OpenTag3D binary NDEF records (upstream `opentag3d.py`).
class OpenTag3D {
  static const recordType = 'application/opentag3d';

  static const _offVersion = 0x00;
  static const _offMaterial = 0x02;
  static const _offModifiers = 0x07;
  static const _offManufacturer = 0x1B;
  static const _offColorName = 0x2B;
  static const _offColorPrimary = 0x4B;
  static const _offDiameter = 0x5C;
  static const _offWeight = 0x5E;
  static const _offPrintTemp = 0x60;
  static const _offBedTemp = 0x61;
  static const _offDensity = 0x62;
  static const _offUrl = 0x70;
  static const _offSerial = 0x90;
  static const _offMfgDate = 0xA0;
  static const _coreSize = 0x66;

  static const _materialToSlicer = {...materialToSlicerBase, 'PA': 'GFL07', 'HIPS': 'GFL14'};

  static String? _str(Uint8List d, int off, int len) {
    if (off + len > d.length) return null;
    var raw = d.sublist(off, off + len);
    final nul = raw.indexOf(0);
    if (nul >= 0) raw = raw.sublist(0, nul);
    try {
      final s = utf8.decode(raw).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static int? _u16(Uint8List d, int off) {
    if (off + 2 > d.length) return null;
    final v = (d[off] << 8) | d[off + 1];
    return v > 0 ? v : null;
  }

  static int? _u8(Uint8List d, int off) => off < d.length && d[off] > 0 ? d[off] : null;

  static String? _color(Uint8List d, int off) {
    if (off + 4 > d.length) return null;
    final c = d.sublist(off, off + 4);
    if (c.every((b) => b == 0)) return null;
    return bytesToHex(c);
  }

  static SpoolFromTag? decode(String uidHex, Uint8List p) {
    if (p.length >= 2 && ((p[0] << 8) | p[1]) >= 2000) return _decodeV2(uidHex, p);
    if (p.length < _coreSize) return null;
    final material = _str(p, _offMaterial, 5);
    final modifiers = _str(p, _offModifiers, 5);
    final manufacturer = _str(p, _offManufacturer, 16);
    final colorName = _str(p, _offColorName, 32);
    final primary = _color(p, _offColorPrimary);
    final diameterUm = _u16(p, _offDiameter);
    final weightG = _u16(p, _offWeight);
    final printTemp = _u8(p, _offPrintTemp);
    final bedTemp = _u8(p, _offBedTemp);
    final densityRaw = _u16(p, _offDensity);

    String? url;
    if (p.length >= _offUrl + 32) {
      final u = _str(p, _offUrl, 32);
      if (u != null) url = 'https://$u';
    }
    final serial = p.length >= _offSerial + 16 ? _str(p, _offSerial, 16) : null;
    String? mfgDate;
    if (p.length >= _offMfgDate + 4) {
      final y = _u16(p, _offMfgDate), m = _u8(p, _offMfgDate + 2), d = _u8(p, _offMfgDate + 3);
      if (y != null && m != null && d != null) {
        mfgDate = '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
      }
    }

    final slicer = _materialToSlicer[(material ?? '').toUpperCase()] ?? '';
    final notes = <String>[];
    if (printTemp != null) {
      notes.add(bedTemp != null ? 'Print: ${printTemp * 5}C, Bed: ${bedTemp * 5}C' : 'Print temp: ${printTemp * 5}C');
    }
    if (densityRaw != null) notes.add('Density: ${(densityRaw / 1000).toStringAsFixed(2)} g/cm³');
    if (diameterUm != null) notes.add('Diameter: ${(diameterUm / 1000).toStringAsFixed(2)}mm');
    if (serial != null) notes.add('S/N: $serial');
    if (mfgDate != null) notes.add('Mfg: $mfgDate');
    if (url != null) notes.add('URL: $url');
    final missing = [
      if (material == null) 'Material',
      if (slicer.isEmpty) 'Slicer Filament',
      if (colorName == null && primary == null) 'Color',
      if (manufacturer == null) 'Brand',
    ];
    if (missing.isNotEmpty) notes.add('Missing: ${missing.join(', ')}');

    return SpoolFromTag(
      tagId: uidToBase64(uidHex),
      tagType: TagType.openTag3D,
      material: material,
      subtype: modifiers,
      colorName: colorName,
      rgba: primary,
      brand: manufacturer,
      labelWeight: weightG,
      slicerFilament: slicer.isEmpty ? null : slicer,
      note: notes.isEmpty ? null : notes.join('; '),
      dataOrigin: TagType.openTag3D,
    );
  }

  /// OpenTag3D 2.x (2.000 moved every field), which Bambuddy 1.3.1 writes on
  /// NTAG215/216. Bytes past the end of the payload read as 0, as the spec says.
  static SpoolFromTag? _decodeV2(String uidHex, Uint8List payload) {
    if (payload.length < 0x40) return null;
    final p = Uint8List(0xA2)..setRange(0, payload.length < 0xA2 ? payload.length : 0xA2, payload);
    final material = _str(p, 0x02, 5);
    final manufacturer = _str(p, 0x0C, 16);
    final colorName = _str(p, 0x1C, 32);
    final primary = _color(p, 0x3C);
    final diameterUm = _u16(p, 0x8C);
    final target = _u8(p, 0x90), min = _u8(p, 0x91), max = _u8(p, 0x92);
    final bed = _u8(p, 0x94);
    final densityRaw = _u16(p, 0x9C);
    final nozzle = min ?? target;

    final slicer = _materialToSlicer[(material ?? '').toUpperCase()] ?? '';
    final notes = <String>[
      if (min != null && max != null && max != min) 'Nozzle ${min * 5}–${max * 5} °C'
      else if (nozzle != null) 'Nozzle ${nozzle * 5} °C',
      if (bed != null) 'Bed ${bed * 5} °C',
      if (densityRaw != null) 'Density: ${(densityRaw / 1000).toStringAsFixed(2)} g/cm³',
      if (diameterUm != null) 'Diameter: ${(diameterUm / 1000).toStringAsFixed(2)}mm',
    ];

    return SpoolFromTag(
      tagId: uidToBase64(uidHex),
      tagType: TagType.openTag3D,
      material: material,
      subtype: _str(p, 0x07, 5),
      colorName: colorName,
      rgba: primary,
      brand: manufacturer,
      labelWeight: _u16(p, 0x9E),
      coreWeight: _u16(p, 0xA0),
      slicerFilament: slicer.isEmpty ? null : slicer,
      note: notes.isEmpty ? null : notes.join('; '),
      dataOrigin: TagType.openTag3D,
      nozzleTemp: nozzle == null ? null : nozzle * 5,
      bedTemp: bed == null ? null : bed * 5,
    );
  }

  /// Encode a spool to the OpenTag3D core region (fits NTAG213 and up).
  static Uint8List encode(Spool spool) {
    final p = Uint8List(_coreSize);
    void putStr(int off, int len, String? s) {
      if (s == null || s.isEmpty) return;
      final b = utf8.encode(s);
      p.setRange(off, off + (b.length < len ? b.length : len), b);
    }

    void putU16(int off, int v) {
      p[off] = (v >> 8) & 0xFF;
      p[off + 1] = v & 0xFF;
    }

    putU16(_offVersion, 0x0014);
    putStr(_offMaterial, 5, spool.material);
    putStr(_offModifiers, 5, spool.subtype);
    putStr(_offManufacturer, 16, spool.brand);
    putStr(_offColorName, 32, spool.colorName);
    final rgba = spool.rgba;
    if (rgba != null && RegExp(r'^[0-9a-fA-F]{6,8}$').hasMatch(rgba)) {
      final c = hexToBytes(rgba.length == 6 ? '${rgba}FF' : rgba);
      p.setRange(_offColorPrimary, _offColorPrimary + 4, c);
    }
    putU16(_offDiameter, 1750);
    if (spool.labelWeight != null && spool.labelWeight! > 0) putU16(_offWeight, spool.labelWeight!);
    return p;
  }
}
