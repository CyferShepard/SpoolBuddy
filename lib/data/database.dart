import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/printer.dart';
import '../models/spool.dart';
import 'catalog_data.dart';

/// SQLite storage, ported from upstream `backend/db/database.py`.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _schema = [
    '''CREATE TABLE IF NOT EXISTS spools (
      id TEXT PRIMARY KEY,
      spool_number INTEGER UNIQUE,
      tag_id TEXT,
      material TEXT NOT NULL,
      subtype TEXT,
      color_name TEXT,
      rgba TEXT,
      brand TEXT,
      label_weight INTEGER DEFAULT 1000,
      core_weight INTEGER DEFAULT 250,
      weight_new INTEGER,
      weight_current INTEGER,
      weight_used REAL DEFAULT 0,
      slicer_filament TEXT,
      slicer_filament_name TEXT,
      location TEXT,
      note TEXT,
      added_time INTEGER,
      encode_time INTEGER,
      added_full INTEGER DEFAULT 0,
      consumed_since_add REAL DEFAULT 0,
      consumed_since_weight REAL DEFAULT 0,
      data_origin TEXT,
      tag_type TEXT,
      ext_has_k INTEGER DEFAULT 0,
      archived_at INTEGER,
      created_at INTEGER,
      updated_at INTEGER
    )''',
    '''CREATE TABLE IF NOT EXISTS printers (
      serial TEXT PRIMARY KEY,
      name TEXT,
      model TEXT,
      ip_address TEXT,
      access_code TEXT,
      last_seen INTEGER,
      config TEXT,
      auto_connect INTEGER DEFAULT 0,
      nozzle_count INTEGER DEFAULT 1
    )''',
    '''CREATE TABLE IF NOT EXISTS k_profiles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      spool_id TEXT REFERENCES spools(id) ON DELETE CASCADE,
      printer_serial TEXT REFERENCES printers(serial) ON DELETE CASCADE,
      extruder INTEGER,
      nozzle_diameter TEXT,
      nozzle_type TEXT,
      k_value TEXT,
      name TEXT,
      cali_idx INTEGER,
      setting_id TEXT,
      created_at INTEGER
    )''',
    '''CREATE TABLE IF NOT EXISTS usage_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      spool_id TEXT REFERENCES spools(id) ON DELETE CASCADE,
      printer_serial TEXT,
      print_name TEXT,
      weight_used REAL,
      timestamp INTEGER
    )''',
    '''CREATE TABLE IF NOT EXISTS spool_assignments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      spool_id TEXT REFERENCES spools(id) ON DELETE CASCADE,
      printer_serial TEXT NOT NULL,
      ams_id INTEGER NOT NULL,
      tray_id INTEGER NOT NULL,
      assigned_at INTEGER,
      UNIQUE(printer_serial, ams_id, tray_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT,
      updated_at INTEGER
    )''',
    '''CREATE TABLE IF NOT EXISTS spool_catalog (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      weight INTEGER NOT NULL,
      is_default INTEGER DEFAULT 1,
      created_at INTEGER
    )''',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_spool_catalog_name ON spool_catalog(name)',
    '''CREATE TABLE IF NOT EXISTS color_catalog (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      manufacturer TEXT NOT NULL,
      color_name TEXT NOT NULL,
      hex_color TEXT NOT NULL,
      material TEXT,
      is_default INTEGER DEFAULT 1,
      created_at INTEGER
    )''',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_color_catalog_unique ON color_catalog(manufacturer, color_name, material)',
    'CREATE INDEX IF NOT EXISTS idx_spools_tag_id ON spools(tag_id)',
    'CREATE INDEX IF NOT EXISTS idx_spools_material ON spools(material)',
    'CREATE INDEX IF NOT EXISTS idx_k_profiles_spool ON k_profiles(spool_id)',
    'CREATE INDEX IF NOT EXISTS idx_usage_history_spool ON usage_history(spool_id)',
  ];

  static Future<AppDatabase> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'spoolbuddy.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          for (final stmt in _schema) {
            await db.execute(stmt);
          }
        },
      ),
    );
    final instance = AppDatabase._(db);
    await instance._seedCatalogs();
    return instance;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> _seedCatalogs() async {
    if (Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM spool_catalog')) == 0) {
      await resetSpoolCatalog();
    }
    if (Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM color_catalog')) == 0) {
      await resetColorCatalog();
    }
  }

  // ============ Spools ============

  Future<List<Spool>> getSpools({bool includeArchived = true}) async {
    final rows = await db.query(
      'spools',
      where: includeArchived ? null : 'archived_at IS NULL',
      orderBy: 'created_at DESC',
    );
    return rows.map(Spool.fromMap).toList();
  }

  Future<Spool?> getSpool(String id) async {
    final rows = await db.query('spools', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Spool.fromMap(rows.first);
  }

  Future<Spool> createSpool(SpoolInput input) async {
    final id = const Uuid().v4();
    final now = _now();
    final next = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COALESCE(MAX(spool_number), 0) + 1 FROM spools')) ??
        1;
    await db.insert('spools', {
      ...input.toMap(),
      'id': id,
      'spool_number': next,
      'ext_has_k': 0,
      'created_at': now,
      'updated_at': now,
    });
    return (await getSpool(id))!;
  }

  Future<Spool?> updateSpool(String id, SpoolInput input) async {
    await db.update('spools', {...input.toMap(), 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);
    return getSpool(id);
  }

  Future<void> deleteSpool(String id) => db.delete('spools', where: 'id = ?', whereArgs: [id]);

  Future<void> archiveSpool(String id) =>
      db.update('spools', {'archived_at': _now(), 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  Future<void> restoreSpool(String id) =>
      db.update('spools', {'archived_at': null, 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  /// Look up a spool by tag id. Archived spools are skipped so recycled tags work.
  Future<Spool?> getSpoolByTag(String tagId, {bool includeArchived = false}) async {
    final rows = await db.query(
      'spools',
      where: includeArchived ? 'tag_id = ?' : 'tag_id = ? AND archived_at IS NULL',
      whereArgs: [tagId],
    );
    return rows.isEmpty ? null : Spool.fromMap(rows.first);
  }

  Future<List<Spool>> getUntaggedSpools() async {
    final rows = await db.query('spools',
        where: "(tag_id IS NULL OR tag_id = '') AND archived_at IS NULL", orderBy: 'created_at DESC');
    return rows.map(Spool.fromMap).toList();
  }

  /// Link a tag to a spool. Any other spool holding the same tag (e.g. an
  /// archived one whose tag is being recycled) has its tag cleared first.
  Future<Spool?> linkTagToSpool(String spoolId, String tagId, {String? tagType, String? dataOrigin}) async {
    await db.update('spools', {'tag_id': null, 'tag_type': null, 'updated_at': _now()},
        where: 'tag_id = ? AND id != ?', whereArgs: [tagId, spoolId]);
    await db.update(
      'spools',
      {
        'tag_id': tagId,
        'updated_at': _now(),
        'tag_type': ?tagType,
        'data_origin': ?dataOrigin,
      },
      where: 'id = ?',
      whereArgs: [spoolId],
    );
    return getSpool(spoolId);
  }

  Future<void> setEncodeTime(String spoolId) =>
      db.update('spools', {'encode_time': _now()}, where: 'id = ?', whereArgs: [spoolId]);

  /// Update consumption after a print (upstream `update_spool_consumption`).
  Future<Spool?> updateSpoolConsumption(String spoolId, double weightUsed) async {
    final spool = await getSpool(spoolId);
    if (spool == null) return null;
    final values = <String, Object?>{
      'updated_at': _now(),
      'consumed_since_add': spool.consumedSinceAdd + weightUsed,
      'consumed_since_weight': spool.consumedSinceWeight + weightUsed,
    };
    if (spool.weightCurrent != null) {
      final w = spool.weightCurrent! - weightUsed.toInt();
      values['weight_current'] = w < 0 ? 0 : w;
    }
    await db.update('spools', values, where: 'id = ?', whereArgs: [spoolId]);
    return getSpool(spoolId);
  }

  /// Set current gross weight (from a scale or manual entry) and recalculate
  /// weight_used to match (upstream `set_spool_weight`).
  Future<Spool?> setSpoolWeight(String spoolId, int weight) async {
    final spool = await getSpool(spoolId);
    if (spool == null) return null;
    int coreWeight;
    if (spool.coreWeight != null && spool.coreWeight! > 0) {
      coreWeight = spool.coreWeight!;
    } else {
      coreWeight = int.tryParse(await getSetting(defaultCoreWeightKey) ?? '') ?? 250;
    }
    final labelWeight = spool.labelWeight ?? 0;
    final num weightUsedNew;
    if (weight < coreWeight) {
      weightUsedNew = labelWeight;
    } else {
      final v = coreWeight + labelWeight - weight;
      weightUsedNew = v < 0 ? 0 : v;
    }
    await db.update(
      'spools',
      {
        'weight_current': weight,
        'weight_used': weightUsedNew,
        'consumed_since_weight': 0,
        'updated_at': _now(),
      },
      where: 'id = ?',
      whereArgs: [spoolId],
    );
    return getSpool(spoolId);
  }

  // ============ Printers ============

  Future<List<Printer>> getPrinters() async =>
      (await db.query('printers', orderBy: 'name')).map(Printer.fromMap).toList();

  Future<Printer?> getPrinter(String serial) async {
    final rows = await db.query('printers', where: 'serial = ?', whereArgs: [serial]);
    return rows.isEmpty ? null : Printer.fromMap(rows.first);
  }

  Future<void> upsertPrinter(Printer printer) async {
    final existing = await getPrinter(printer.serial);
    if (existing == null) {
      await db.insert('printers', printer.toMap());
    } else {
      await db.update('printers', printer.toMap(), where: 'serial = ?', whereArgs: [printer.serial]);
    }
  }

  Future<void> deletePrinter(String serial) => db.delete('printers', where: 'serial = ?', whereArgs: [serial]);

  Future<void> updateNozzleCount(String serial, int count) =>
      db.update('printers', {'nozzle_count': count}, where: 'serial = ?', whereArgs: [serial]);

  Future<void> touchPrinter(String serial) =>
      db.update('printers', {'last_seen': _now()}, where: 'serial = ?', whereArgs: [serial]);

  // ============ Slot assignments ============

  Future<void> assignSpoolToSlot(String spoolId, String serial, int amsId, int trayId) => db.insert(
        'spool_assignments',
        {
          'spool_id': spoolId,
          'printer_serial': serial,
          'ams_id': amsId,
          'tray_id': trayId,
          'assigned_at': _now(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> unassignSlot(String serial, int amsId, int trayId) => db.delete('spool_assignments',
      where: 'printer_serial = ? AND ams_id = ? AND tray_id = ?', whereArgs: [serial, amsId, trayId]);

  Future<String?> getSpoolForSlot(String serial, int amsId, int trayId) async {
    final rows = await db.query('spool_assignments',
        columns: ['spool_id'],
        where: 'printer_serial = ? AND ams_id = ? AND tray_id = ?',
        whereArgs: [serial, amsId, trayId]);
    return rows.isEmpty ? null : rows.first['spool_id'] as String?;
  }

  /// Map of (amsId, trayId) -> spoolId for a printer.
  Future<Map<(int, int), String>> getSlotAssignments(String serial) async {
    final rows = await db.query('spool_assignments', where: 'printer_serial = ?', whereArgs: [serial]);
    return {
      for (final r in rows) (r['ams_id'] as int, r['tray_id'] as int): r['spool_id'] as String,
    };
  }

  // ============ Usage history ============

  Future<void> logUsage(String spoolId, String serial, String printName, double weightUsed) =>
      db.insert('usage_history', {
        'spool_id': spoolId,
        'printer_serial': serial,
        'print_name': printName,
        'weight_used': weightUsed,
        'timestamp': _now(),
      });

  Future<List<Map<String, Object?>>> getUsageHistory(String spoolId, {int limit = 100}) => db.query(
        'usage_history',
        where: 'spool_id = ?',
        whereArgs: [spoolId],
        orderBy: 'timestamp DESC',
        limit: limit,
      );

  // ============ K-profiles ============

  Future<List<Map<String, Object?>>> getSpoolKProfiles(String spoolId) =>
      db.query('k_profiles', where: 'spool_id = ?', whereArgs: [spoolId]);

  /// Store the chosen K-profile for a spool on a printer/nozzle, replacing any previous one.
  Future<void> saveSpoolKProfile(String spoolId, String serial, String nozzleDiameter, Calibration cal) async {
    await db.transaction((txn) async {
      await txn.delete('k_profiles',
          where: 'spool_id = ? AND printer_serial = ? AND nozzle_diameter = ?',
          whereArgs: [spoolId, serial, nozzleDiameter]);
      await txn.insert('k_profiles', {
        'spool_id': spoolId,
        'printer_serial': serial,
        'extruder': cal.extruderId,
        'nozzle_diameter': nozzleDiameter,
        'k_value': cal.kValue.toString(),
        'name': cal.name,
        'cali_idx': cal.caliIdx,
        'setting_id': cal.settingId,
        'created_at': _now(),
      });
      await txn.update('spools', {'ext_has_k': 1}, where: 'id = ?', whereArgs: [spoolId]);
    });
  }

  // ============ Settings ============

  static const defaultCoreWeightKey = 'spoolbuddy-default-core-weight';

  Future<String?> getSetting(String key) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) => db.insert(
        'settings',
        {'key': key, 'value': value, 'updated_at': _now()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ============ Catalogs ============

  Future<List<Map<String, Object?>>> getSpoolCatalog() => db.query('spool_catalog', orderBy: 'name');

  Future<void> addSpoolCatalogEntry(String name, int weight) => db.insert(
      'spool_catalog', {'name': name, 'weight': weight, 'is_default': 0, 'created_at': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> updateSpoolCatalogEntry(int id, String name, int weight) =>
      db.update('spool_catalog', {'name': name, 'weight': weight}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteSpoolCatalogEntry(int id) => db.delete('spool_catalog', where: 'id = ?', whereArgs: [id]);

  Future<void> resetSpoolCatalog() async {
    final now = _now();
    await db.transaction((txn) async {
      await txn.delete('spool_catalog');
      final batch = txn.batch();
      for (final (name, weight) in defaultSpoolCatalog) {
        batch.insert('spool_catalog', {'name': name, 'weight': weight, 'is_default': 1, 'created_at': now});
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, Object?>>> getColorCatalog() =>
      db.query('color_catalog', orderBy: 'manufacturer, material, color_name');

  Future<void> addColorCatalogEntry(String manufacturer, String colorName, String hex, String? material) =>
      db.insert(
          'color_catalog',
          {
            'manufacturer': manufacturer,
            'color_name': colorName,
            'hex_color': hex,
            'material': material,
            'is_default': 0,
            'created_at': _now(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteColorCatalogEntry(int id) => db.delete('color_catalog', where: 'id = ?', whereArgs: [id]);

  Future<void> resetColorCatalog() async {
    final now = _now();
    await db.transaction((txn) async {
      await txn.delete('color_catalog');
      final batch = txn.batch();
      for (final (m, c, h, mat) in defaultColorCatalog) {
        batch.insert('color_catalog', {
          'manufacturer': m,
          'color_name': c,
          'hex_color': h,
          'material': mat,
          'is_default': 1,
          'created_at': now,
        });
      }
      await batch.commit(noResult: true, continueOnError: true);
    });
  }
}
