import 'dart:convert';
import 'dart:typed_data';

/// Decodes Apple binary plist format (`bplist00`) into Dart objects.
///
/// Supports the same types as [BinaryPlistEncoder]: [String], [int], [double],
/// [bool], `null`, [Uint8List] (data), [Map<String, dynamic>] (dict), and
/// [List] (array). Dates decode as their raw Core Foundation seconds
/// ([double]) and UIDs as [PlistUid].
///
/// The binary plist format consists of:
/// 1. Header: `bplist00` (8 bytes)
/// 2. Object table: serialized objects
/// 3. Offset table: byte offsets to each object
/// 4. Trailer: 32 bytes of metadata
class BinaryPlistDecoder {
  /// Decodes a binary plist [Uint8List] into a [Map<String, dynamic>].
  ///
  /// Throws [ArgumentError] if the data is not a valid `bplist00` binary.
  static Map<String, dynamic> decode(Uint8List data) {
    final decoder = BinaryPlistDecoder._(data);
    final result = decoder._decode();
    if (result is Map<String, dynamic>) {
      return result;
    }
    throw ArgumentError(
      'Binary plist root object is not a dict: ${result.runtimeType}',
    );
  }

  /// Decodes a binary plist [Uint8List] into any supported Dart object.
  ///
  /// Unlike [decode], this does not require the root to be a dict.
  static Object? decodeAny(Uint8List data) {
    final decoder = BinaryPlistDecoder._(data);
    return decoder._decode();
  }

  BinaryPlistDecoder._(this._data);

  final Uint8List _data;
  late final ByteData _byteData = ByteData.sublistView(_data);

  /// Cached decoded objects by index (to avoid re-decoding shared refs).
  final Map<int, Object?> _decodedObjects = {};

  late int _offsetSize;
  late int _objectRefSize;
  late int _numObjects;
  late int _topObjectIndex;
  late int _offsetTableOffset;

  Object? _decode() {
    // Validate header
    if (_data.length < 40) {
      // 8 header + 32 trailer minimum
      throw ArgumentError('Binary plist too short: ${_data.length} bytes');
    }

    final header = ascii.decode(_data.sublist(0, 8), allowInvalid: true);
    if (header != 'bplist00') {
      throw ArgumentError('Not a binary plist: invalid header "$header"');
    }

    // Parse trailer (last 32 bytes)
    final trailerOffset = _data.length - 32;
    _offsetSize = _data[trailerOffset + 6];
    _objectRefSize = _data[trailerOffset + 7];
    _numObjects = _readUint64BE(trailerOffset + 8);
    _topObjectIndex = _readUint64BE(trailerOffset + 16);
    _offsetTableOffset = _readUint64BE(trailerOffset + 24);

    if (_numObjects == 0) {
      throw ArgumentError('Binary plist has no objects');
    }

    return _readObject(_topObjectIndex);
  }

  /// Reads the object at the given index in the object table.
  Object? _readObject(int objectIndex) {
    if (_decodedObjects.containsKey(objectIndex)) {
      return _decodedObjects[objectIndex];
    }

    final offset = _readOffsetTableEntry(objectIndex);
    final result = _readObjectAtOffset(offset);
    _decodedObjects[objectIndex] = result;
    return result;
  }

  /// Reads the byte offset for the given object index from the offset table.
  int _readOffsetTableEntry(int objectIndex) {
    final entryOffset = _offsetTableOffset + objectIndex * _offsetSize;
    return _readUnsignedInt(entryOffset, _offsetSize);
  }

