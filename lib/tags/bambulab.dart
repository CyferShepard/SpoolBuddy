import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'tag_models.dart';

/// Bambu Lab RFID tags: MIFARE Classic 1K (upstream `bambulab.py`).
class BambuLab {
  /// material_id -> (full name, material type), from BambuStudio filaments_color_codes.json.
  static const materials = {
    'GFA00': ('Bambu PLA Basic', 'PLA'),
    'GFA01': ('Bambu PLA Matte', 'PLA'),
    'GFA02': ('Bambu PLA Metal', 'PLA'),
    'GFA03': ('Bambu PLA Silk', 'PLA'),
    'GFA05': ('Bambu PLA Tough', 'PLA'),
    'GFA07': ('Bambu PLA Glow', 'PLA'),
    'GFA08': ('Bambu PLA Sparkle', 'PLA'),
    'GFA09': ('Bambu PLA Marble', 'PLA'),
    'GFA50': ('Bambu PLA-CF', 'PLA-CF'),
    'GFB00': ('Bambu ABS', 'ABS'),
    'GFB01': ('Bambu ASA', 'ASA'),
    'GFB60': ('Bambu ASA Aero', 'ASA'),
    'GFB98': ('Bambu ABS-GF', 'ABS-GF'),
    'GFB99': ('Support for ABS', 'Support'),
    'GFC00': ('Bambu PC', 'PC'),
    'GFG00': ('Bambu PETG Basic', 'PETG'),
    'GFG01': ('Bambu PETG Translucent', 'PETG'),
    'GFG50': ('Bambu PETG-CF', 'PETG-CF'),
    'GFN03': ('Bambu PA-CF', 'PA-CF'),
    'GFN04': ('Bambu PAHT-CF', 'PAHT-CF'),
    'GFN05': ('Bambu PA6-CF', 'PA6-CF'),
    'GFN06': ('Bambu PA6-GF', 'PA6-GF'),
    'GFS00': ('Bambu Support W', 'Support'),
    'GFS01': ('Bambu Support G', 'Support'),
    'GFT00': ('Bambu TPU 95A', 'TPU'),
    'GFU00': ('Bambu PLA-S', 'PLA'),
    'GFU01': ('Bambu PET-CF', 'PET-CF'),
    'GFL00': ('Generic PLA', 'PLA'),
    'GFL01': ('Generic PETG', 'PETG'),
    'GFL02': ('Generic ABS', 'ABS'),
    'GFL03': ('Generic ASA', 'ASA'),
    'GFL04': ('Generic PC', 'PC'),
    'GFL05': ('Generic TPU', 'TPU'),
    'GFL06': ('Generic PVA', 'PVA'),
    'GFL99': ('Generic Filament', 'PLA'),
  };

  /// Blocks the decoder needs (sectors 0, 1 and 4).
  static const blocksToRead = [1, 2, 4, 5, 16];

  /// Blocks the Bambuddy SpoolBuddy daemon reads and sends (`BAMBU_BLOCKS` in
  /// spoolbuddy/daemon/pn5180.py). Block 9 holds the tray UUID shared by both tags of a spool.
  static const bambuddyBlocks = [1, 2, 4, 5, 6, 9];

  /// Tray UUID from block 9: 16 bytes as 32 upper-case hex chars, or null if absent/blank.
  static String? trayUuid(Map<int, Uint8List> blocks) {
    final b = blocks[9];
    if (b == null || b.length < 16) return null;
    final hex = bytesToHex(b.sublist(0, 16));
    return hex == '0' * 32 ? null : hex;
  }

  /// Publicly documented Bambu Lab key derivation (Bambu Research Group RFID
  /// Tag Guide): HKDF-SHA256 with the tag UID as input key material, a fixed
  /// salt and info "RFID-A\0", yielding 16 six-byte sector A keys.
  static const _salt = [
    0x9a, 0x75, 0x9c, 0xf2, 0xc4, 0xf7, 0xca, 0xff, //
    0x22, 0x2c, 0xb9, 0x76, 0x9b, 0x41, 0xbc, 0x96,
  ];

  static List<Uint8List> deriveKeys(Uint8List uid) {
    final prk = Hmac(sha256, _salt).convert(uid).bytes;
    final info = [...ascii.encode('RFID-A'), 0];
    final okm = <int>[];
    var t = <int>[];
    for (var i = 1; okm.length < 16 * 6; i++) {
      t = Hmac(sha256, prk).convert([...t, ...info, i]).bytes;
      okm.addAll(t);
    }
    return [for (var s = 0; s < 16; s++) Uint8List.fromList(okm.sublist(s * 6, s * 6 + 6))];
  }

  static String _cstr(List<int> b) {
    final nul = b.indexOf(0);
    return utf8.decode(nul >= 0 ? b.sublist(0, nul) : b, allowMalformed: true);
  }

  /// Decode MIFARE blocks; returns null unless a material id is present.
  static SpoolFromTag? decode(String uidHex, Map<int, Uint8List> blocks) {
    final b1 = blocks[1];
    final materialId = (b1 != null && b1.length >= 16) ? _cstr(b1.sublist(8, 16)) : null;
    if (materialId == null || materialId.isEmpty) return null;

    final filamentType = blocks[2] != null ? _cstr(blocks[2]!) : null;
    final detailedType = blocks[4] != null ? _cstr(blocks[4]!) : null;
    final b5 = blocks[5];
    final colorRgba = (b5 != null && b5.length >= 4) ? bytesToHex(b5.sublist(0, 4)) : null;
    int? spoolWeight;
    if (b5 != null && b5.length >= 6) {
      spoolWeight = b5[4] | (b5[5] << 8);
      if (spoolWeight == 0) spoolWeight = null;
    }

    var materialType = (filamentType == null || filamentType.isEmpty) ? 'PLA' : filamentType;
    var subtype = '';
    var brand = 'Bambu';
    final known = materials[materialId];
    if (known != null) {
      final (fullName, matType) = known;
      materialType = matType;
      final prefix = 'Bambu $matType ';
      if (fullName.startsWith(prefix)) {
        subtype = fullName.substring(prefix.length);
      } else if (fullName.startsWith('Generic')) {
        brand = 'Generic';
      }
    }

    final colorName = (detailedType != null && detailedType.isNotEmpty && colorRgba != null)
        ? detailedType
        : '(Unknown Color)';
    final missing = [if (colorRgba == null) 'Color', if (spoolWeight == null) 'Spool Weight'];

    return SpoolFromTag(
      // Upstream matches every tag type to spools by base64 UID, so use it here too.
      tagId: uidToBase64(uidHex),
      tagType: TagType.bambuLab,
      material: materialType,
      subtype: subtype,
      colorName: colorName,
      rgba: colorRgba,
      brand: brand,
      labelWeight: materialId.startsWith('GF') ? 1000 : null,
      coreWeight: spoolWeight,
      slicerFilament: materialId,
      slicerFilamentName: known?.$1,
      note: missing.isEmpty ? null : 'Missing: ${missing.join(', ')}',
      dataOrigin: TagType.bambuLab,
    );
  }
}
