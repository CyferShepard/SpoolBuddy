import 'dart:convert';
import 'dart:typed_data';

/// Tag data formats (upstream `TagType`).
class TagType {
  static const spoolEaseV1 = 'SpoolEaseV1';
  static const spoolEaseV2 = 'SpoolEaseV2';
  static const bambuLab = 'Bambu Lab';
  static const openPrintTag = 'OpenPrintTag';
  static const openSpool = 'OpenSpool';
  static const openTag3D = 'OpenTag3D';
  static const anycubic = 'Anycubic';
  static const unknown = 'Unknown';
}

/// Physical NFC tag types (upstream `NfcTagType`).
class NfcTagType {
  static const ntag = 'NTAG';
  static const mifareClassic1k = 'MifareClassic1K';
  static const unknown = 'Unknown';
}

/// Spool data extracted from any tag type, normalized for the database.
class SpoolFromTag {
  final String tagId;
  final String tagType;
  final String? material;
  final String? subtype;
  final String? colorName;
  final String? rgba;
  final String? brand;
  final int? labelWeight;
  final int? coreWeight;
  final int? weightNew;
  final String? slicerFilament;
  final String? slicerFilamentName;
  final String? note;
  final String? dataOrigin;

  /// Print temperatures as single values (°C). Where a tag gives a range, the
  /// nozzle takes the low end and the bed the high end.
  final int? nozzleTemp;
  final int? bedTemp;

  const SpoolFromTag({
    required this.tagId,
    required this.tagType,
    this.material,
    this.subtype,
    this.colorName,
    this.rgba,
    this.brand,
    this.labelWeight,
    this.coreWeight,
    this.weightNew,
    this.slicerFilament,
    this.slicerFilamentName,
    this.note,
    this.dataOrigin,
    this.nozzleTemp,
    this.bedTemp,
  });
}

/// Result of reading an NFC tag.
class TagReadResult {
  final String uid; // upper-case hex
  final String uidBase64; // url-safe base64 without padding (SpoolEase-compatible tag id)
  final String nfcType;
  final String tagType;
  final SpoolFromTag? spool;

  const TagReadResult({
    required this.uid,
    required this.uidBase64,
    required this.nfcType,
    required this.tagType,
    this.spool,
  });

  /// The id used to match the tag to a spool in the database.
  String get tagId => spool?.tagId ?? uidBase64;
}

/// One NDEF record: [type] as a string (e.g. "U", "application/json"), raw [payload].
class NdefRecordData {
  final String type;
  final Uint8List payload;
  const NdefRecordData(this.type, this.payload);
}

Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// URL-safe base64 of the UID with padding stripped (matches upstream `uid_base64`).
String uidToBase64(String uidHex) => base64Url.encode(hexToBytes(uidHex)).replaceAll('=', '');

/// Material -> generic Bambu slicer filament code, shared by OpenSpool/OpenTag3D/OpenPrintTag.
const materialToSlicerBase = {
  'PLA': 'GFL00',
  'PETG': 'GFL01',
  'ABS': 'GFL02',
  'ASA': 'GFL03',
  'PC': 'GFL04',
  'TPU': 'GFL05',
  'PVA': 'GFL06',
};
