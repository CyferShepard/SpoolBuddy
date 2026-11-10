import 'dart:convert';
import 'dart:typed_data';

import 'tag_models.dart';

/// Anycubic ACE RFID tags: NTAG213-compatible chips with the spool data in
/// raw pages (no NDEF), as read by the ACE Pro.
///
/// Layout (pages are 4 bytes; numbers little-endian):
///   4      7B 00 65 00 header
///   5-9    SKU, e.g. "AHPLDB-107"
///   10-14  brand, "AC" for Anycubic
///   15-19  material, e.g. "PLA"
///   20     colour as A, B, G, R
///   23     print speed min, max (mm/s)
///   24     nozzle temperature min, max (°C)
///   29     bed temperature min, max (°C)
///   30     diameter (mm × 100), length (m)
///   31     filament weight (g)
class Anycubic {
  static const firstPage = 4;
  static const lastPage = 31;
  static const _header = [0x7B, 0x00, 0x65, 0x00];

  static bool matches(Map<int, Uint8List> pages) {
    final h = pages[firstPage];
    return h != null && h.length >= 4 && List.generate(4, (i) => h[i]).join(',') == _header.join(',');
  }

  static SpoolFromTag? decode(String uidHex, Map<int, Uint8List> pages) {
    if (!matches(pages)) return null;

    String? text(int page) {
      final bytes = <int>[];
      for (var p = page; p < page + 5; p++) {
        final b = pages[p];
        if (b == null) break;
        bytes.addAll(b.take(4));
      }
      final s = utf8.decode(bytes.takeWhile((c) => c != 0).toList(), allowMalformed: true).trim();
      return s.isEmpty ? null : s;
    }

    int? u16(int page, int offset) {
      final b = pages[page];
      if (b == null || b.length < offset + 2) return null;
      final v = b[offset] | (b[offset + 1] << 8);
      return v == 0 ? null : v;
    }

    String hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    final c = pages[20];
    final rgba = (c == null || c.length < 4 || c.every((x) => x == 0))
        ? null
        : '${hex2(c[3])}${hex2(c[2])}${hex2(c[1])}${hex2(c[0])}';

    final sku = text(5);
    final brandCode = text(10);
    final nozzle = (u16(24, 0), u16(24, 2));
    final bed = (u16(29, 0), u16(29, 2));
    String? range((int?, int?) r, String unit) =>
        r.$1 == null ? null : (r.$2 == null || r.$2 == r.$1 ? '${r.$1} $unit' : '${r.$1}–${r.$2} $unit');
    final note = [
      if (range(nozzle, '°C') case final n?) 'Nozzle $n',
      if (range(bed, '°C') case final b?) 'Bed $b',
      if (sku != null) 'SKU $sku',
    ].join(' · ');

    return SpoolFromTag(
      tagId: uidToBase64(uidHex),
      tagType: TagType.anycubic,
      material: text(15),
      brand: brandCode == 'AC' ? 'Anycubic' : brandCode,
      rgba: rgba,
      labelWeight: u16(31, 0),
      note: note.isEmpty ? null : note,
      dataOrigin: TagType.anycubic,
      nozzleTemp: nozzle.$1 ?? nozzle.$2,
      bedTemp: bed.$2 ?? bed.$1,
    );
  }
}
