import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:flutter/foundation.dart';

/// Thrown when the ELM327 layer encounters a non-recoverable error.
class Elm327Exception implements Exception {
  const Elm327Exception(this.message);
  final String message;
  @override
  String toString() => 'Elm327Exception: $message';
}

/// Manages a Classic-BT RFCOMM connection to an ELM327 OBD adapter.
///
/// Uses the `bluetooth_classic` plugin which supports Android Classic BT / SPP.
///
/// Usage:
///   final elm = Elm327();
///   await elm.connect('AA:BB:CC:DD:EE:FF');
///   final ver = await elm.send('ATZ', timeout: Duration(seconds: 3));
///   await elm.disconnect();
///
/// Thread-safety: only one [send] may be in flight at a time.
class Elm327 {
  static const String _elmPrompt = '>';
  // SPP (Serial Port Profile) UUID – used by virtually all ELM327 adapters.
  static const String _sppUuid = '00001101-0000-1000-8000-00805f9b34fb';

  final BluetoothClassic _bt = BluetoothClassic();
  StreamSubscription<Uint8List>? _inputSub;
  StreamSubscription<int>? _statusSub;
  final StringBuffer _buf = StringBuffer();
  Completer<String>? _pending;
  bool _connected = false;
  bool _closing = false;

  bool get isConnected => _connected;

  /// Connect to a paired ELM327 adapter by its Bluetooth MAC address.
  /// Throws [Elm327Exception] or [TimeoutException] on failure.
  Future<void> connect(String address) async {
    await disconnect();
    _closing = false;
    debugPrint('[ELM327] Connecting to $address');

    final ok = await _bt.connect(address, _sppUuid)
        .timeout(const Duration(seconds: 15), onTimeout: () {
      throw Elm327Exception('connect timeout to $address');
    });
    if (!ok) throw Elm327Exception('connect returned false for $address');

    _buf.clear();
    _pending = null;
    _connected = true;

    _inputSub = _bt.onDeviceDataReceived().listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );

    // Monitor connection status to detect remote disconnection.
    _statusSub = _bt.onDeviceStatusChanged().listen((status) {
      if (status == 0 /* disconnected */ && !_closing) {
        debugPrint('[ELM327] Status: disconnected');
        _connected = false;
        _onDone();
      }
    });

    debugPrint('[ELM327] Connected to $address');
  }

  /// Disconnect and free resources. Safe to call multiple times.
  Future<void> disconnect() async {
    _closing = true;
    _connected = false;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const Elm327Exception('disconnected'));
    }
    await _inputSub?.cancel();
    _inputSub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    try {
      await _bt.disconnect();
    } catch (_) {}
    _buf.clear();
    _closing = false;
  }

  /// Send a single AT command or OBD command (without trailing '\r').
  /// Returns the ELM327 response string (trimmed, prompt stripped).
  /// Throws [Elm327Exception] on error or timeout.
  Future<String> send(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_connected) throw const Elm327Exception('not connected');
    if (_pending != null) throw const Elm327Exception('command already in progress');

    _buf.clear();
    _pending = Completer<String>();
    await _bt.write('$command\r');

    return _pending!.future.timeout(timeout, onTimeout: () {
      _pending = null;
      throw Elm327Exception('timeout waiting for response to: $command');
    });
  }

  /// Run the standard ELM327 init sequence for OBD-II.
  ///
  /// Returns the auto-detected protocol description string from ATDP.
  Future<String> initialize() async {
    // Reset – ELM may echo version string; wait for prompt.
    debugPrint('[ELM327] Sending ATZ');
    await send('ATZ', timeout: const Duration(seconds: 5));
    // Small delay to allow ELM to fully restart.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await send('ATE0'); // echo off
    await send('ATL0'); // linefeeds off
    await send('ATH0'); // headers off (simplifies response parsing)
    await send('ATS0'); // spaces off (compact hex: "410C1AF8")
    await send('ATAL'); // allow long messages (>7 data bytes)
    await send('ATSP0'); // auto-detect OBD protocol

    // Trigger protocol detection – query supported PIDs (mode 01 PID 00).
    // May respond "NO DATA" if engine is off; that's acceptable here.
    try {
      await send('0100', timeout: const Duration(seconds: 6));
    } catch (_) {
      // Ignore – engine may be off.
    }

    final protocolDesc = await send('ATDP');
    debugPrint('[ELM327] Protocol: $protocolDesc');
    return protocolDesc.trim();
  }

  // ── Internal helpers ────────────────────────────────────────────────────

  void _onData(Uint8List bytes) {
    // Decode Latin-1 (ELM327 uses ASCII subset; Latin-1 is a safe superset).
    _buf.write(latin1.decode(bytes, allowInvalid: true));
    final s = _buf.toString();
    // ELM327 terminates every response with '>'.
    if (s.contains(_elmPrompt)) {
      final response = s.split(_elmPrompt).first.trim();
      _buf.clear();
      final pending = _pending;
      _pending = null;
      if (pending != null && !pending.isCompleted) {
        pending.complete(response);
      }
    }
  }

  void _onError(Object error) {
    debugPrint('[ELM327] Stream error: $error');
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(Elm327Exception('stream error: $error'));
    }
  }

  void _onDone() {
    debugPrint('[ELM327] Connection closed by remote');
    if (!_closing) {
      final pending = _pending;
      _pending = null;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(const Elm327Exception('connection closed by remote'));
      }
    }
  }
}
