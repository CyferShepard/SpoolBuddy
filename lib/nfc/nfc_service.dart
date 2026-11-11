import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' show TypeNameFormat;

import '../models/spool.dart';
import '../tags/anycubic.dart';
import '../tags/bambulab.dart';
import '../tags/openspool.dart';
import '../tags/opentag3d.dart';
import '../tags/spoolease.dart';
import '../tags/tag_decoder.dart';
import '../tags/tag_models.dart';

enum TagWriteFormat { spoolEase, openSpool, openTag3D }

extension TagWriteFormatLabel on TagWriteFormat {
  String get label => switch (this) {
        TagWriteFormat.spoolEase => 'SpoolEase V2',
        TagWriteFormat.openSpool => 'OpenSpool',
        TagWriteFormat.openTag3D => 'OpenTag3D',
      };
}

class NfcException implements Exception {
  final String message;

  /// UID of the tag involved, when one was detected.
  final String? uidHex;
  NfcException(this.message, {this.uidHex});
  @override
  String toString() => message;
}

/// A tag as the Bambuddy SpoolBuddy daemon reports it.
class RawTagScan {
  final String uidHex;
  final int? sak;
  final String tagType; // "mifare_classic", "ntag" or "unknown"
  final String? trayUuid;
  final Map<String, String>? rawBlocks;

  /// What the phone could decode from the tag itself (Bambu blocks or an NDEF
  /// spool format), for pre-filling a new spool. Not sent to Bambuddy.
  final SpoolFromTag? decoded;
  const RawTagScan(this.uidHex, this.sak, this.tagType, {this.trayUuid, this.rawBlocks, this.decoded});
}

/// Reads and writes spool tags with the phone's NFC reader.
class NfcService {
  static const _pollTimeout = Duration(seconds: 20);

  Future<NFCAvailability> availability() => FlutterNfcKit.nfcAvailability;

