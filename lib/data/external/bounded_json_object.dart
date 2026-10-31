import 'dart:convert';
import 'dart:typed_data';

/// Rejects duplicate (including escaped) keys before the SDK folds them.
/// Size is checked before decoding; callers must also bound their input reads.
Map<String, dynamic> boundedJsonObject(Uint8List bytes,
    {required int maxBytes, int maxDepth = 32}) {
  if (bytes.isEmpty || bytes.length > maxBytes) {
    throw const FormatException('invalid_object');
  }
  final source = utf8.decode(bytes, allowMalformed: false);
  final stack = <Set<String>?>[];
  for (var i = 0; i < source.length; i++) {
    final unit = source.codeUnitAt(i);
    if (unit == 34) {
      final start = i++;
      while (i < source.length && source.codeUnitAt(i) != 34) {
        if (source.codeUnitAt(i) == 92) i++;
        i++;
      }
      if (i >= source.length) throw const FormatException('invalid_object');
      var next = i + 1;
      while (next < source.length && ' \r\n\t'.contains(source[next])) {
        next++;
      }
      if (next < source.length && source.codeUnitAt(next) == 58) {
        if (stack.isEmpty ||
            stack.last == null ||
            !stack.last!
                .add(jsonDecode(source.substring(start, i + 1)) as String)) {
          throw const FormatException('invalid_object');
        }
      }
    } else if (unit == 123 || unit == 91) {
      stack.add(unit == 123 ? <String>{} : null);
      if (stack.length > maxDepth) {
        throw const FormatException('invalid_object');
      }
    } else if (unit == 125 || unit == 93) {
      if (stack.isEmpty || (unit == 125) != (stack.last != null)) {
        throw const FormatException('invalid_object');
      }
      stack.removeLast();
    }
  }
  if (stack.isNotEmpty) throw const FormatException('invalid_object');
  final value = jsonDecode(source);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_object');
  }
  return value;
}
