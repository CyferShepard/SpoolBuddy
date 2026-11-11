import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spoolbuddy/models/spool.dart';
import 'package:spoolbuddy/tags/anycubic.dart';
import 'package:spoolbuddy/tags/bambulab.dart';
import 'package:spoolbuddy/tags/cbor_lite.dart';
import 'package:spoolbuddy/tags/openprinttag.dart';
import 'package:spoolbuddy/tags/openspool.dart';
import 'package:spoolbuddy/tags/opentag3d.dart';
import 'package:spoolbuddy/tags/spoolease.dart';
import 'package:spoolbuddy/tags/tag_decoder.dart';
import 'package:spoolbuddy/tags/tag_models.dart';

const uid = '04AABBCCDD1122';

const spool = Spool(
  id: 'abc-123',
  material: 'PETG',
  subtype: 'HF',
  colorName: 'Ocean Blue',
  rgba: '1E90FFFF',
  brand: 'eSUN',
  labelWeight: 1000,
  coreWeight: 240,
  slicerFilament: 'GFG99',
  note: 'a & b = c',
);

void main() {
  test('uid base64 matches upstream (urlsafe, no padding)', () {
    expect(uidToBase64(uid), 'BKq7zN0RIg');
  });

  group('SpoolEase', () {
    test('decodes V2 URL', () {
      final s = SpoolEase.decode(
          'https://info.filament3d.org/V2/?TG=abc&M=PLA&MS=Matte&CC=FF0000FF&CN=Red&B=Bambu&WL=1000&WE=250&SC=GFA01&N=hello%20world',
          uid)!;
      expect(s.tagType, TagType.spoolEaseV2);
      expect(s.tagId, 'abc');
      expect(s.material, 'PLA');
      expect(s.subtype, 'Matte');
      expect(s.rgba, 'FF0000FF');
      expect(s.labelWeight, 1000);
      expect(s.coreWeight, 250);
      expect(s.note, 'hello world');
    });

    test('falls back to UID when TG missing', () {
      final s = SpoolEase.decode('https://info.filament3d.org/V2/?M=PETG', uid)!;
      expect(s.tagId, uidToBase64(uid));
    });

    test('rejects other URLs', () {
      expect(SpoolEase.decode('https://example.com/?M=PLA', uid), isNull);
    });

    test('encode/decode roundtrip', () {
      final url = SpoolEase.encode('TAGID', spool, encodeTime: 1700000000);
      final s = SpoolEase.decode(url, uid)!;
      expect(s.tagId, 'TAGID');
      expect(s.material, 'PETG');
      expect(s.brand, 'eSUN');
      expect(s.note, 'a & b = c');
      expect(s.coreWeight, 240);
    });
  });

  group('OpenSpool', () {
    test('decode', () {
      final payload = Uint8List.fromList(utf8.encode(
          '{"protocol":"openspool","version":"1.0","type":"PLA","color_hex":"ffaabb","brand":"Generic","min_temp":"200","max_temp":"220"}'));
      final s = OpenSpool.decode(uid, payload)!;
      expect(s.rgba, 'FFAABBFF');
      expect(s.slicerFilament, 'GFL00');
      expect(s.note, 'Temp: 200-220C');
    });

    test('rejects non-openspool json', () {
      expect(OpenSpool.decode(uid, Uint8List.fromList(utf8.encode('{"protocol":"x"}'))), isNull);
    });

    test('encode roundtrip', () {
      final s = OpenSpool.decode(uid, OpenSpool.encode(spool))!;
      expect(s.material, 'PETG');
      expect(s.rgba, '1E90FFFF');
      expect(s.brand, 'eSUN');
    });
  });

  group('OpenTag3D', () {
    test('encode roundtrip', () {
      final payload = OpenTag3D.encode(spool);
      expect(payload.length, 0x66);
      final s = OpenTag3D.decode(uid, payload)!;
      expect(s.material, 'PETG');
      expect(s.subtype, 'HF');
      expect(s.brand, 'eSUN');
      expect(s.colorName, 'Ocean Blue');
      expect(s.rgba, '1E90FFFF');
      expect(s.labelWeight, 1000);
      expect(s.note, contains('Diameter: 1.75mm'));
    });

    test('too short', () {
      expect(OpenTag3D.decode(uid, Uint8List(50)), isNull);
    });

    test('2.004, as Bambuddy 1.3.1 writes it', () {
      // Laid out like Bambuddy's test_opentag3d_v2_3500.py.
      final p = Uint8List(0xA2);
      void text(int off, int len, String s) => p.setRange(off, off + len, ascii.encode(s.padRight(len)));
      p[0] = 2004 >> 8;
      p[1] = 2004 & 0xFF;
      text(0x02, 5, 'PETG');
      text(0x07, 5, 'HF');
      text(0x0C, 16, 'Polymaker');
      text(0x1C, 32, 'Jade White');
      p.setRange(0x3C, 0x40, [0x00, 0xAE, 0x42, 0xFF]);
      p[0x8C] = 1750 >> 8;
      p[0x8D] = 1750 & 0xFF;
      p[0x90] = 46; // target 230
      p[0x91] = 46; // min 230
      p[0x92] = 52; // max 260
      p[0x94] = 14; // bed 70
      p[0x9E] = 1000 >> 8;
      p[0x9F] = 1000 & 0xFF;
      p[0xA1] = 250;

      final s = OpenTag3D.decode(uid, p)!;
      expect(s.material, 'PETG');
      expect(s.subtype, 'HF');
      expect(s.brand, 'Polymaker');
      expect(s.colorName, 'Jade White');
      expect(s.rgba, '00AE42FF');
      expect(s.labelWeight, 1000);
      expect(s.coreWeight, 250);
      expect(s.nozzleTemp, 230);
      expect(s.bedTemp, 70);
      expect(s.note, contains('Nozzle 230–260 °C'));
      expect(s.note, contains('Diameter: 1.75mm'));
    });
  });

  group('OpenPrintTag', () {
    test('decodes meta + main regions', () {
      // main: {9: 1 (PETG), 10: "PETG Galaxy Black", 11: "Prusament", 16: 1000, 18: 201, 19: h'112233'}
      final main = <int>[
        0xA6, //
        0x09, 0x01,
        0x0A, 0x71, ...utf8.encode('PETG Galaxy Black'),
        0x0B, 0x69, ...utf8.encode('Prusament'),
        0x10, 0x19, 0x03, 0xE8,
        0x12, 0x18, 0xC9,
        0x13, 0x43, 0x11, 0x22, 0x33,
      ];
      // meta: {0: 3} -> main region starts at offset 3
      final payload = Uint8List.fromList([0xA1, 0x00, 0x03, ...main]);
      final s = OpenPrintTag.decode(uid, payload)!;
      expect(s.material, 'PETG');
      expect(s.colorName, 'Galaxy Black');
      expect(s.brand, 'Prusament');
      expect(s.labelWeight, 1000);
      expect(s.coreWeight, 201);
      expect(s.rgba, '112233FF');
    });

    test('cbor ignores trailing bytes and handles indefinite maps', () {
      final v = CborLite.decode(Uint8List.fromList([0xBF, 0x01, 0x02, 0xFF, 0x00, 0x00]));
      expect(v, {1: 2});
    });
  });

  group('Anycubic', () {
    // Pages 4-31 read from a real Anycubic PLA tag (dark blue, SKU AHPLDB-107).
    const dump = '7B0065004148504C44422D3130370000000000000000000041430000000000000000000000000000'
        '00000000504C410000000000000000000000000000000000FF943500000000000000000032'
        '00C800BE00E6000000000000000000000000000000000037004100AF004A01E8030000';
    Map<int, Uint8List> pages() {
      final b = hexToBytes(dump);
      return {for (var i = 0; i < b.length ~/ 4; i++) 4 + i: Uint8List.sublistView(b, i * 4, i * 4 + 4)};
    }

    test('decodes brand, material, colour, weight and temperatures', () {
      final s = Anycubic.decode('5371D8FC420001', pages())!;
      expect(s.tagType, TagType.anycubic);
      expect(s.brand, 'Anycubic');
      expect(s.material, 'PLA');
      expect(s.rgba, '003594FF'); // stored A,B,G,R
      expect(s.labelWeight, 1000);
      expect(s.note, 'Nozzle 190–230 °C · Bed 55–65 °C · SKU AHPLDB-107');
      // Single values: the low end of the nozzle range, the high end of the bed's.
      expect(s.nozzleTemp, 190);
      expect(s.bedTemp, 65);
    });

    test('ignores tags without the Anycubic header, and missing pages', () {
      expect(Anycubic.decode('04AABBCC', {4: Uint8List.fromList([3, 0, 0xFE, 0])}), isNull);
      final partial = pages()..removeWhere((p, _) => p >= 20);
      final s = Anycubic.decode('5371D8FC420001', partial)!;
      expect(s.material, 'PLA');
      expect(s.rgba, isNull);
      expect(s.labelWeight, isNull);
    });
  });

  group('Bambu Lab', () {
    Map<int, Uint8List> blocks() {
      Uint8List block(List<int> data) => Uint8List(16)..setRange(0, data.length, data);
      return {
        1: block([...ascii.encode('A00-G1'), 0, 0, ...ascii.encode('GFA00')]),
        2: block(ascii.encode('PLA')),
        4: block(ascii.encode('PLA Basic')),
        5: block([0xFF, 0x00, 0x00, 0xFF, 0xFA, 0x00]),
      };
    }

    test('decode', () {
      final r = TagDecoder.decodeMifareBlocks('75886B1D', blocks());
      expect(r.tagType, TagType.bambuLab);
      final s = r.spool!;
      expect(s.material, 'PLA');
      expect(s.subtype, 'Basic');
      expect(s.brand, 'Bambu');
      expect(s.rgba, 'FF0000FF');
      expect(s.coreWeight, 250);
      expect(s.slicerFilament, 'GFA00');
      expect(s.tagId, uidToBase64('75886B1D'));
    });

    test('no material id -> unknown', () {
      final r = TagDecoder.decodeMifareBlocks('75886B1D', {1: Uint8List(16)});
      expect(r.tagType, TagType.unknown);
    });

    test('key derivation matches RFC 5869 HKDF reference', () {
      final keys = BambuLab.deriveKeys(hexToBytes('75886B1D'));
      expect(keys, hasLength(16));
      expect(bytesToHex(keys[0]), '6E5B0EC6EF7C');
      expect(bytesToHex(keys[1]), '4CE96076285F');
      expect(bytesToHex(keys[15]), 'D9805EEC7045');
    });
  });

  test('NDEF URL record dispatch', () {
    final url = utf8.encode('info.filament3d.org/V2/?M=ASA');
    final r = TagDecoder.decodeNdefRecords(uid, [NdefRecordData('U', Uint8List.fromList([0x04, ...url]))]);
    expect(r.tagType, TagType.spoolEaseV2);
    expect(r.spool!.material, 'ASA');
  });
}