  /// Reads and decodes the object at the given byte offset.
  Object? _readObjectAtOffset(int offset) {
    final marker = _data[offset];
    final objectType = (marker >> 4) & 0x0F;
    final objectInfo = marker & 0x0F;

    switch (objectType) {
      case 0x0: // null, bool, fill
        return _readSingleton(objectInfo);
      case 0x1: // int
        return _readInt(offset, objectInfo);
      case 0x2: // real (float)
        return _readReal(offset, objectInfo);
      case 0x3: // date (treat as double)
        return _readDate(offset, objectInfo);
      case 0x4: // data (raw bytes)
        return _readData(offset, objectInfo);
      case 0x5: // ASCII string
        return _readAsciiString(offset, objectInfo);
      case 0x6: // Unicode string (UTF-16 BE)
        return _readUnicodeString(offset, objectInfo);
      case 0x8: // UID — objectInfo + 1 bytes, big-endian
        return PlistUid(_readUnsignedInt(offset + 1, objectInfo + 1));
      case 0xA: // array
        return _readArray(offset, objectInfo);
      case 0xD: // dict
        return _readDict(offset, objectInfo);
      default:
        throw ArgumentError(
          'Unsupported binary plist object type: 0x${objectType.toRadixString(16)} at offset $offset',
        );
    }
  }

  /// Reads a singleton value (null, bool, fill).
  Object? _readSingleton(int info) {
    switch (info) {
      case 0x0:
        return null; // null
      case 0x8:
        return false; // bool false
      case 0x9:
        return true; // bool true
      case 0xF:
        return null; // fill byte
      default:
        return null;
    }
  }

  /// Reads an integer. [sizeExponent] is log2 of byte count.
  int _readInt(int offset, int sizeExponent) {
    final byteCount = 1 << sizeExponent; // 1, 2, 4, or 8
    return _readUnsignedInt(offset + 1, byteCount);
  }

  /// Reads a real (float). [sizeExponent] is log2 of byte count.
  double _readReal(int offset, int sizeExponent) {
    final byteCount = 1 << sizeExponent;
    if (byteCount == 4) {
      return _byteData.getFloat32(offset + 1, Endian.big);
    } else if (byteCount == 8) {
      return _byteData.getFloat64(offset + 1, Endian.big);
    }
    throw ArgumentError('Unsupported real size: $byteCount bytes');
  }

  /// Reads a date (Core Foundation absolute time as float64).
  double _readDate(int offset, int sizeExponent) {
    return _byteData.getFloat64(offset + 1, Endian.big);
  }

  /// Reads raw data bytes.
  Uint8List _readData(int offset, int sizeInfo) {
    final (count, dataStart) = _readSizeAndDataStart(offset, sizeInfo);
    return Uint8List.fromList(_data.sublist(dataStart, dataStart + count));
  }

  /// Reads an ASCII string.
  String _readAsciiString(int offset, int sizeInfo) {
    final (count, dataStart) = _readSizeAndDataStart(offset, sizeInfo);
    return ascii.decode(
      _data.sublist(dataStart, dataStart + count),
      allowInvalid: true,
    );
  }

  /// Reads a UTF-16 BE string.
  String _readUnicodeString(int offset, int sizeInfo) {
    final (count, dataStart) = _readSizeAndDataStart(offset, sizeInfo);
    final codeUnits = <int>[];
    for (int i = 0; i < count; i++) {
      codeUnits.add(_byteData.getUint16(dataStart + i * 2, Endian.big));
    }
    return String.fromCharCodes(codeUnits);
  }

  /// Reads an array.
  List<Object?> _readArray(int offset, int sizeInfo) {
    final (count, refsStart) = _readSizeAndDataStart(offset, sizeInfo);
    final result = <Object?>[];
    for (int i = 0; i < count; i++) {
      final ref = _readUnsignedInt(
        refsStart + i * _objectRefSize,
        _objectRefSize,
      );
      result.add(_readObject(ref));
    }
    return result;
  }

  /// Reads a dict.
  Map<String, dynamic> _readDict(int offset, int sizeInfo) {
    final (count, refsStart) = _readSizeAndDataStart(offset, sizeInfo);
    final keyRefsStart = refsStart;
    final valRefsStart = refsStart + count * _objectRefSize;

    final result = <String, dynamic>{};
    for (int i = 0; i < count; i++) {
      final keyRef = _readUnsignedInt(
        keyRefsStart + i * _objectRefSize,
        _objectRefSize,
      );
      final valRef = _readUnsignedInt(
        valRefsStart + i * _objectRefSize,
        _objectRefSize,
      );
      final key = _readObject(keyRef);
      final value = _readObject(valRef);
      result[key.toString()] = value;
    }
    return result;
  }

