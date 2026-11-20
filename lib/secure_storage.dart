/// Backend-owned Windows DPAPI storage for Schwab credentials and OAuth tokens.
///
/// The application never writes plaintext secrets to disk or includes them in
/// URLs, logs, or child-process arguments. DPAPI binds the encrypted value to
/// the current Windows user account.
///
/// Encryption calls `CryptProtectData`/`CryptUnprotectData` directly through
/// `dart:ffi`; no helper process is involved, so it also works when the
/// backend runs detached without a console. The file format is a hex-encoded
/// DPAPI blob of the UTF-16LE JSON text, which matches the format produced by
/// PowerShell `ConvertFrom-SecureString` in earlier versions.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

class SecureStorage {
  SecureStorage({Directory? directory})
    : _directory =
          directory ??
          Directory(
            '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
            r'\ATrader',
          );

  final Directory _directory;
  File get _file => File('${_directory.path}\\secrets.dpapi');

  Future<void> save(Map<String, String> secrets) async {
    _requireWindows();
    await _directory.create(recursive: true);
    final plain = _utf16LittleEndian(jsonEncode(secrets));
    final encrypted = WindowsDpapi.protect(plain);
    plain.fillRange(0, plain.length, 0);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(_toHex(encrypted), flush: true);
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }

  Future<Map<String, String>> load() async {
    _requireWindows();
    if (!await _file.exists()) return {};
    final Map<String, dynamic> decoded;
    try {
      final encrypted = _fromHex((await _file.readAsString()).trim());
      final plain = WindowsDpapi.unprotect(encrypted);
      decoded =
          jsonDecode(_fromUtf16LittleEndian(plain)) as Map<String, dynamic>;
      plain.fillRange(0, plain.length, 0);
    } on Object {
      throw const SecureStorageException(
        'Saved Schwab credentials could not be decrypted for this Windows '
        'user. Enter the Client ID and Client Secret again to replace them.',
      );
    }
    return decoded.map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> remove() async {
    _requireWindows();
    if (await _file.exists()) await _file.delete();
  }

  void _requireWindows() {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Protected secret storage is implemented only for Windows.',
      );
    }
  }

  static Uint8List _utf16LittleEndian(String text) {
    final bytes = Uint8List(text.length * 2);
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      bytes[index * 2] = unit & 0xff;
      bytes[index * 2 + 1] = unit >> 8;
    }
    return bytes;
  }

  static String _fromUtf16LittleEndian(Uint8List bytes) {
    if (bytes.length.isOdd) throw const FormatException('Invalid UTF-16 data.');
    return String.fromCharCodes([
      for (var index = 0; index < bytes.length; index += 2)
        bytes[index] | (bytes[index + 1] << 8),
    ]);
  }

  static String _toHex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    if (hex.isEmpty || hex.length.isOdd) {
      throw const FormatException('Invalid protected data.');
    }
    final bytes = Uint8List(hex.length ~/ 2);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = int.parse(
        hex.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    return bytes;
  }
}

class SecureStorageException implements Exception {
  const SecureStorageException(this.message);
  final String message;

  @override
  String toString() => message;
}

final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptDataNative =
    Int32 Function(
      Pointer<_DataBlob> input,
      Pointer<Void> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> output,
    );
typedef _CryptData =
    int Function(
      Pointer<_DataBlob> input,
      Pointer<Void> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> output,
    );

/// Current-user Windows DPAPI without optional entropy or UI prompts.
class WindowsDpapi {
  static const _uiForbidden = 0x1;
  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _cryptProtect = _crypt32
      .lookupFunction<_CryptDataNative, _CryptData>('CryptProtectData');
  static final _cryptUnprotect = _crypt32
      .lookupFunction<_CryptDataNative, _CryptData>('CryptUnprotectData');
  static final _localAlloc = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  static final _localFree = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  static final _getLastError = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  static Uint8List protect(Uint8List plain) => _run(_cryptProtect, plain);

  static Uint8List unprotect(Uint8List encrypted) =>
      _run(_cryptUnprotect, encrypted);

  static Uint8List _run(_CryptData function, Uint8List bytes) {
    const zeroInitialized = 0x40;
    final input = _localAlloc(
      zeroInitialized,
      sizeOf<_DataBlob>(),
    ).cast<_DataBlob>();
    final output = _localAlloc(
      zeroInitialized,
      sizeOf<_DataBlob>(),
    ).cast<_DataBlob>();
    final buffer = _localAlloc(
      zeroInitialized,
      bytes.isEmpty ? 1 : bytes.length,
    ).cast<Uint8>();
    if (input.address == 0 || output.address == 0 || buffer.address == 0) {
      throw StateError('Windows could not allocate protected-data memory.');
    }
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref
        ..length = bytes.length
        ..data = buffer;
      final ok = function(
        input,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) {
        throw StateError(
          'Windows DPAPI operation failed (error ${_getLastError()}).',
        );
      }
      final result = Uint8List.fromList(
        output.ref.data.asTypedList(output.ref.length),
      );
      output.ref.data
          .asTypedList(output.ref.length)
          .fillRange(0, output.ref.length, 0);
      _localFree(output.ref.data.cast());
      return result;
    } finally {
      buffer.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      _localFree(buffer.cast());
      _localFree(input.cast());
      _localFree(output.cast());
    }
  }
}