  Future<void> cancel() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {}
  }

  /// Wait for a tag and decode it.
  Future<TagReadResult> readTag() async {
    final tag = await FlutterNfcKit.poll(timeout: _pollTimeout, readIso15693: false);
    try {
      final uidHex = tag.id.replaceAll(':', '').toUpperCase();
      if (tag.type == NFCTagType.mifare_classic) {
        return await _readBambu(uidHex);
      }
      if (tag.ndefAvailable ?? false) {
        final raw = await FlutterNfcKit.readNDEFRawRecords(cached: false);
        final records = raw
            .map((r) => NdefRecordData(utf8.decode(hexToBytes(r.type), allowMalformed: true), hexToBytes(r.payload)))
            .toList();
        return TagDecoder.decodeNdefRecords(uidHex, records);
      }
      final anycubic = Anycubic.decode(uidHex, await _readAnycubicPages());
      if (anycubic != null) return TagDecoder.result(uidHex, NfcTagType.ntag, anycubic);
      return TagDecoder.decodeNdefRecords(uidHex, const []);
    } finally {
      await cancel();
    }
  }

  Future<TagReadResult> _readBambu(String uidHex) async =>
      TagDecoder.decodeMifareBlocks(uidHex, await _readBambuBlocks(uidHex, BambuLab.blocksToRead));

  /// Wait for any tag and return what the Bambuddy SpoolBuddy daemon reports
  /// for it: chip UID and SAK, plus tray UUID and raw blocks for Bambu tags.
  Future<RawTagScan> scanRaw({Duration timeout = const Duration(seconds: 5)}) async {
    final tag = await FlutterNfcKit.poll(timeout: timeout, readIso15693: false);
    try {
      final uidHex = tag.id.replaceAll(':', '').toUpperCase();
      final sak = int.tryParse(tag.sak ?? '', radix: 16);
      final tagType = (sak == 0x08 || sak == 0x18 || tag.type == NFCTagType.mifare_classic)
          ? 'mifare_classic'
          : (sak == 0x00 || sak == 0x04 || tag.type == NFCTagType.mifare_ultralight)
              ? 'ntag'
              : 'unknown';
      if (tagType != 'mifare_classic') {
        SpoolFromTag? decoded;
        if (tag.ndefAvailable ?? false) {
          try {
            final raw = await FlutterNfcKit.readNDEFRawRecords(cached: false);
            decoded = TagDecoder.decodeNdefRecords(uidHex, [
              for (final r in raw)
                NdefRecordData(utf8.decode(hexToBytes(r.type), allowMalformed: true), hexToBytes(r.payload)),
            ]).spool;
          } catch (_) {}
        }
        if (decoded == null && tagType == 'ntag') decoded = Anycubic.decode(uidHex, await _readAnycubicPages());
        return RawTagScan(uidHex, sak, tagType, decoded: decoded);
      }
      try {
        final blocks = await _readBambuBlocks(uidHex, BambuLab.bambuddyBlocks);
        return RawTagScan(uidHex, sak, tagType,
            trayUuid: BambuLab.trayUuid(blocks),
            rawBlocks: {for (final e in blocks.entries) '${e.key}': bytesToHex(e.value)},
            decoded: BambuLab.decode(uidHex, blocks));
      } catch (_) {
        // Not a Bambu tag, or the read failed: report the UID alone, as the daemon does.
        return RawTagScan(uidHex, sak, tagType);
      }
    } finally {
      await cancel();
    }
  }

  /// Wait for an NTAG and write the NDEF records parsed from Bambuddy's tag image.
  /// [larger] is written instead when the tag holds its [largerSize] bytes
  /// (OpenTag3D v2 on an NTAG215/216, v1 on an NTAG213).
  /// Returns the tag UID (hex) and whether [larger] was written.
  /// Throws [NfcException] with a UID when the tag is unsuitable.
  Future<(String, bool)> writeNdefRecords(List<NDEFRawRecord> records,
      {List<NDEFRawRecord>? larger, int largerSize = 0, Duration timeout = const Duration(seconds: 30)}) async {
    final tag = await FlutterNfcKit.poll(timeout: timeout, readIso15693: false);
    try {
      final uidHex = tag.id.replaceAll(':', '').toUpperCase();
      if (tag.type == NFCTagType.mifare_classic) {
        throw NfcException('MIFARE Classic tags cannot be written. Use an NTAG215/216 tag.', uidHex: uidHex);
      }
      if (!(tag.ndefAvailable ?? false) || !(tag.ndefWritable ?? false)) {
        throw NfcException('This tag is not NDEF-writable.', uidHex: uidHex);
      }
      final useLarger = larger != null && largerSize <= (tag.ndefCapacity ?? 0);
      await FlutterNfcKit.writeNDEFRawRecords(useLarger ? larger : records);
      return (uidHex, useLarger);
    } finally {
      await cancel();
    }
  }

  /// Read an Anycubic tag's data pages with NTAG READ commands (4 pages each).
  /// Android exposes these non-NXP chips only as NfcA, and reads fail now and
  /// then, so each read is retried. Returns what was read; empty if the first
  /// read shows it isn't an Anycubic tag.
  Future<Map<int, Uint8List>> _readAnycubicPages() async {
    final pages = <int, Uint8List>{};
    for (var p = Anycubic.firstPage; p <= Anycubic.lastPage; p += 4) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final r = await FlutterNfcKit.transceive<Uint8List>(Uint8List.fromList([0x30, p]),
              timeout: const Duration(milliseconds: 500));
          if (r.length < 16) continue;
          for (var i = 0; i < 4; i++) {
            pages[p + i] = Uint8List.sublistView(r, i * 4, i * 4 + 4);
          }
          break;
        } catch (_) {}
      }
      if (p == Anycubic.firstPage && !Anycubic.matches(pages)) return const {};
    }
    return pages;
  }

  Future<Map<int, Uint8List>> _readBambuBlocks(String uidHex, List<int> blockList) async {
    final keys = BambuLab.deriveKeys(hexToBytes(uidHex));
    final blocks = <int, Uint8List>{};
    final authed = <int>{};
    for (final block in blockList) {
      final sector = block ~/ 4;
      if (!authed.contains(sector)) {
        final ok = await FlutterNfcKit.authenticateSector<Uint8List>(sector, keyA: keys[sector]);
        if (!ok) {
          throw NfcException('Could not authenticate MIFARE sector $sector. This may not be a Bambu Lab tag.');
        }
        authed.add(sector);
      }
      blocks[block] = await FlutterNfcKit.readBlock(block);
    }
    return blocks;
  }

  /// Wait for a writable NDEF tag and write [spool] to it in [format].
  /// Returns the tag's UID (hex) and the tag id stored in the database.
  Future<(String uidHex, String tagId)> writeSpool(Spool spool, TagWriteFormat format) async {
    final tag = await FlutterNfcKit.poll(timeout: _pollTimeout, readIso15693: false);
    try {
      if (tag.type == NFCTagType.mifare_classic) {
        throw NfcException('MIFARE Classic tags (e.g. Bambu Lab) cannot be written. Use an NTAG215/216 tag.');
      }
      if (!(tag.ndefAvailable ?? false) || !(tag.ndefWritable ?? false)) {
        throw NfcException('This tag is not NDEF-writable.');
      }
      final uidHex = tag.id.replaceAll(':', '').toUpperCase();
      final tagId = uidToBase64(uidHex);
      final record = _buildRecord(spool, format, tagId);
      final size = record.payload.length ~/ 2 + record.type.length ~/ 2 + 8;
      final capacity = tag.ndefCapacity;
      if (capacity != null && capacity > 0 && size > capacity) {
        throw NfcException('Data ($size bytes) does not fit on this tag ($capacity bytes).');
      }
      await FlutterNfcKit.writeNDEFRawRecords([record]);
      return (uidHex, tagId);
    } finally {
      await cancel();
    }
  }

  NDEFRawRecord _buildRecord(Spool spool, TagWriteFormat format, String tagId) {
    switch (format) {
      case TagWriteFormat.spoolEase:
        final url = SpoolEase.encode(tagId, spool, encodeTime: DateTime.now().millisecondsSinceEpoch ~/ 1000);
        // 0x04 = "https://" URI prefix code
        final payload = [0x04, ...utf8.encode(url.replaceFirst('https://', ''))];
        return NDEFRawRecord('', bytesToHex(payload), bytesToHex(utf8.encode('U')), TypeNameFormat.nfcWellKnown);
      case TagWriteFormat.openSpool:
        return NDEFRawRecord('', bytesToHex(OpenSpool.encode(spool)), bytesToHex(utf8.encode(OpenSpool.recordType)),
            TypeNameFormat.media);
      case TagWriteFormat.openTag3D:
        return NDEFRawRecord('', bytesToHex(OpenTag3D.encode(spool)), bytesToHex(utf8.encode(OpenTag3D.recordType)),
            TypeNameFormat.media);
    }
  }
}