  /// Reads the size from the marker byte, handling the extended size case.
  ///
  /// Returns `(count, dataStartOffset)` where [dataStartOffset] is the byte
  /// offset where the actual object data begins (after the size header).
  (int count, int dataStart) _readSizeAndDataStart(int offset, int sizeInfo) {
    if (sizeInfo < 0x0F) {
      return (sizeInfo, offset + 1);
    }
    // Extended size: next byte is an int marker (0x1N) encoding the real size
    final intMarker = _data[offset + 1];
    final intSizeExp = intMarker & 0x0F;
    final intByteCount = 1 << intSizeExp;
    final count = _readUnsignedInt(offset + 2, intByteCount);
    return (count, offset + 2 + intByteCount);
  }

  /// Reads a big-endian unsigned integer of [byteCount] bytes at [offset].
  int _readUnsignedInt(int offset, int byteCount) {
    int value = 0;
    for (int i = 0; i < byteCount; i++) {
      value = (value << 8) | _data[offset + i];
    }
    return value;
  }

  /// Reads a big-endian uint64 at [offset] using two 32-bit reads.
  int _readUint64BE(int offset) {
    final high = _byteData.getUint32(offset, Endian.big);
    final low = _byteData.getUint32(offset + 4, Endian.big);
    return (high << 32) | low;
  }
}

/// Encodes Dart objects into Apple binary plist format (`bplist00`).
///
/// Supports: [String], [int], [double], [bool], `null`, [Uint8List] (data),
/// [Map<String, dynamic>] (dict), and [List] (array).
///
/// The binary plist format consists of:
/// 1. Header: `bplist00` (8 bytes)
/// 2. Object table: serialized objects
/// 3. Offset table: byte offsets to each object
/// 4. Trailer: 32 bytes of metadata
///
/// Reference: Apple's binary plist specification and Python's `plistlib`.
class BinaryPlistEncoder {
  /// Encodes a [Map<String, dynamic>] as Apple binary plist format.
  ///
  /// Returns a [Uint8List] starting with the `bplist00` magic bytes.
  static Uint8List encode(Map<String, dynamic> dict) {
    final encoder = BinaryPlistEncoder._();
    return encoder._encode(dict);
  }

  BinaryPlistEncoder._();

  /// Flattened list of all objects in order of their reference index.
  final List<Object?> _objects = [];

  /// Child reference indices for each container object, keyed by the
  /// container's own index (dict: keys then values; array: items).
  ///
  /// References are recorded positionally while flattening rather than looked
  /// up by value afterwards. A value-keyed lookup conflates `0` with `0.0`
  /// (Dart's `==` and `hashCode` treat them as equal), which silently swapped
  /// int and real types, and could not find `NaN` at all.
  final Map<int, List<int>> _childRefs = {};

  /// Assigns a reference index to [obj], recursively flattening dicts/lists.
  ///
  /// Returns the reference index for [obj].
  int _flatten(Object? obj) {
    if (obj == null ||
        obj is bool ||
        obj is int ||
        obj is double ||
        obj is String ||
        obj is Uint8List) {
      return _addObject(obj);
    }
    if (obj is Map<String, dynamic>) {
      // Add the dict object first to get its index, then flatten children.
      final refIndex = _addObject(obj);
      final keyRefs = <int>[];
      final valueRefs = <int>[];
      for (final entry in obj.entries) {
        keyRefs.add(_flatten(entry.key));
        valueRefs.add(_flatten(entry.value));
      }
      _childRefs[refIndex] = [...keyRefs, ...valueRefs];
      return refIndex;
    }
    if (obj is List) {
      final refIndex = _addObject(obj);
      _childRefs[refIndex] = [for (final item in obj) _flatten(item)];
      return refIndex;
    }
    throw ArgumentError('Unsupported plist type: ${obj.runtimeType}');
  }

