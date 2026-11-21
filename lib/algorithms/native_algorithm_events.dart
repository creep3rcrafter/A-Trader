import 'dart:ffi';
import 'dart:io';

/// Windows event notifications wake the other process immediately. This avoids
/// two timer/poll delays for every candle and uses no CPU while the worker idles.
class NativeAlgorithmEvents {
  NativeAlgorithmEvents(String directory) {
    if (!enabled) return;
    final id = directory.split(RegExp(r'[/\\]')).last;
    _request = _create('Local\\ATrader-$id-request');
    _response = _create('Local\\ATrader-$id-response');
  }
  bool get enabled => Platform.isWindows;
  Pointer<Void> _request = nullptr, _response = nullptr;
  static final _kernel = Platform.isWindows
      ? DynamicLibrary.open('kernel32.dll')
      : null;
  static final _heap = _kernel!
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  static final _allocate = _kernel!
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  static final _free = _kernel!
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  static final _createEvent = _kernel!
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Int32, Int32, Pointer<Uint16>),
        Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Uint16>)
      >('CreateEventW');
  static final _setEvent = _kernel!
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('SetEvent');
  static final _wait = _kernel!
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  static final _close = _kernel!
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');

  Pointer<Void> _create(String name) {
    final buffer = _allocate(_heap, 0x8, (name.length + 1) * 2);
    if (buffer == nullptr) {
      throw StateError('Could not allocate the Dart worker notification.');
    }
    try {
      buffer
          .cast<Uint16>()
          .asTypedList(name.length + 1)
          .setAll(0, name.codeUnits);
      final handle = _createEvent(nullptr, 0, 0, buffer.cast<Uint16>());
      if (handle == nullptr) {
        throw StateError('Could not create the Dart worker notification.');
      }
      return handle;
    } finally {
      _free(_heap, 0, buffer);
    }
  }

  void requestReady() {
    if (enabled && _setEvent(_request) == 0) {
      throw StateError('Could not notify the Dart worker.');
    }
  }

  void responseReady() {
    if (enabled && _setEvent(_response) == 0) {
      throw StateError('Could not notify the simulator.');
    }
  }

  void waitForRequest() {
    if (enabled && _wait(_request, 0xffffffff) != 0) {
      throw StateError('Dart worker request notification failed.');
    }
  }

  bool waitForResponse(Duration timeout) =>
      !enabled || _wait(_response, timeout.inMilliseconds) == 0;
  void close() {
    if (!enabled) return;
    if (_request != nullptr) {
      _close(_request);
      _request = nullptr;
    }
    if (_response != nullptr) {
      _close(_response);
      _response = nullptr;
    }
  }
}
