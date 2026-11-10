import 'dart:convert';
import 'dart:typed_data';

/// Minimal CBOR (RFC 8949) decoder. Decodes one item starting at [offset] and
/// ignores any trailing bytes, which OpenPrintTag needs because its regions
/// are concatenated CBOR items.
class CborLite {
  CborLite(this._d, [this._pos = 0]);

  final Uint8List _d;
  int _pos;

  static Object? decode(Uint8List data, [int offset = 0]) => CborLite(data, offset)._item();

  int _byte() {
    if (_pos >= _d.length) throw const FormatException('CBOR: unexpected end of data');
    return _d[_pos++];
  }

  int _uint(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | _byte();
    }
    return v;
  }

  /// Returns the argument value, or -1 for indefinite length.
  int _arg(int ai) {
    if (ai < 24) return ai;
    if (ai == 24) return _uint(1);
    if (ai == 25) return _uint(2);
    if (ai == 26) return _uint(4);
    if (ai == 27) return _uint(8);
    if (ai == 31) return -1;
    throw FormatException('CBOR: invalid additional info $ai');
  }

  Uint8List _take(int n) {
    if (_pos + n > _d.length) throw const FormatException('CBOR: unexpected end of data');
    final out = Uint8List.sublistView(_d, _pos, _pos + n);
    _pos += n;
    return out;
  }

  bool _atBreak() {
    if (_pos < _d.length && _d[_pos] == 0xFF) {
      _pos++;
      return true;
    }
    return false;
  }

  Uint8List _bytesOf(int major, int len) {
    if (len >= 0) return Uint8List.fromList(_take(len));
    final b = BytesBuilder();
    while (!_atBreak()) {
      final ib = _byte();
      if (ib >> 5 != major) throw const FormatException('CBOR: bad chunk');
      b.add(_take(_arg(ib & 0x1F)));
    }
    return b.toBytes();
  }

  Object? _item() {
    final ib = _byte();
    final major = ib >> 5;
    final ai = ib & 0x1F;
    switch (major) {
      case 0:
        return _arg(ai);
      case 1:
        return -1 - _arg(ai);
      case 2:
        return _bytesOf(2, _arg(ai));
      case 3:
        return utf8.decode(_bytesOf(3, _arg(ai)), allowMalformed: true);
      case 4:
        final len = _arg(ai);
        final list = <Object?>[];
        if (len >= 0) {
          for (var i = 0; i < len; i++) {
            list.add(_item());
          }
        } else {
          while (!_atBreak()) {
            list.add(_item());
          }
        }
        return list;
      case 5:
        final len = _arg(ai);
        final map = <Object?, Object?>{};
        if (len >= 0) {
          for (var i = 0; i < len; i++) {
            final k = _item();
            map[k] = _item();
          }
        } else {
          while (!_atBreak()) {
            final k = _item();
            map[k] = _item();
          }
        }
        return map;
      case 6:
        _arg(ai); // semantic tag: ignore, return the tagged value
        return _item();
      default:
        if (ai == 20) return false;
        if (ai == 21) return true;
        if (ai == 22 || ai == 23) return null;
        if (ai == 25) return _half(_uint(2));
        if (ai == 26) return ByteData.sublistView(_take(4)).getFloat32(0);
        if (ai == 27) return ByteData.sublistView(_take(8)).getFloat64(0);
        if (ai < 24) return ai;
        if (ai == 24) return _byte();
        throw FormatException('CBOR: unsupported simple value $ai');
    }
  }

  static double _half(int h) {
    final exp = (h >> 10) & 0x1F;
    final mant = h & 0x3FF;
    double v;
    if (exp == 0) {
      v = mant / 1024 * 6.103515625e-05;
    } else if (exp == 31) {
      v = mant == 0 ? double.infinity : double.nan;
    } else {
      v = (1 + mant / 1024) * (1 << exp) / (1 << 15);
    }
    return (h & 0x8000) != 0 ? -v : v;
  }
}
