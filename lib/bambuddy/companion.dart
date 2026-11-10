import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' show TypeNameFormat;

import '../data/database.dart';
import '../nfc/nfc_service.dart';
import '../tags/tag_models.dart';
import 'api_models.dart';
import 'bambuddy_client.dart';
import 'ndef_tlv.dart';

/// A scan and Bambuddy's answer: the matched spool, or null for an unknown tag.
class ScanResult {
  final RawTagScan scan;
  final int? spoolId;
  final DateTime at;
  const ScanResult(this.scan, this.spoolId, this.at);
  bool get matched => spoolId != null;
}

/// A tag write Bambuddy queued for this device.
class PendingWrite {
  final int spoolId;
  final Uint8List ndefData;
  const PendingWrite(this.spoolId, this.ndefData);
}

enum CompanionStatus { unpaired, offline, connecting, online }

/// Makes the phone a SpoolBuddy device for Bambuddy: registers, sends
/// heartbeats, reports every tag it reads and performs tag writes Bambuddy asks
/// for. Mirrors the Raspberry Pi daemon in bambuddy/spoolbuddy/daemon/.
class BambuddyCompanion extends ChangeNotifier {
  BambuddyCompanion(this.db, this.nfc, {BambuddyClient Function(String url, String apiKey)? clientFactory})
      : _newClient = clientFactory ?? BambuddyClient.new;

  final BambuddyClient Function(String url, String apiKey) _newClient;

  /// Version reported to Bambuddy. Replaced by Bambuddy's own version after
  /// registering (see [BambuddyClient.bambuddyVersion]).
  String firmwareVersion = '0.0.0';
  static const _kUrl = 'bambuddy_url';
  static const _kKey = 'bambuddy_api_key';
  static const _kDeviceId = 'bambuddy_device_id';
  static const _kName = 'bambuddy_device_name';
  static const _heartbeatInterval = Duration(seconds: 10);

  /// A tag still on the phone is re-detected on every poll; within this window
  /// it counts as the same placement and is not reported again.
  static const _samePlacementWindow = Duration(seconds: 4);

  final AppDatabase db;
  final NfcService nfc;

  BambuddyClient? _client;
  String? deviceId;
  String deviceName = 'SpoolBuddy Android';
  CompanionStatus status = CompanionStatus.unpaired;
  String? lastError;
  bool nfcAvailable = false;
  bool scanning = false;

  /// Last tag reported to Bambuddy, for the status bar.
  RawTagScan? lastScan;
  DateTime? _lastSeen;

  PendingWrite? pendingWrite;
  bool writing = false;

  /// Result of the last scan Bambuddy answered.
  ScanResult? lastResult;

  /// Whether Bambuddy tracks filament in Spoolman; picks the inventory endpoints.
  bool spoolman = false;

  /// Spool the next scanned tag gets linked to, if armed.
  BSpool? linkTarget;

  /// One-off messages for the UI (snackbars).
  final ValueNotifier<String?> messages = ValueNotifier(null);

  BambuddyClient? get api => _client;

  bool _active = false;
  Timer? _heartbeat;
  final _started = DateTime.now();

  bool get paired => _client != null;
  String? get url => _client?.baseUrl;

  Future<void> load() async {
    final url = await db.getSetting(_kUrl);
    final key = await db.getSetting(_kKey);
    deviceId = await db.getSetting(_kDeviceId);
    deviceName = await db.getSetting(_kName) ?? deviceName;
    if (url != null && url.isNotEmpty && key != null && key.isNotEmpty && deviceId != null) {
      _client = _newClient(url, key);
      status = CompanionStatus.offline;
    }
    notifyListeners();
  }

