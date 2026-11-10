import 'dart:convert';
import 'dart:typed_data';

import 'bambulab.dart';
import 'openprinttag.dart';
import 'openspool.dart';
import 'opentag3d.dart';
import 'spoolease.dart';
import 'tag_models.dart';

/// Unified decoder for all supported tag types (upstream `tags/decoder.py`).
class TagDecoder {
  static const _urlPrefixes = [
    '', 'http://www.', 'https://www.', 'http://', 'https://', 'tel:', 'mailto:', //
    'ftp://anonymous:anonymous@', 'ftp://ftp.', 'ftps://', 'sftp://', 'smb://', 'nfs://',
    'ftp://', 'dav://', 'news:', 'telnet://', 'imap:', 'rtsp://', 'urn:', 'pop:', 'sip:',
    'sips:', 'tftp:', 'btspp://', 'btl2cap://', 'btgoep://', 'tcpobex://', 'irdaobex://',
    'file://', 'urn:epc:id:', 'urn:epc:tag:', 'urn:epc:pat:', 'urn:epc:raw:', 'urn:epc:',
    'urn:nfc:',
  ];

  static String? decodeUrlPayload(Uint8List payload) {
    if (payload.isEmpty) return null;
    final prefix = payload[0] < _urlPrefixes.length ? _urlPrefixes[payload[0]] : '';
    return prefix + utf8.decode(payload.sublist(1), allowMalformed: true);
  }

  static TagReadResult result(String uidHex, String nfcType, SpoolFromTag? spool) => TagReadResult(
        uid: uidHex.toUpperCase(),
        uidBase64: uidToBase64(uidHex),
        nfcType: nfcType,
        tagType: spool?.tagType ?? TagType.unknown,
        spool: spool,
      );

  static TagReadResult decodeNdefRecords(String uidHex, List<NdefRecordData> records) {
    for (final r in records) {
      SpoolFromTag? spool;
      if (r.type == OpenPrintTag.recordType) {
        spool = OpenPrintTag.decode(uidHex, r.payload);
      } else if (r.type == OpenSpool.recordType) {
        spool = OpenSpool.decode(uidHex, r.payload);
      } else if (r.type == OpenTag3D.recordType) {
        spool = OpenTag3D.decode(uidHex, r.payload);
      } else if (r.type == 'U' || r.type.startsWith('urn:nfc:wkt:U')) {
        final url = decodeUrlPayload(r.payload);
        if (url != null) spool = SpoolEase.decode(url, uidHex);
      }
      if (spool != null) return result(uidHex, NfcTagType.ntag, spool);
    }
    return result(uidHex, NfcTagType.ntag, null);
  }

  static TagReadResult decodeMifareBlocks(String uidHex, Map<int, Uint8List> blocks) =>
      result(uidHex, NfcTagType.mifareClassic1k, BambuLab.decode(uidHex, blocks));
}
