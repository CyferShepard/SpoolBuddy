import 'dart:typed_data';

/// One NDEF record parsed from raw tag memory.
class ParsedNdefRecord {
  final int tnf;
  final Uint8List type;
  final Uint8List id;
  final Uint8List payload;
  const ParsedNdefRecord(this.tnf, this.type, this.id, this.payload);
}

/// Parse the NTAG memory image Bambuddy sends for a tag write
/// (`ndef_data_hex`: optional capability container, then an NDEF TLV, then 0xFE)
/// into its NDEF records, so the phone can write them through Android's NDEF API.
List<ParsedNdefRecord> parseNdefTlv(Uint8List data) {
  var i = 0;
  // Bambuddy prefixes the 4-byte capability container (E1 ..), which Android writes itself.
  if (data.length >= 4 && data[0] == 0xE1) i = 4;

  while (i < data.length) {
    final t = data[i++];
    if (t == 0x00) continue; // NULL TLV
    if (t == 0xFE) break; // terminator
    if (i >= data.length) break;
    var len = data[i++];
    if (len == 0xFF) {
      if (i + 2 > data.length) throw const FormatException('Truncated TLV length');
      len = (data[i] << 8) | data[i + 1];
      i += 2;
    }
    if (i + len > data.length) throw const FormatException('Truncated TLV');
    if (t == 0x03) return _parseMessage(Uint8List.sublistView(data, i, i + len));
    i += len;
  }
  throw const FormatException('No NDEF message in tag data');
}

List<ParsedNdefRecord> _parseMessage(Uint8List m) {
  final records = <ParsedNdefRecord>[];
  var i = 0;
  while (i < m.length) {
    final header = m[i++];
    final mb = header & 0x80 != 0;
    final me = header & 0x40 != 0;
    final cf = header & 0x20 != 0;
    final sr = header & 0x10 != 0;
    final il = header & 0x08 != 0;
    final tnf = header & 0x07;
    if (cf) throw const FormatException('Chunked NDEF records are not supported');
    if (tnf == 7) throw const FormatException('Reserved NDEF type name format');
    if (records.isEmpty && !mb) throw const FormatException('First NDEF record lacks MB flag');
    int need(int n) {
      if (i + n > m.length) throw const FormatException('Truncated NDEF record');
      return n;
    }

    need(1);
    final typeLen = m[i++];
    int payloadLen;
    if (sr) {
      need(1);
      payloadLen = m[i++];
    } else {
      need(4);
      payloadLen = (m[i] << 24) | (m[i + 1] << 16) | (m[i + 2] << 8) | m[i + 3];
      i += 4;
    }
    var idLen = 0;
    if (il) {
      need(1);
      idLen = m[i++];
    }
    Uint8List take(int n) {
      need(n);
      final out = Uint8List.fromList(m.sublist(i, i + n));
      i += n;
      return out;
    }

    final type = take(typeLen);
    final id = take(idLen);
    final payload = take(payloadLen);
    records.add(ParsedNdefRecord(tnf, type, id, payload));
    if (me) break;
  }
  if (records.isEmpty) throw const FormatException('Empty NDEF message');
  return records;
}