  int _addObject(Object? obj) {
    _objects.add(obj);
    return _objects.length - 1;
  }

  Uint8List _encode(Map<String, dynamic> rootDict) {
    // Phase 1: Flatten all objects to get reference indices.
    _objects.clear();
    _childRefs.clear();
    _flatten(rootDict);

    final numObjects = _objects.length;

    // Determine object ref size (bytes needed to encode a ref index).
    final objectRefSize = _bytesNeeded(numObjects);

    // Phase 2: Serialize each object and record offsets.
    final objectData = BytesBuilder(copy: false);
    final offsets = <int>[];

    // Write header: bplist00
    objectData.add(ascii.encode('bplist00'));

    for (int i = 0; i < numObjects; i++) {
      offsets.add(objectData.length);
      _writeObject(i, objectData, objectRefSize);
    }

    // Phase 3: Write offset table.
    final offsetTableOffset = objectData.length;
    final offsetSize = _bytesNeeded(offsetTableOffset);

    for (final offset in offsets) {
      objectData.add(_encodeUnsignedInt(offset, offsetSize));
    }

    // Phase 4: Write trailer (32 bytes).
    final trailer = ByteData(32);
    // Bytes 0-5: unused (zero)
    trailer.setUint8(6, offsetSize); // byte 6: offset int size
    trailer.setUint8(7, objectRefSize); // byte 7: object ref size
    // Bytes 8-15: number of objects (big-endian uint64)
    _setUint64BE(trailer, 8, numObjects);
    // Bytes 16-23: top object index (0, big-endian uint64)
    _setUint64BE(trailer, 16, 0);
    // Bytes 24-31: offset table offset (big-endian uint64)
    _setUint64BE(trailer, 24, offsetTableOffset);

    objectData.add(trailer.buffer.asUint8List());

    return Uint8List.fromList(objectData.toBytes());
  }

  /// Serializes the object at [index] into the byte builder.
  void _writeObject(int index, BytesBuilder builder, int objectRefSize) {
    final obj = _objects[index];
    if (obj == null) {
      builder.addByte(0x00); // null
      return;
    }
    if (obj is bool) {
      builder.addByte(obj ? 0x09 : 0x08);
      return;
    }
    if (obj is int) {
      _writeInt(obj, builder);
      return;
    }
    if (obj is double) {
      _writeReal(obj, builder);
      return;
    }
    if (obj is String) {
      _writeString(obj, builder);
      return;
    }
    if (obj is Uint8List) {
      _writeSizeHeader(0x40, obj.length, builder);
      builder.add(obj);
      return;
    }
    if (obj is Map<String, dynamic>) {
      _writeContainer(
        0xD0,
        obj.length,
        _childRefs[index]!,
        builder,
        objectRefSize,
      );
      return;
    }
    if (obj is List) {
      _writeContainer(
        0xA0,
        obj.length,
        _childRefs[index]!,
        builder,
        objectRefSize,
      );
      return;
    }
    throw ArgumentError('Unsupported plist type: ${obj.runtimeType}');
  }

  /// Writes an integer object.
  ///
  /// Format: 0x1N where N is log2(byte_count).
  /// Encodes as the smallest power-of-2 byte count that fits.
  void _writeInt(int value, BytesBuilder builder) {
    if (value >= 0 && value < 0x100) {
      builder.addByte(0x10); // 1-byte int
      builder.addByte(value & 0xFF);
    } else if (value >= 0 && value < 0x10000) {
      builder.addByte(0x11); // 2-byte int
      final bd = ByteData(2);
      bd.setUint16(0, value, Endian.big);
      builder.add(bd.buffer.asUint8List());
    } else if (value >= 0 && value < 0x100000000) {
      builder.addByte(0x12); // 4-byte int
      final bd = ByteData(4);
      bd.setUint32(0, value, Endian.big);
      builder.add(bd.buffer.asUint8List());
    } else {
      builder.addByte(0x13); // 8-byte int
      final bd = ByteData(8);
      // Dart int is 64-bit on VM, but ByteData has no setInt64 with big-endian
      // that handles negative values portably. Use two 32-bit writes.
      bd.setUint32(0, (value >> 32) & 0xFFFFFFFF, Endian.big);
      bd.setUint32(4, value & 0xFFFFFFFF, Endian.big);
      builder.add(bd.buffer.asUint8List());
    }
  }

