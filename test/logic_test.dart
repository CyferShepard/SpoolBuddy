import 'package:flutter_test/flutter_test.dart';
import 'package:spoolbuddy/data/database.dart';
import 'package:spoolbuddy/models/printer.dart';
import 'package:spoolbuddy/models/spool.dart';
import 'package:spoolbuddy/printers/printer_connection.dart';
import 'package:spoolbuddy/printers/printer_manager.dart';
import 'package:spoolbuddy/printers/usage_tracker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('database', () {
    late AppDatabase db;
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    });
    tearDown(() => db.db.close());

    test('seeds catalogs', () async {
      expect((await db.getSpoolCatalog()).length, greaterThan(80));
      expect((await db.getColorCatalog()).length, greaterThan(100));
    });

    test('spool numbers increment and weights recalc like upstream', () async {
      final a = await db.createSpool(SpoolInput(material: 'PLA', labelWeight: 1000, coreWeight: 250));
      final b = await db.createSpool(SpoolInput(material: 'PETG'));
      expect(a.spoolNumber, 1);
      expect(b.spoolNumber, 2);

      // gross 750 = 250 core + 500 net -> used 500
      var s = (await db.setSpoolWeight(a.id, 750))!;
      expect(s.weightUsed, 500);
      expect(s.netWeight, 500);
      expect(s.remainingPercent, 50);

      // print consumption on top of weighing
      s = (await db.updateSpoolConsumption(a.id, 100))!;
      expect(s.consumedSinceWeight, 100);
      expect(s.weightCurrent, 650);
      expect(s.netWeight, 400);

      // below core weight -> empty
      s = (await db.setSpoolWeight(a.id, 100))!;
      expect(s.netWeight, 0);
    });

    test('tag lookup skips archived spools and linking moves the tag', () async {
      final a = await db.createSpool(SpoolInput(material: 'PLA', tagId: 'T1'));
      expect((await db.getSpoolByTag('T1'))!.id, a.id);
      await db.archiveSpool(a.id);
      expect(await db.getSpoolByTag('T1'), isNull);

      final b = await db.createSpool(SpoolInput(material: 'PLA'));
      await db.linkTagToSpool(b.id, 'T1');
      expect((await db.getSpool(a.id))!.tagId, isNull);
      expect((await db.getSpoolByTag('T1'))!.id, b.id);
    });

    test('slot assignments', () async {
      await db.upsertPrinter(const Printer(serial: 'P1', ipAddress: '1.2.3.4', accessCode: 'x'));
      final a = await db.createSpool(SpoolInput(material: 'PLA'));
      await db.assignSpoolToSlot(a.id, 'P1', 0, 2);
      expect(await db.getSpoolForSlot('P1', 0, 2), a.id);
      expect((await db.getSlotAssignments('P1'))[(0, 2)], a.id);
      await db.unassignSlot('P1', 0, 2);
      expect(await db.getSpoolForSlot('P1', 0, 2), isNull);
    });
  });

  group('MQTT report parsing', () {
    PrinterConnection conn() =>
        PrinterConnection(serial: 'S', ipAddress: '1.2.3.4', accessCode: 'x', onChanged: (_) {});

    test('parses AMS, progress and stage', () {
      final c = conn();
      c.handleMessage({
        'print': {
          'gcode_state': 'RUNNING',
          'mc_percent': 42,
          'stg_cur': 2,
          'subtask_name': 'benchy',
          'ams': {
            'tray_now': '1',
            'tray_reading_bits': '0',
            'ams': [
              {
                'id': '0',
                'humidity': '4',
                'humidity_raw': '23',
                'temp': '25.4',
                'tray': [
                  {'id': '0', 'tray_type': 'PLA', 'tray_color': 'FF0000FF', 'remain': 80, 'k': 0.02},
                  {'id': '1'},
                ],
              }
            ],
          },
        }
      });
      final s = c.state;
      expect(s.gcodeState, 'RUNNING');
      expect(s.printProgress, 42);
      expect(s.stgCurName, 'Heatbed preheating');
      expect(s.trayNow, 1);
      final u = s.amsUnits.single;
      expect(u.humidity, 23);
      expect(u.temperature, 25.4);
      expect(u.trays[0].kValue, 0.02);
      expect(u.trays[0].remain, 80);
      expect(u.trays[1].isEmpty, isTrue);
    });

    test('dual nozzle snow decoding', () {
      final c = conn();
      c.handleMessage({
        'print': {
          'device': {
            'extruder': {
              'state': 0x10,
              'info': [
                {'id': 0, 'snow': (1 << 8) | 2, 'dia': 0.4},
                {'id': 1, 'snow': 0xFFFF},
              ],
            }
          }
        }
      });
      expect(c.state.nozzleCount, 2);
      expect(c.state.trayNowRight, 6);
      expect(c.state.trayNowLeft, 255);
      expect(c.state.activeExtruder, 1);
    });

    test('calibration response populates K lookup by cali_idx', () {
      final c = conn();
      c.handleMessage({
        'print': {
          'command': 'extrusion_cali_get',
          'nozzle_diameter': '0.4',
          'filaments': [
            {'cali_idx': 5, 'filament_id': 'GFA00', 'k_value': '0.025', 'name': 'PLA fast'}
          ],
        }
      });
      c.handleMessage({
        'print': {
          'ams': {
            'ams': [
              {
                'id': 0,
                'tray': [
                  {'id': 0, 'tray_type': 'PLA', 'cali_idx': 5}
                ]
              }
            ]
          }
        }
      });
      expect(c.state.amsUnits.single.trays.single.kValue, 0.025);
    });
  });

  group('usage tracker', () {
    PrinterState state(String gcode, int remain) => PrinterState()
      ..gcodeState = gcode
      ..subtaskName = 'job'
      ..amsUnits = [
        AmsUnit(id: 0, trays: [AmsTray(amsId: 0, trayId: 1, trayType: 'PLA', remain: remain)])
      ];

    test('reports remain% delta at print end', () async {
      Map<(int, int), int>? got;
      final t = UsageTracker((serial, name, usage) async => got = usage);
      t.onStateUpdate('S', state('IDLE', 90));
      t.onStateUpdate('S', state('RUNNING', 90));
      t.onStateUpdate('S', state('RUNNING', 85));
      expect(got, isNull);
      t.onStateUpdate('S', state('FINISH', 82));
      expect(got, {(0, 1): 8});
      expect(estimateWeightFromPercent(8, 1000), 80);
    });
  });

  group('filament setting', () {
    test('Bambu setting id maps to tray_info_idx', () {
      const s = Spool(id: '1', material: 'PLA', rgba: 'FF0000', slicerFilament: 'GFSA00_07');
      final f = PrinterManager.filamentSettingFor(s);
      expect(f.trayInfoIdx, 'GFA00');
      expect(f.settingId, 'GFSA00');
      expect(f.trayColor, 'FF0000FF');
      expect((f.nozzleTempMin, f.nozzleTempMax), (190, 230));
    });

    test('filament id used directly; empty falls back to generic', () {
      expect(
          PrinterManager.filamentSettingFor(const Spool(id: '1', material: 'PETG', slicerFilament: 'GFG00')).trayInfoIdx,
          'GFG00');
      expect(PrinterManager.filamentSettingFor(const Spool(id: '1', material: 'PETG')).trayInfoIdx, 'GFG99');
    });
  });
}
