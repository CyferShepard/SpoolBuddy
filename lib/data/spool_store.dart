import 'package:flutter/foundation.dart';

import '../models/spool.dart';
import 'database.dart';

/// In-memory view of the spool inventory, refreshed from the database.
class SpoolStore extends ChangeNotifier {
  SpoolStore(this.db);

  final AppDatabase db;
  List<Spool> spools = [];

  Future<void> refresh() async {
    spools = await db.getSpools();
    notifyListeners();
  }

  Spool? byId(String id) => spools.where((s) => s.id == id).firstOrNull;

  Future<Spool> create(SpoolInput input) async {
    final s = await db.createSpool(input);
    await refresh();
    return s;
  }

  Future<void> update(String id, SpoolInput input) async {
    await db.updateSpool(id, input);
    await refresh();
  }

  Future<void> delete(String id) async {
    await db.deleteSpool(id);
    await refresh();
  }

  Future<void> setArchived(String id, bool archived) async {
    archived ? await db.archiveSpool(id) : await db.restoreSpool(id);
    await refresh();
  }

  Future<void> setWeight(String id, int grams) async {
    await db.setSpoolWeight(id, grams);
    await refresh();
  }

  Future<void> linkTag(String id, String tagId, {String? tagType, String? dataOrigin}) async {
    await db.linkTagToSpool(id, tagId, tagType: tagType, dataOrigin: dataOrigin);
    await refresh();
  }
}