  /// Writes a float64 (real) object.
  ///
  /// Format: 0x23 followed by 8-byte big-endian IEEE 754 double.
  void _writeReal(double value, BytesBuilder builder) {
    builder.addByte(0x23); // 8-byte float
    final bd = ByteData(8);
    bd.setFloat64(0, value, Endian.big);
    builder.add(bd.buffer.asUint8List());
  }

  /// Writes a string object.
  ///
  /// Uses ASCII (0x5N) if the string is pure ASCII, otherwise Unicode (0x6N).
  /// If length >= 15, writes 0xNF followed by an encoded int length.
  void _writeString(String value, BytesBuilder builder) {
    final isAscii = value.codeUnits.every((c) => c < 128);

    if (isAscii) {
      final bytes = ascii.encode(value);
      _writeSizeHeader(0x50, bytes.length, builder);
      builder.add(bytes);
    } else {
      // UTF-16 BE encoding
      final codeUnits = value.codeUnits;
      _writeSizeHeader(0x60, codeUnits.length, builder);
      final bd = ByteData(codeUnits.length * 2);
      for (int i = 0; i < codeUnits.length; i++) {
        bd.setUint16(i * 2, codeUnits[i], Endian.big);
      }
      builder.add(bd.buffer.asUint8List());
    }
  }

  /// Writes a dict (`0xDN`: N key refs then N value refs) or array
  /// (`0xAN`: N item refs) from the refs recorded while flattening.
  void _writeContainer(
    int marker,
    int count,
    List<int> refs,
    BytesBuilder builder,
    int objectRefSize,
  ) {
    _writeSizeHeader(marker, count, builder);
    for (final ref in refs) {
      builder.add(_encodeUnsignedInt(ref, objectRefSize));
    }
  }

  /// Writes a type+size header byte.
  ///
  /// If [size] < 15, it is packed into the low nibble of the marker byte.
  /// If [size] >= 15, the low nibble is 0xF and the size follows as an int.
  void _writeSizeHeader(int markerHighNibble, int size, BytesBuilder builder) {
    if (size < 15) {
      builder.addByte(markerHighNibble | size);
    } else {
      builder.addByte(markerHighNibble | 0x0F);
      _writeInt(size, builder);
    }
  }

  /// Encodes an unsigned integer into exactly [byteCount] bytes (big-endian).
  static Uint8List _encodeUnsignedInt(int value, int byteCount) {
    final bytes = Uint8List(byteCount);
    for (int i = byteCount - 1; i >= 0; i--) {
      bytes[i] = value & 0xFF;
      value >>= 8;
    }
    return bytes;
  }

  /// Returns the minimum number of bytes needed to represent [value].
  static int _bytesNeeded(int value) {
    if (value <= 0xFF) return 1;
    if (value <= 0xFFFF) return 2;
    if (value <= 0xFFFFFFFF) return 4;
    return 8;
  }

  /// Sets a big-endian uint64 at [offset] in [bd].
  static void _setUint64BE(ByteData bd, int offset, int value) {
    bd.setUint32(offset, (value >> 32) & 0xFFFFFFFF, Endian.big);
    bd.setUint32(offset + 4, value & 0xFFFFFFFF, Endian.big);
  }
}

/// A binary plist UID (`0x8N`) — an `NSKeyedArchiver` object reference.
class PlistUid {
  /// The referenced object index.
  final int value;

  const PlistUid(this.value);

  @override
  bool operator ==(Object other) => other is PlistUid && other.value == value;

  @override
  int get hashCode => Object.hash(PlistUid, value);

  @override
  String toString() => 'PlistUid($value)';
}
