import 'dart:async';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter/foundation.dart';

import 'elm327.dart';
import 'obd_protocol.dart';

/// Manages the full OBD lifecycle: connect → init → poll → auto-reconnect.
///
/// Runs inside the Android foreground service (background isolate).
/// External consumers read [state] or subscribe to [stateStream].
class OBDService {
  OBDService();

  // ── Configuration ──────────────────────────────────────────────────────

  /// How often the live-data polling loop fires.
  static const Duration _pollInterval = Duration(seconds: 1);

  /// How often full DTC list is refreshed (every N poll cycles).
  static const int _dtcRefreshCycles = 30;

  /// Delay before attempting reconnect after a failure.
  static const Duration _reconnectDelay = Duration(seconds: 5);

  // ── State ─────────────────────────────────────────────────────────────

  OBDState _state = const OBDState();
  final StreamController<OBDState> _stateCtrl =
      StreamController<OBDState>.broadcast();

  OBDState get state => _state;
  Stream<OBDState> get stateStream => _stateCtrl.stream;

  // ── Internals ─────────────────────────────────────────────────────────

  final Elm327 _elm = Elm327();
  String? _targetAddress;
  String? _targetName;
  Timer? _pollTimer;
  bool _running = false;
  int _pollCycle = 0;

  // Live accumulated data (mutated during poll, copied into OBDState)
  double?      _rpm;
  int?         _speed;
  double?      _coolant;
  double?      _oil;
  double?      _fuel;
  double?      _throttle;
  double?      _intake;
  double?      _maf;
  int?         _runTime;
  bool?        _mil;
  int?         _dtcCount;
  List<String> _dtcs = const <String>[];

  // ── Public API ────────────────────────────────────────────────────────

  /// Set the ELM327 BT device to connect to. Triggers (re)connection.
  void setTargetDevice(String address, {String? name}) {
    _targetAddress = address;
    _targetName = name ?? address;
    debugPrint('[OBDService] Target device set: $_targetName ($address)');
    _startConnection();
  }

  /// Trigger a DTC clear (OBD mode 04). Fire-and-forget.
  Future<void> clearDtcs() async {
    if (!_elm.isConnected) return;
    try {
      await _elm.send('04', timeout: const Duration(seconds: 5));
      // Reset local DTC state
      _dtcs = const <String>[];
      _dtcCount = 0;
      _mil = false;
      _pushState();
      debugPrint('[OBDService] DTCs cleared');
    } catch (e) {
      debugPrint('[OBDService] clearDtcs error: $e');
    }
  }

  /// Stop polling and disconnect. Call on foreground-service stop.
  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _elm.disconnect();
    _updateConnection(OBDConnectionState.disconnected);
  }

  // ── Connection lifecycle ──────────────────────────────────────────────

  void _startConnection() {
    if (!_running) {
      _running = true;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    _connectAndInit();
  }

  Future<void> _connectAndInit() async {
    final address = _targetAddress;
    if (address == null) return;

    _updateConnection(OBDConnectionState.connecting);
    try {
      await _elm.connect(address);
      final protocolDesc = await _elm.initialize();

      // Extract ELM version from ATI response (ATIDP returns protocol,
      // but ELM version is in ATZ response – capture via ATIV).
      String elmVersion = '';
      try {
        elmVersion = await _elm.send('ATI');
      } catch (_) {}

      _state = OBDState(
        connection:   OBDConnectionState.connected,
        deviceName:   _targetName,
        deviceAddress: address,
        elmVersion:   elmVersion.trim(),
        protocolDesc: protocolDesc,
        data:         null,
        lastUpdateMs: DateTime.now().millisecondsSinceEpoch,
      );
      _notifyState();

      _pollCycle = 0;
      _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    } catch (e) {
      debugPrint('[OBDService] Connect/init failed: $e');
      await _elm.disconnect();
      _updateConnection(OBDConnectionState.disconnected);
      if (_running) {
        // Auto-reconnect after delay
        Timer(_reconnectDelay, _connectAndInit);
      }
    }
  }

  // ── Polling loop ──────────────────────────────────────────────────────

  Future<void> _pollOnce() async {
    if (!_elm.isConnected) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _updateConnection(OBDConnectionState.disconnected);
      if (_running) {
        Timer(_reconnectDelay, _connectAndInit);
      }
      return;
    }

    try {
      // Fast-update PIDs (every cycle)
      _rpm      = parseRpm(await _elm.send('010C'));
      _speed    = parseSpeed(await _elm.send('010D'));
      _coolant  = parseTemp(await _elm.send('0105'), ObdPid.coolantTemp);
      _throttle = parsePercent(await _elm.send('0111'), ObdPid.throttlePos);

      // Medium-update PIDs (every 5 cycles)
      if (_pollCycle % 5 == 0) {
        _intake  = parseTemp(await _elm.send('010F'), ObdPid.intakeAirTemp);
        _maf     = parseMaf(await _elm.send('0110'));
        _fuel    = parsePercent(await _elm.send('012F'), ObdPid.fuelTankLevel);
        _runTime = parseRunTime(await _elm.send('011F'));
      }

      // Slow-update PIDs (every N cycles)
      if (_pollCycle % 10 == 0) {
        _oil = parseTemp(await _elm.send('015C'), ObdPid.oilTemp);
        final status = parseMonitorStatus(await _elm.send('0101'));
        if (status != null) {
          _mil = status.milOn;
          _dtcCount = status.dtcCount;
        }
      }

      // DTC full refresh
      if (_pollCycle % _dtcRefreshCycles == 0) {
        _dtcs = parseDtcs(await _elm.send('03'));
      }

      _pollCycle++;
      _pushState();
    } catch (e) {
      debugPrint('[OBDService] Poll error: $e');
      // On error, let next cycle check isConnected and reconnect if needed.
    }
  }

  // ── State helpers ─────────────────────────────────────────────────────

  void _updateConnection(OBDConnectionState conn) {
    _state = OBDState(
      connection:   conn,
      deviceName:   _state.deviceName,
      deviceAddress: _state.deviceAddress,
      elmVersion:   _state.elmVersion,
      protocolDesc: _state.protocolDesc,
      data:         conn == OBDConnectionState.connected ? _state.data : null,
      lastUpdateMs: DateTime.now().millisecondsSinceEpoch,
    );
    _notifyState();
  }

  void _pushState() {
    _state = OBDState(
      connection:   OBDConnectionState.connected,
      deviceName:   _state.deviceName,
      deviceAddress: _state.deviceAddress,
      elmVersion:   _state.elmVersion,
      protocolDesc: _state.protocolDesc,
      lastUpdateMs: DateTime.now().millisecondsSinceEpoch,
      data: OBDData(
        engineRpm:       _rpm,
        vehicleSpeedKmh: _speed,
        coolantTempC:    _coolant,
        oilTempC:        _oil,
        fuelLevelPct:    _fuel,
        throttlePosPct:  _throttle,
        intakeAirTempC:  _intake,
        mafGs:           _maf,
        runTimeS:        _runTime,
        milOn:           _mil,
        dtcCount:        _dtcCount,
        dtcs:            List<String>.unmodifiable(_dtcs),
      ),
    );
    _notifyState();
  }

  void _notifyState() {
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(_state);
    }
  }

  /// Returns a list of currently paired Bluetooth devices.
  /// Used by the UI to let the user select the ELM327 adapter.
  static Future<List<Device>> pairedDevices() async {
    final bt = BluetoothClassic();
    return bt.getPairedDevices();
  }
}
