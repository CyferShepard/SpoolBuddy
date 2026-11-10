import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:provider/provider.dart';

import '../nfc/nfc_service.dart';

/// Runs [action] (which polls for a tag) behind a "hold tag to phone" dialog.
/// Returns null if cancelled or failed (an error message is shown).
Future<T?> runNfcAction<T>(BuildContext context, String prompt, Future<T> Function(NfcService) action) async {
  final nfc = context.read<NfcService>();
  final avail = await nfc.availability();
  if (!context.mounted) return null;
  if (avail != NFCAvailability.available) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('NFC unavailable'),
        content: Text(avail == NFCAvailability.disabled
            ? 'Turn on NFC in your phone settings and try again.'
            : 'This device has no NFC reader.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
    return null;
  }

  var cancelled = false;
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.nfc, size: 64),
        const SizedBox(height: 16),
        Text(prompt, textAlign: TextAlign.center),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            nfc.cancel();
          },
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  String? error;
  T? result;
  try {
    result = await action(nfc);
  } on NfcException catch (e) {
    error = e.message;
  } on PlatformException catch (e) {
    if (e.code == '408') {
      error = 'No tag detected.';
    } else {
      error = e.message ?? e.code;
    }
  } catch (e) {
    error = '$e';
  }
  nav.pop();
  if (cancelled) return null;
  if (error != null && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('NFC error'),
        content: Text(error!),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
    return null;
  }
  return result;
}
