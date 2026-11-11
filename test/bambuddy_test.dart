import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spoolbuddy/bambuddy/api_models.dart';
import 'package:spoolbuddy/bambuddy/bambuddy_client.dart';
import 'package:spoolbuddy/bambuddy/companion.dart';
import 'package:spoolbuddy/bambuddy/ndef_tlv.dart';
import 'package:spoolbuddy/data/database.dart';
import 'package:spoolbuddy/nfc/nfc_service.dart';
import 'package:spoolbuddy/tags/bambulab.dart';
import 'package:spoolbuddy/tags/opentag3d.dart';
import 'package:spoolbuddy/models/spool.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Bambuddy's backend/app/services/opentag3d.py `_encode_ndef`, reproduced.
Uint8List bambuddyEncodeNdef(Uint8List payload) {
  final mime = ascii.encode('application/opentag3d');
  final record = [0xD2, mime.length, payload.length, ...mime, ...payload];
  final tlv = record.length < 0xFF ? [0x03, record.length] : [0x03, 0xFF, record.length >> 8, record.length & 0xFF];
  return Uint8List.fromList([0xE1, 0x10, 0x12, 0x00, ...tlv, ...record, 0xFE]);
}

class _Recorder {
  final calls = <http.Request>[];
  final Map<String, (int, Object)> responses = {};

  MockClient get client => MockClient((req) async {
        calls.add(req);
        final r = responses.entries.where((e) => req.url.path.endsWith(e.key)).firstOrNull?.value ?? (200, {});
        return http.Response(jsonEncode(r.$2), r.$1, headers: {'content-type': 'application/json'});
      });

  Map<String, dynamic> body(int i) => jsonDecode(calls[i].body) as Map<String, dynamic>;
}