  static String _newDeviceId() {
    final r = Random.secure();
    return 'sb-android-${List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  static Future<String> _localIp() async {
    try {
      for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in iface.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return '0.0.0.0';
  }

  /// Register with Bambuddy. Settings are saved only if registration succeeds.
  Future<void> pair(String url, String apiKey, String name) async {
    final id = deviceId ?? await db.getSetting(_kDeviceId) ?? _newDeviceId();
    final client = _newClient(url, apiKey.trim());
    final hostname = name.trim().isEmpty ? 'SpoolBuddy Android' : name.trim();
    await _registerWith(client, id, hostname);
    await db.setSetting(_kUrl, client.baseUrl);
    await db.setSetting(_kKey, client.apiKey);
    await db.setSetting(_kDeviceId, id);
    await db.setSetting(_kName, hostname);
    _client?.close();
    _client = client;
    deviceId = id;
    deviceName = hostname;
    status = CompanionStatus.online;
    lastError = null;
    notifyListeners();
  }

  /// Stop, tell Bambuddy to forget this device, and clear the settings.
  Future<void> unpair() async {
    await stop();
    final c = _client;
    if (c != null && deviceId != null) await c.unregister(deviceId!);
    c?.close();
    _client = null;
    for (final k in [_kUrl, _kKey]) {
      await db.setSetting(k, '');
    }
    status = CompanionStatus.unpaired;
    lastScan = null;
    pendingWrite = null;
    notifyListeners();
  }

  /// Start heartbeats and tag listening (app in the foreground).
  Future<void> start() async {
    if (!paired || _active) return;
    _active = true;
    nfcAvailable = await nfc.availability() == NFCAvailability.available;
    status = CompanionStatus.connecting;
    notifyListeners();
    await _register();
    await refreshMode();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
    unawaited(_listenLoop());
  }

  /// Stop heartbeats and tag listening (app in the background).
  Future<void> stop() async {
    _active = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    await nfc.cancel();
    if (paired) status = CompanionStatus.offline;
    scanning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _active = false;
    _heartbeat?.cancel();
    _client?.close();
    super.dispose();
  }

  void _setError(Object e) {
    lastError = '$e';
    if (e is BambuddyException && e.status == null) status = CompanionStatus.offline;
    notifyListeners();
  }

  /// Register, then match Bambuddy's version so the kiosk doesn't offer a
  /// daemon update (re-registering once if the version changed).
  Future<void> _registerWith(BambuddyClient c, String id, String hostname) async {
    final ip = await _localIp();
    await c.register(deviceId: id, hostname: hostname, ipAddress: ip, firmwareVersion: firmwareVersion);
    final v = await c.bambuddyVersion(id);
    if (v != null && v != firmwareVersion) {
      firmwareVersion = v;
      await c.register(deviceId: id, hostname: hostname, ipAddress: ip, firmwareVersion: firmwareVersion);
    }
  }

  Future<void> _register() async {
    final c = _client;
    if (c == null || deviceId == null) return;
    try {
      await _registerWith(c, deviceId!, deviceName);
      status = CompanionStatus.online;
      lastError = null;
      notifyListeners();
    } catch (e) {
      _setError(e);
    }
  }

  /// Re-read whether Bambuddy uses Spoolman. Keeps the last known value on failure.
  Future<void> refreshMode() async {
    final c = _client;
    if (c == null) return;
    try {
      final m = await c.spoolmanMode();
      _modeKnown = true;
      if (m != spoolman) {
        spoolman = m;
        notifyListeners();
      }
    } catch (_) {}
  }

  bool _modeKnown = false;

  /// Make sure [spoolman] reflects Bambuddy before choosing inventory endpoints.
  Future<void> ensureMode() async {
    if (!_modeKnown) await refreshMode();
  }

  Future<void> _sendHeartbeat() async {
    final c = _client;
    if (c == null || deviceId == null || !_active) return;
    try {
      final r = await c.heartbeat(
        deviceId: deviceId!,
        uptimeS: DateTime.now().difference(_started).inSeconds,
        nfcOk: nfcAvailable,
        ipAddress: await _localIp(),
        firmwareVersion: firmwareVersion,
      );
      if (status != CompanionStatus.online || lastError != null) {
        status = CompanionStatus.online;
        lastError = null;
        notifyListeners();
      }
      await _handleCommand(r);
    } on BambuddyException catch (e) {
      if (e.unregistered) {
        await _register(); // an admin removed this device in Bambuddy; come back, like the daemon
      } else {
        _setError(e);
      }
    } catch (e) {
      _setError(e);
    }
  }

  @visibleForTesting
  Future<void> handleCommandForTest(Map<String, dynamic> r) => _handleCommand(r);

  Future<void> _handleCommand(Map<String, dynamic> r) async {
    final cmd = r['pending_command'];
    if (cmd is! String) return;
    final c = _client!;
    if (cmd == 'write_tag') {
      final p = r['pending_write_payload'];
      if (p is! Map) return;
      final spoolId = p['spool_id'];
      final hex = p['ndef_data_hex'];
      if (spoolId is! int || hex is! String) return;
      if (pendingWrite?.spoolId == spoolId) return; // still pending from an earlier heartbeat
      pendingWrite = PendingWrite(spoolId, hexToBytes(hex));
      notifyListeners();
      await nfc.cancel(); // interrupt the listening poll so the write can start
    } else if (cmd == 'apply_system_config') {
      await c.systemCommandResult(deviceId!, cmd, false, 'Not supported by the Android companion app');
    } else if (cmd.startsWith('run_') && cmd.endsWith('_diag')) {
      final diag = cmd.substring(4, cmd.length - 5);
      if (const {'nfc', 'scale', 'read_tag'}.contains(diag)) {
        await c.diagnosticResult(deviceId!, diag, false, 'Not supported by the Android companion app', 1);
      }
    }
    // Other commands (reboot, shutdown, restart_*) are cleared by Bambuddy on delivery
    // and do not apply to a phone.
  }

  Future<void> _listenLoop() async {
    while (_active) {
      if (pendingWrite != null) {
        // The UI drives writes (it shows the prompt); wait until it is done.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      if (!nfcAvailable) {
        await Future<void>.delayed(const Duration(seconds: 3));
        nfcAvailable = await nfc.availability() == NFCAvailability.available;
        continue;
      }
      scanning = true;
      try {
        final scan = await nfc.scanRaw();
        if (_active && pendingWrite == null) await _report(scan);
      } on PlatformException catch (e) {
        if (e.code != '408') {
          // 408 = poll timeout, the normal idle case. Anything else: back off briefly.
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    scanning = false;
  }

  Future<void> _report(RawTagScan scan) async {
    final now = DateTime.now();
    final prev = lastScan;
    final samePlacement = prev != null &&
        prev.uidHex == scan.uidHex &&
        _lastSeen != null &&
        now.difference(_lastSeen!) < _samePlacementWindow;
    _lastSeen = now;
    if (samePlacement) return;

    final c = _client;
    if (c == null || deviceId == null) return;
    try {
      // A phone cannot see a tag leave; a different tag means the previous one is gone.
      if (prev != null && prev.uidHex != scan.uidHex) await c.tagRemoved(deviceId!, prev.uidHex);
      lastScan = scan;
      notifyListeners();

      final target = linkTarget;
      if (target != null) {
        try {
          await c.linkTag(target.id,
              tagUid: scan.uidHex, trayUuid: scan.trayUuid, spoolman: spoolman);
          messages.value = 'Tag ${scan.uidHex} linked to ${target.title}';
          linkTarget = null;
        } on BambuddyException catch (e) {
          messages.value = 'Could not link tag: ${e.message}';
        }
      }
      await _sendScan(scan);
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _sendScan(RawTagScan scan) async {
    final r = await _client!.tagScanned(
      deviceId: deviceId!,
      tagUid: scan.uidHex,
      sak: scan.sak,
      tagType: scan.tagType,
      trayUuid: scan.trayUuid,
      rawBlocks: scan.rawBlocks,
    );
    final id = r['spool_id'];
    lastResult = ScanResult(scan, r['matched'] == true && id is int ? id : null, DateTime.now());
    notifyListeners();
  }

  /// Send the last scan again, e.g. after linking it or creating its spool,
  /// so Bambuddy (and the kiosk) shows the match.
  Future<void> resendLastScan() async {
    final scan = lastScan;
    if (scan == null || _client == null || deviceId == null) return;
    try {
      await _sendScan(scan);
    } catch (e) {
      _setError(e);
    }
  }

  /// Link the next tag scanned to [spool] (e.g. the second tag of a spool).
  void armLink(BSpool? spool) {
    linkTarget = spool;
    notifyListeners();
  }

  /// Ask Bambuddy to write [spoolId] to a tag and fetch the write right away
  /// instead of waiting for the next heartbeat.
  Future<void> requestTagWrite(int spoolId) async {
    final c = _client;
    if (c == null || deviceId == null) return;
    await c.queueWriteTag(deviceId!, spoolId);
    await _sendHeartbeat();
  }

  /// Perform the pending write: wait for a tag, write, report the result.
  /// Returns a message for the user.
  Future<String> performWrite() async {
    final w = pendingWrite;
    final c = _client;
    if (w == null || c == null || deviceId == null) return 'Nothing to write';
    writing = true;
    notifyListeners();
    try {
      final records = parseNdefTlv(w.ndefData)
          .map((r) => NDEFRawRecord(
                bytesToHex(r.id),
                bytesToHex(r.payload),
                bytesToHex(r.type),
                TypeNameFormat.values[r.tnf],
              ))
          .toList();
      final uid = await nfc.writeNdefRecords(records);
      await c.writeResult(deviceId: deviceId!, spoolId: w.spoolId, tagUid: uid, success: true, message: 'Write successful');
      // The tag is still on the phone: treat it as already reported so the loop doesn't re-send it.
      lastScan = RawTagScan(uid, null, 'ntag');
      _lastSeen = DateTime.now();
      return 'Tag written';
    } on NfcException catch (e) {
      if (e.uidHex != null && e.uidHex!.length >= 8) {
        await _safe(() =>
            c.writeResult(deviceId: deviceId!, spoolId: w.spoolId, tagUid: e.uidHex!, success: false, message: e.message));
      } else {
        await _safe(() => c.cancelWrite(deviceId!));
      }
      return e.message;
    } on PlatformException catch (e) {
      await _safe(() => c.cancelWrite(deviceId!));
      return e.code == '408' ? 'No tag detected. Write cancelled.' : (e.message ?? e.code);
    } on FormatException catch (e) {
      await _safe(() => c.cancelWrite(deviceId!));
      return 'Bambuddy sent tag data this app cannot write: ${e.message}';
    } catch (e) {
      await _safe(() => c.cancelWrite(deviceId!));
      return 'Write failed: $e';
    } finally {
      pendingWrite = null;
      writing = false;
      notifyListeners();
    }
  }

  /// User dismissed the write prompt.
  Future<void> cancelWrite() async {
    final c = _client;
    pendingWrite = null;
    await nfc.cancel();
    notifyListeners();
    if (c != null && deviceId != null) await _safe(() => c.cancelWrite(deviceId!));
  }

  Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      lastError = '$e';
    }
  }
}
