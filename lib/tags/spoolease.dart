import '../models/spool.dart';
import 'tag_models.dart';

/// SpoolEase V1/V2 NDEF URL tags (upstream `spoolease_format.py`).
class SpoolEase {
  static const prefixV1 = 'https://info.filament3d.org/V1';
  static const prefixV2 = 'https://info.filament3d.org/V2/';
  static const _prefixAlt = 'info.filament3d.org';

  static bool canDecode(String url) =>
      url.contains(prefixV1) || url.contains(prefixV2) || url.contains(_prefixAlt);

  static SpoolFromTag? decode(String url, String uidHex) {
    if (!canDecode(url)) return null;
    final q = url.indexOf('?');
    if (q < 0) return null;
    final version = url.contains('V2') ? 2 : 1;

    final params = <String, String>{};
    for (final part in url.substring(q + 1).split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final key = eq < 0 ? part : part.substring(0, eq);
      if (params.containsKey(key)) continue; // first value wins, like parse_qs()[0]
      final raw = eq < 0 ? '' : part.substring(eq + 1);
      try {
        params[key] = Uri.decodeQueryComponent(raw);
      } catch (_) {
        params[key] = raw;
      }
    }
    String? s(String k) => (params[k]?.isNotEmpty ?? false) ? params[k] : null;
    int? n(String k) => int.tryParse(s(k) ?? '');

    final type = version == 2 ? TagType.spoolEaseV2 : TagType.spoolEaseV1;
    return SpoolFromTag(
      tagId: s('TG') ?? uidToBase64(uidHex),
      tagType: type,
      material: s('M'),
      subtype: s('MS'),
      colorName: s('CN'),
      rgba: s('CC'),
      brand: s('B'),
      labelWeight: n('WL'),
      coreWeight: n('WE'),
      weightNew: n('WF'),
      slicerFilament: s('SC'),
      slicerFilamentName: s('SN'),
      note: s('N'),
      dataOrigin: type,
    );
  }

  /// Encode a spool as a SpoolEase V2 URL.
  static String encode(String tagId, Spool spool, {int? encodeTime}) {
    final params = <String>[];
    void add(String k, Object? v) {
      if (v == null || v == '') return;
      params.add('$k=${Uri.encodeComponent(v.toString())}');
    }

    add('TG', tagId);
    add('ID', spool.id);
    add('DE', encodeTime);
    add('DA', spool.addedTime);
    add('M', spool.material);
    add('MS', spool.subtype);
    add('CC', spool.rgba);
    add('CN', spool.colorName);
    add('B', spool.brand);
    add('WL', spool.labelWeight);
    add('WE', spool.coreWeight);
    add('WF', spool.weightNew);
    add('SC', spool.slicerFilament);
    add('SN', spool.slicerFilamentName);
    add('N', spool.note);
    return '$prefixV2?${params.join('&')}';
  }
}
