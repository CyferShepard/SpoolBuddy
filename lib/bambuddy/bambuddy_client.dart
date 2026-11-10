import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_models.dart';

/// Error talking to Bambuddy. [status] is the HTTP status, or null for network errors.
class BambuddyException implements Exception {
  final int? status;
  final String message;
  BambuddyException(this.status, this.message);

  /// Bambuddy's own answer for a device it doesn't know (an admin unregistered it).
  bool get unregistered => status == 404 && message == 'Device not registered';

  @override
  String toString() => status == null ? message : 'HTTP $status: $message';
}

/// Talks to Bambuddy's SpoolBuddy device API (`/api/v1/spoolbuddy`), the same
/// calls the Raspberry Pi daemon (`spoolbuddy/daemon/api_client.py`) makes.
class BambuddyClient {
  BambuddyClient(String baseUrl, this.apiKey, {http.Client? httpClient})
      : baseUrl = normalizeUrl(baseUrl),
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final http.Client _http;

  static String normalizeUrl(String url) {
    var u = url.trim();
    if (u.isNotEmpty && !u.contains('://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Uri _uri(String path) => Uri.parse('$baseUrl/api/v1/spoolbuddy$path');

  /// Send a request to `/api/v1[path]` and return the decoded JSON body.
  Future<Object?> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$baseUrl/api/v1$path'))..headers['X-API-Key'] = apiKey;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response resp;
    try {
      resp = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 15)));
    } on TimeoutException {
      throw BambuddyException(null, 'Bambuddy did not respond');
    } catch (e) {
      throw BambuddyException(null, 'Cannot reach Bambuddy: $e');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {}
    if (resp.statusCode >= 200 && resp.statusCode < 300) return decoded;

    var detail = decoded is Map ? decoded['detail'] : null;
    if (detail is Map) detail = detail['message'] ?? detail['code']; // e.g. {code: tag_already_linked, message: ...}
    if (detail is List) detail = detail.map((e) => e is Map ? e['msg'] : e).join('; '); // FastAPI validation errors
    final msg = switch (resp.statusCode) {
      401 => 'API key rejected',
      403 => 'API key lacks permission for this action',
      _ => detail is String ? detail : (resp.reasonPhrase ?? 'Request failed'),
    };
    throw BambuddyException(resp.statusCode, detail is String && resp.statusCode == 404 ? detail : msg);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    final r = await _send('POST', '/spoolbuddy$path', body);
    return r is Map<String, dynamic> ? r : const {};
  }

  // ---------------------------------------------------------------------------
  // Inventory, printers and AMS (the calls Bambuddy's kiosk pages make).
  // [spoolman] selects the Spoolman-backed endpoints.

  /// Whether Bambuddy tracks filament in Spoolman (`/settings/spoolman`, as the kiosk checks).
  Future<bool> spoolmanMode() async {
    final r = await _send('GET', '/settings/spoolman');
    return r is Map && r['spoolman_enabled'] == 'true' && (r['spoolman_url'] ?? '').toString().isNotEmpty;
  }

  /// Spoolman's address as Bambuddy has it, or null when Spoolman mode is off.
  Future<String?> spoolmanUrl() async {
    final r = await _send('GET', '/settings/spoolman');
    if (r is! Map || r['spoolman_enabled'] != 'true') return null;
    final url = (r['spoolman_url'] ?? '').toString().trim().replaceFirst(RegExp(r'/+$'), '');
    return url.isEmpty ? null : url;
  }