void main() {
  sqfliteFfiInit();

  group('NDEF TLV', () {
    test('parses Bambuddy write image back to the OpenTag3D record', () {
      const spool = Spool(id: '1', material: 'PLA', brand: 'Anycubic', rgba: 'FF0000FF', labelWeight: 1000);
      final payload = OpenTag3D.encode(spool);
      final records = parseNdefTlv(bambuddyEncodeNdef(payload));
      expect(records, hasLength(1));
      expect(records.single.tnf, 2); // media
      expect(ascii.decode(records.single.type), 'application/opentag3d');
      expect(records.single.payload, payload);
      expect(OpenTag3D.decode('04AABBCCDD1122', records.single.payload)!.brand, 'Anycubic');
    });

    test('handles 3-byte TLV length and no capability container', () {
      final payload = Uint8List(300);
      final mime = ascii.encode('application/x');
      final record = [0xC2, mime.length, 0, 0, 0x01, 0x2C, ...mime, ...payload]; // long record
      final data = Uint8List.fromList([0x03, 0xFF, record.length >> 8, record.length & 0xFF, ...record, 0xFE]);
      expect(parseNdefTlv(data).single.payload.length, 300);
    });

    test('rejects data without an NDEF TLV', () {
      expect(() => parseNdefTlv(Uint8List.fromList([0xE1, 0x10, 0x12, 0x00, 0xFE])), throwsFormatException);
    });
  });

  test('tray UUID comes from block 9 and is shared by both tags', () {
    final b9 = Uint8List.fromList(List.generate(16, (i) => i * 17));
    expect(BambuLab.trayUuid({9: b9}), '00112233445566778899AABBCCDDEEFF');
    expect(BambuLab.trayUuid({9: Uint8List(16)}), isNull);
    expect(BambuLab.trayUuid({}), isNull);
  });

  group('client', () {
    test('sends X-API-Key and daemon-shaped bodies', () async {
      final rec = _Recorder();
      final c = BambuddyClient('192.168.1.5:8000/', 'KEY', httpClient: rec.client);
      expect(c.baseUrl, 'http://192.168.1.5:8000');

      await c.tagScanned(
          deviceId: 'sb-x', tagUid: '75886B1D', sak: 8, tagType: 'mifare_classic', trayUuid: 'AB' * 16, rawBlocks: {'9': 'AB' * 16});
      final req = rec.calls.single;
      expect(req.url.toString(), 'http://192.168.1.5:8000/api/v1/spoolbuddy/nfc/tag-scanned');
      expect(req.headers['X-API-Key'], 'KEY');
      expect(rec.body(0), {
        'device_id': 'sb-x',
        'tag_uid': '75886B1D',
        'sak': 8,
        'tag_type': 'mifare_classic',
        'tray_uuid': 'AB' * 16,
        'raw_blocks': {'9': 'AB' * 16},
      });
    });

    test('maps errors', () async {
      final rec = _Recorder()
        ..responses['/heartbeat'] = (404, {'detail': 'Device not registered'})
        ..responses['/register'] = (401, {'detail': 'Invalid API key'});
      final c = BambuddyClient('http://h', 'K', httpClient: rec.client);
      await expectLater(
          c.heartbeat(deviceId: 'd', uptimeS: 1, nfcOk: true, firmwareVersion: 'v'),
          throwsA(isA<BambuddyException>().having((e) => e.unregistered, 'unregistered', isTrue)));
      await expectLater(
          c.register(deviceId: 'd', hostname: 'h', ipAddress: '1.1.1.1', firmwareVersion: 'v'),
          throwsA(isA<BambuddyException>().having((e) => e.message, 'message', 'API key rejected')));
    });
  });

  group('inventory API', () {
    test('sets temperatures on the Spoolman filament of a spool', () async {
      final rec = _Recorder()
        ..responses['/settings/spoolman'] = (200, {'spoolman_enabled': 'true', 'spoolman_url': 'http://spoolman:7912/'})
        ..responses['/spool/12'] = (200, {
          'id': 12,
          'filament': {'id': 6}
        });
      final c = BambuddyClient('http://b', 'K', httpClient: rec.client);
      await c.setSpoolmanFilamentTemps(12, extruder: 190, bed: 65);
      expect(rec.calls.map((r) => '${r.method} ${r.url}'), [
        'GET http://b/api/v1/settings/spoolman',
        'GET http://spoolman:7912/api/v1/spool/12',
        'PATCH http://spoolman:7912/api/v1/filament/6',
      ]);
      expect(rec.calls[2].headers.containsKey('X-API-Key'), isFalse); // Bambuddy's key stays with Bambuddy
      expect(rec.body(2), {'settings_extruder_temp': 190, 'settings_bed_temp': 65});

      rec.responses['/settings/spoolman'] = (200, {'spoolman_enabled': 'false', 'spoolman_url': ''});
      expect(() => c.setSpoolmanFilamentTemps(12, extruder: 190), throwsA(isA<BambuddyException>()));
    });

    test('picks Spoolman or built-in endpoints and request shapes', () async {
      final rec = _Recorder()
        ..responses['/inventory/spools'] = (200, [
          {'id': 3, 'material': 'PLA', 'brand': 'Anycubic', 'label_weight': 1000, 'weight_used': 250.5, 'rgba': 'FF0000FF'}
        ]);
      final c = BambuddyClient('http://b', 'K', httpClient: rec.client);

      final local = await c.spools(spoolman: false);
      expect(rec.calls.last.url.path, '/api/v1/inventory/spools');
      expect(local.single.remaining, closeTo(749.5, 0.01));
      expect(local.single.title, 'Anycubic PLA');

      await c.spools(spoolman: true);
      expect(rec.calls.last.url.path, '/api/v1/spoolman/inventory/spools');

      await c.assignSlot(3, 1, 0, 2, spoolman: true);
      expect(rec.calls.last.url.path, '/api/v1/spoolman/inventory/slot-assignments');
      expect(rec.body(rec.calls.length - 1), {'spoolman_spool_id': 3, 'printer_id': 1, 'ams_id': 0, 'tray_id': 2});

      await c.assignSlot(3, 1, 0, 2, spoolman: false);
      expect(rec.body(rec.calls.length - 1), {'spool_id': 3, 'printer_id': 1, 'ams_id': 0, 'tray_id': 2});

      await c.unassignSlot(spoolId: 3, printerId: 1, amsId: 0, trayId: 2, spoolman: true);
      expect((rec.calls.last.method, rec.calls.last.url.path), ('DELETE', '/api/v1/spoolman/inventory/slot-assignments/3'));
      await c.unassignSlot(spoolId: 3, printerId: 1, amsId: 0, trayId: 2, spoolman: false);
      expect(rec.calls.last.url.path, '/api/v1/inventory/assignments/1/0/2');

      await c.linkTag(3, tagUid: '04AABB', spoolman: true);
      expect((rec.calls.last.method, rec.calls.last.url.path), ('PATCH', '/api/v1/spoolman/inventory/spools/3/tag'));
      expect(rec.body(rec.calls.length - 1), {'tag_uid': '04AABB'});
      await c.linkTag(3, tagUid: '04AABB', trayUuid: 'AB' * 16, spoolman: false);
      expect(rec.calls.last.url.path, '/api/v1/inventory/spools/3/link-tag');
      expect(rec.body(rec.calls.length - 1), {'tag_uid': '04AABB', 'tray_uuid': 'AB' * 16});
    });

    test('Spoolman mode comes from /settings/spoolman', () async {
      final rec = _Recorder()..responses['/settings/spoolman'] = (200, {'spoolman_enabled': 'true', 'spoolman_url': 'http://sm'});
      expect(await BambuddyClient('http://b', 'K', httpClient: rec.client).spoolmanMode(), isTrue);
      rec.responses['/settings/spoolman'] = (200, {'spoolman_enabled': 'false', 'spoolman_url': ''});
      expect(await BambuddyClient('http://b', 'K', httpClient: rec.client).spoolmanMode(), isFalse);
    });

    test('structured error details become readable messages', () async {
      final rec = _Recorder()
        ..responses['/tag'] = (409, {
          'detail': {'code': 'tag_already_linked', 'message': 'tag_uid is linked to spool 9'}
        });
      await expectLater(
        BambuddyClient('http://b', 'K', httpClient: rec.client).linkTag(1, tagUid: 'AA', spoolman: true),
        throwsA(isA<BambuddyException>().having((e) => e.message, 'message', 'tag_uid is linked to spool 9')),
      );
    });

    test('detects the slot a spool was just loaded into', () {
      BPrinterStatus status(List<Map<String, dynamic>> trays, {Map<String, dynamic>? ext}) => BPrinterStatus.fromJson({
            'id': 1,
            'connected': true,
            'ams': [
              {'id': 0, 'tray': trays}
            ],
            'vt_tray': [ext ?? {'id': 254, 'state': 9}],
          });
      final before = status([
        {'id': 0, 'tray_type': 'PLA', 'exists': true},
        {'id': 1, 'exists': false, 'state': 9},
        {'id': 2, 'state': 9}, // no presence bit: falls back to state
        {'id': 3}, // nothing known: falls back to filament type
      ]);
      expect(newlyLoadedSlots(before, before), isEmpty);
      // A non-RFID spool: present, but no filament type yet.
      expect(
          newlyLoadedSlots(before, status([
            {'id': 0, 'tray_type': 'PLA', 'exists': true},
            {'id': 1, 'exists': true, 'state': 10},
            {'id': 2, 'state': 9},
            {'id': 3},
          ])),
          [(0, 1)]);
      expect(
          newlyLoadedSlots(before, status([
            {'id': 0, 'exists': false}, // unloaded, not loaded
            {'id': 1, 'exists': false},
            {'id': 2, 'state': 11},
            {'id': 3, 'tray_type': 'PETG'},
          ])),
          [(0, 2), (0, 3)]);
      expect(
          newlyLoadedSlots(before, status(before.ams.first.trays.map((_) => <String, dynamic>{}).toList(),
              ext: {'id': 254, 'state': 11})),
          [(externalAmsId, 0)]);
    });

    test('H3C: per-hotend external inputs and AMS 3H slots', () {
      BPrinterStatus h3c(bool loaded) => BPrinterStatus.fromJson({
            'id': 1,
            'connected': true,
            'ams': [
              {
                'id': 32,
                'tray': [for (var i = 0; i < 9; i++) {'id': i, 'state': loaded && i == 6 ? 11 : 9}]
              }
            ],
            'vt_tray': [
              for (final id in [247, 252, 254, 255]) {'id': id, 'state': loaded && id == 252 ? 11 : 9}
            ],
          });
      expect(newlyLoadedSlots(h3c(false), h3c(true)), [(32, 6), (externalAmsId, 7)]);
      expect([for (final id in [254, 255, 247, 253]) externalSlotIndex(id)], [0, 1, 2, 8]);
      expect(externalLabel(252, 9), 'Ext 4'); // feeds hotend 3
      expect(h3c(false).ams.single.label, 'AMS 3H');
      expect(amsSlotLabel(32, 6), '3H-7');
    });

    test('printer status parses AMS and external trays', () {
      final s = BPrinterStatus.fromJson({
        'id': 1,
        'name': 'P2S',
        'connected': true,
        'ams': [
          {
            'id': 0,
            'humidity': 32,
            'temp': 29.2,
            'is_ams_ht': false,
            'tray': [
              {'id': 0, 'tray_type': 'PLA', 'tray_color': 'FFFFFFFF', 'remain': 80},
              {'id': 1, 'tray_type': null, 'exists': false},
            ]
          }
        ],
        'vt_tray': [
          {'id': 254, 'tray_type': null}
        ],
      });
      expect(s.ams.single.label, 'AMS A');
      expect(s.ams.single.slotLabel(s.ams.single.trays[0]), 'A1');
      expect(s.ams.single.trays[1].isEmpty, isTrue);
      expect(s.vtTrays.single.id, 254);
    });
  });

  group('companion', () {
    late AppDatabase db;
    late _Recorder rec;
    late BambuddyCompanion companion;

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
      rec = _Recorder();
      companion = BambuddyCompanion(db, NfcService(),
          clientFactory: (url, key) => BambuddyClient(url, key, httpClient: rec.client));
    });
    tearDown(() => db.db.close());

    test('pair registers, persists settings and keeps the device id on reload', () async {
      await companion.pair('http://bambuddy:8000', ' KEY ', 'Phone');
      expect(companion.paired, isTrue);
      final reg = rec.body(0);
      expect(rec.calls[0].url.path, '/api/v1/spoolbuddy/devices/register');
      expect(reg['device_id'], startsWith('sb-android-'));
      expect(reg['hostname'], 'Phone');
      expect(reg['has_scale'], isFalse);
      expect(rec.calls[0].headers['X-API-Key'], 'KEY');

      final again = BambuddyCompanion(db, NfcService(),
          clientFactory: (url, key) => BambuddyClient(url, key, httpClient: rec.client));
      await again.load();
      expect(again.paired, isTrue);
      expect(again.deviceId, reg['device_id']);
      expect(again.url, 'http://bambuddy:8000');
    });

    test('failed pairing saves nothing', () async {
      rec.responses['/register'] = (401, {'detail': 'nope'});
      await expectLater(companion.pair('http://bambuddy', 'BAD', 'P'), throwsA(isA<BambuddyException>()));
      expect(companion.paired, isFalse);
      expect(await db.getSetting('bambuddy_url'), isNull);
    });

    test('heartbeat commands: write_tag queued once, unsupported ones answered', () async {
      await companion.pair('http://b', 'K', 'P');
      rec.calls.clear();
      final image = bambuddyEncodeNdef(Uint8List(102));
      final hb = {
        'pending_command': 'write_tag',
        'pending_write_payload': {'spool_id': 7, 'ndef_data_hex': bytesToHexLower(image)},
      };
      await companion.handleCommandForTest(hb);
      expect(companion.pendingWrite!.spoolId, 7);
      expect(companion.pendingWrite!.ndefData, image);
      expect(companion.pendingWrite!.ndefV2, isNull);

      // A reply to a heartbeat sent before that write finished brings the
      // same command again; it isn't run twice. A later one is a new request.
      final sentBefore = companion.writesDone;
      await companion.cancelWrite();
      await companion.handleCommandForTest(hb, sentBefore);
      expect(companion.pendingWrite, isNull);
      final v2 = bambuddyEncodeNdef(Uint8List(0xA2));
      await companion.handleCommandForTest({
        'pending_command': 'write_tag',
        'pending_write_payload': {
          'spool_id': 7,
          'ndef_data_hex': bytesToHexLower(image),
          'ndef_v2_hex': bytesToHexLower(v2),
        },
      });
      expect(companion.pendingWrite!.ndefV2, v2);
      // The v2 message is measured as Android counts a tag's capacity.
      expect(ndefMessageSize(parseNdefTlv(v2)), 186); // over an NTAG213's 137

      await companion.handleCommandForTest({'pending_command': 'apply_system_config'});
      expect(rec.calls.last.url.path, endsWith('/system/command-result'));
      expect(rec.body(rec.calls.length - 1)['success'], isFalse);

      await companion.handleCommandForTest({'pending_command': 'run_scale_diag'});
      expect(rec.calls.last.url.path, endsWith('/diagnostics/${companion.deviceId}/result'));
      expect(rec.body(rec.calls.length - 1)['diagnostic'], 'scale');
    });
  });
}

String bytesToHexLower(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
