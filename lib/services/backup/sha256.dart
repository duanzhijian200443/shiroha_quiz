import 'dart:typed_data';

/// Minimal pure-Dart SHA-256 used by the B0 package boundary. B0 must not add
/// a new dependency; this implementation only hashes package entries, which
/// are bounded by the frozen resource ceilings.
final class StreamingSha256 {
  StreamingSha256() {
    _h = List<int>.of(_initialHash);
  }

  static final List<int> _initialHash = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  static final List<int> _k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  late List<int> _h;
  final ByteData _block = ByteData(64);
  int _blockLength = 0;
  int _totalLength = 0;

  void update(List<int> data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    var index = start;
    while (index < stop) {
      final available = 64 - _blockLength;
      final count = stop - index < available ? stop - index : available;
      for (var offset = 0; offset < count; offset++) {
        _block.setUint8(_blockLength + offset, data[index + offset]);
      }
      _blockLength += count;
      index += count;
      _totalLength += count;
      if (_blockLength == 64) {
        _processBlock();
        _blockLength = 0;
      }
    }
  }

  void _processBlock() {
    final w = Uint32List(64);
    for (var index = 0; index < 16; index++) {
      w[index] = _block.getUint32(index * 4);
    }
    for (var index = 16; index < 64; index++) {
      final s0 = _rotr(w[index - 15], 7) ^
          _rotr(w[index - 15], 18) ^
          (w[index - 15] >> 3);
      final s1 = _rotr(w[index - 2], 17) ^
          _rotr(w[index - 2], 19) ^
          (w[index - 2] >> 10);
      w[index] = (w[index - 16] + s0 + w[index - 7] + s1) & 0xffffffff;
    }

    var a = _h[0];
    var b = _h[1];
    var c = _h[2];
    var d = _h[3];
    var e = _h[4];
    var f = _h[5];
    var g = _h[6];
    var h = _h[7];

    for (var index = 0; index < 64; index++) {
      final sum1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temp1 = (h + sum1 + choose + _k[index] + w[index]) & 0xffffffff;
      final sum0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + majority) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }

  static int _rotr(int value, int bits) =>
      ((value >> bits) | (value << (32 - bits))) & 0xffffffff;

  String digestHex() {
    final totalBits = _totalLength * 8;
    final padLength =
        _blockLength < 56 ? 56 - _blockLength : 120 - _blockLength;
    final padding = Uint8List(padLength);
    padding[0] = 0x80;
    update(padding);
    final lengthBytes = ByteData(8)..setUint64(0, totalBits, Endian.big);
    update(lengthBytes.buffer.asUint8List());
    final result = StringBuffer();
    for (final value in _h) {
      result.write(value.toRadixString(16).padLeft(8, '0'));
    }
    return result.toString();
  }
}

String sha256Hex(List<int> bytes) {
  final hasher = StreamingSha256();
  hasher.update(bytes);
  return hasher.digestHex();
}