  /// Set the extruder and bed temperatures on the filament of Spoolman spool
  /// [spoolId]. Bambuddy has no temperature fields in Spoolman mode, so this
  /// goes to Spoolman directly, at the address Bambuddy uses for it.
  Future<void> setSpoolmanFilamentTemps(int spoolId, {int? extruder, int? bed}) async {
    if (extruder == null && bed == null) return;
    final base = await spoolmanUrl();
    if (base == null) throw BambuddyException(null, 'Spoolman is not enabled in Bambuddy');
    Future<Object?> call(String method, String path, [Object? body]) async {
      final req = http.Request(method, Uri.parse('$base/api/v1$path'));
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final http.Response resp;
      try {
        resp = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 10)));
      } catch (e) {
        throw BambuddyException(null, 'Cannot reach Spoolman at $base');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw BambuddyException(resp.statusCode, 'Spoolman refused the temperatures (${resp.statusCode})');
      }
      return jsonDecode(utf8.decode(resp.bodyBytes));
    }

    final spool = await call('GET', '/spool/$spoolId');
    final filamentId = spool is Map && spool['filament'] is Map ? spool['filament']['id'] : null;
    if (filamentId == null) throw BambuddyException(null, 'Spoolman spool $spoolId has no filament');
    await call('PATCH', '/filament/$filamentId', {
      'settings_extruder_temp': ?extruder,
      'settings_bed_temp': ?bed,
    });
  }

  Future<List<BSpool>> spools({required bool spoolman}) async {
    final r = await _send('GET', '${spoolman ? '/spoolman' : ''}/inventory/spools?include_archived=false');
    return [for (final s in (r as List? ?? const [])) if (s is Map<String, dynamic>) BSpool.fromJson(s)];
  }

  Future<BSpool> spool(int id, {required bool spoolman}) async =>
      BSpool.fromJson(await _send('GET', '${spoolman ? '/spoolman' : ''}/inventory/spools/$id') as Map<String, dynamic>);

  /// Create a spool; [fields] uses Bambuddy's spool field names.
  Future<BSpool> createSpool(Map<String, Object?> fields, {required bool spoolman}) async => BSpool.fromJson(
      await _send('POST', '${spoolman ? '/spoolman' : ''}/inventory/spools', fields) as Map<String, dynamic>);

  /// Link a tag to a spool. With Spoolman 0.27+ this adds to the spool's tags rather than replacing them.
  Future<void> linkTag(int spoolId, {String? tagUid, String? trayUuid, required bool spoolman}) => _send(
        'PATCH',
        spoolman ? '/spoolman/inventory/spools/$spoolId/tag' : '/inventory/spools/$spoolId/link-tag',
        {'tag_uid': ?tagUid, 'tray_uuid': ?trayUuid},
      );

  Future<List<BPrinter>> printers() async {
    final r = await _send('GET', '/printers/');
    return [for (final p in (r as List? ?? const [])) if (p is Map<String, dynamic>) BPrinter.fromJson(p)];
  }

  Future<BPrinterStatus> printerStatus(int id) async =>
      BPrinterStatus.fromJson(await _send('GET', '/printers/$id/status') as Map<String, dynamic>);

  Future<List<BSlotAssignment>> slotAssignments(int printerId, {required bool spoolman}) async {
    final r = await _send('GET',
        spoolman ? '/spoolman/inventory/slot-assignments/all?printer_id=$printerId' : '/inventory/assignments?printer_id=$printerId');
    return [
      for (final a in (r as List? ?? const []))
        if (a is Map)
          BSlotAssignment(
            (a['printer_id'] as num).toInt(),
            (a['ams_id'] as num).toInt(),
            (a['tray_id'] as num).toInt(),
            ((spoolman ? a['spoolman_spool_id'] : a['spool_id']) as num).toInt(),
          ),
    ];
  }

  /// Assign a spool to a slot; Bambuddy also configures the slot over MQTT.
  /// Returns true when the slot will configure once a spool is inserted.
  Future<bool> assignSlot(int spoolId, int printerId, int amsId, int trayId, {required bool spoolman}) async {
    final r = await _send(
      'POST',
      spoolman ? '/spoolman/inventory/slot-assignments' : '/inventory/assignments',
      {
        spoolman ? 'spoolman_spool_id' : 'spool_id': spoolId,
        'printer_id': printerId,
        'ams_id': amsId,
        'tray_id': trayId,
      },
    );
    return r is Map && r['pending_config'] == true;
  }

  Future<void> unassignSlot({required int spoolId, required int printerId, required int amsId, required int trayId, required bool spoolman}) =>
      _send('DELETE',
          spoolman ? '/spoolman/inventory/slot-assignments/$spoolId' : '/inventory/assignments/$printerId/$amsId/$trayId');

  /// Record a weighed gross weight (spool + filament); Bambuddy recalculates usage.
  Future<void> updateSpoolWeight(int spoolId, double grams) =>
      _post('/scale/update-spool-weight', {'spool_id': spoolId, 'weight_grams': grams});

  /// Queue a tag write for [deviceId]; the next heartbeat delivers it.
  Future<void> queueWriteTag(String deviceId, int spoolId) =>
      _post('/nfc/write-tag', {'device_id': deviceId, 'spool_id': spoolId});

  Future<Map<String, dynamic>> register({
    required String deviceId,
    required String hostname,
    required String ipAddress,
    required String firmwareVersion,
  }) =>
      _post('/devices/register', {
        'device_id': deviceId,
        'hostname': hostname,
        'ip_address': ipAddress,
        'firmware_version': firmwareVersion,
        'has_nfc': true,
        'has_scale': false,
        'nfc_reader_type': 'phone',
        'nfc_connection': 'android',
        'backend_url': baseUrl,
        'has_backlight': false,
      });

  Future<Map<String, dynamic>> heartbeat({
    required String deviceId,
    required int uptimeS,
    required bool nfcOk,
    String? ipAddress,
    required String firmwareVersion,
  }) =>
      _post('/devices/$deviceId/heartbeat', {
        'nfc_ok': nfcOk,
        'scale_ok': false,
        'uptime_s': uptimeS,
        'ip_address': ipAddress,
        'firmware_version': firmwareVersion,
        'nfc_reader_type': 'phone',
        'nfc_connection': 'android',
        'backend_url': baseUrl,
      });

  /// Bambuddy's own version, from the daemon update check. The Pi daemon ships
  /// with Bambuddy and reports the same version; anything else makes the kiosk
  /// offer an (SSH-based) daemon update that cannot apply to a phone.
  Future<String?> bambuddyVersion(String deviceId) async {
    try {
      final resp = await _http
          .get(_uri('/devices/$deviceId/update-check'), headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final v = (jsonDecode(utf8.decode(resp.bodyBytes)) as Map)['latest_version'];
      return v is String && v.isNotEmpty && v.length <= 20 ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> unregister(String deviceId) async {
    try {
      await _http
          .delete(_uri('/devices/$deviceId'), headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best effort: Bambuddy lists the device as offline and it can be removed there.
    }
  }

  Future<Map<String, dynamic>> tagScanned({
    required String deviceId,
    required String tagUid,
    int? sak,
    String? tagType,
    String? trayUuid,
    Map<String, String>? rawBlocks,
  }) =>
      _post('/nfc/tag-scanned', {
        'device_id': deviceId,
        'tag_uid': tagUid,
        'sak': sak,
        'tag_type': tagType,
        'tray_uuid': trayUuid,
        'raw_blocks': rawBlocks,
      });

  Future<void> tagRemoved(String deviceId, String tagUid) =>
      _post('/nfc/tag-removed', {'device_id': deviceId, 'tag_uid': tagUid});

  Future<void> writeResult({
    required String deviceId,
    required int spoolId,
    required String tagUid,
    required bool success,
    String? message,
  }) =>
      _post('/nfc/write-result', {
        'device_id': deviceId,
        'spool_id': spoolId,
        'tag_uid': tagUid,
        'success': success,
        'message': message,
      });

  Future<void> cancelWrite(String deviceId) => _post('/devices/$deviceId/cancel-write', const {});

  Future<void> systemCommandResult(String deviceId, String command, bool success, String message) =>
      _post('/devices/$deviceId/system/command-result',
          {'command': command, 'success': success, 'message': message});

  Future<void> diagnosticResult(String deviceId, String diagnostic, bool success, String output, int exitCode) =>
      _post('/diagnostics/$deviceId/result',
          {'diagnostic': diagnostic, 'success': success, 'output': output, 'exit_code': exitCode});

  void close() => _http.close();
}
