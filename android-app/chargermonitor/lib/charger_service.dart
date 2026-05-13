import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'protocol.dart';

enum ChargerConnectionState {
  disconnected,
  connecting,
  connected;

  String get jsonValue => name;
}

/// Immutable snapshot of the charger state, JSON-serialisable.
class ChargerState {
  const ChargerState({
    this.connection = ChargerConnectionState.disconnected,
    this.deviceType,
    this.deviceTypeCode,
    this.realtime,
    this.lastUpdateMs,
  });

  final ChargerConnectionState connection;
  final String? deviceType;
  final int? deviceTypeCode;
  final RealtimeData? realtime;
  final int? lastUpdateMs;

  Map<String, dynamic> toJson() {
    final RealtimeData? d = realtime;
    return <String, dynamic>{
      'connection': connection.jsonValue,
      'device_type': deviceType,
      'device_type_code': deviceTypeCode,
      'last_update_ms': lastUpdateMs,
      'data': d == null
          ? null
          : <String, dynamic>{
              'battery_voltage_v': d.batteryVoltageV,
              'battery_current_a': d.batteryCurrentA,
              'assistant_battery_voltage_v': d.assistantBatteryVoltageV,
              'assistant_battery_current_a': d.assistantBatteryCurrentA,
              'solar_panel_voltage_v': d.solarPanelVoltageV,
              'solar_panel_power_w': d.solarPanelPowerW,
              'load_voltage_v': d.loadVoltageV,
              'load_current_a': d.loadCurrentA,
              'load_power_w': d.loadPowerW,
              'starting_battery_voltage_v': d.startingBatteryVoltageV,
              'starting_battery_voltage2_v': d.startingBatteryVoltage2V,
              'charge_capacity_ah': d.chargeCapacity,
              'charge_energy_wh': d.chargeEnergy,
              'assistant_charge_capacity_ah': d.assistantChargeCapacity,
              'assistant_charge_energy_wh': d.assistantChargeEnergy,
            },
      'flags': d == null
          ? null
          : <String, dynamic>{
              'charge_state': d.chargeState,
              'assistant_charge_state': d.assistantChargeState,
              'full_charge': d.fullCharge,
              'over_temp': d.overTemp,
              'battery_over_pressure': d.batteryOverPressure,
              'pv_over_pressure': d.pvOverPressure,
              'battery_under_voltage': d.batteryUnderVoltage,
            },
    };
  }
}

/// Manages a persistent BLE connection to the solar charge controller.
/// Designed to run inside an Android foreground service.
class ChargerService {
  static const Map<int, String> _deviceTypeNames = <int, String>{
    0x01: 'MPPT 5012',
    0x02: 'MPPT 5020',
    0x03: 'MPPT 5010',
    0x04: 'Two-in-One',
    0x05: 'B-to-B',
    0x06: 'AC',
    0x07: 'Dual Battery',
    0x10: 'Two-in-One Solar',
    0x11: 'Two-in-One B-to-B',
  };

  final ProtocolParser _parser = ProtocolParser();
  BluetoothDevice? _device;
  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? _writeChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _heartbeatTimer;
  Timer? _bootstrapTimer;
  Timer? _reconnectTimer;

  bool _stopped = false;
  bool _connecting = false;
  int _reconnectAttempt = 0;

  ChargerState _state = const ChargerState();

  final StreamController<ChargerState> _stateController =
      StreamController<ChargerState>.broadcast();

  Stream<ChargerState> get stateStream => _stateController.stream;
  ChargerState get state => _state;

  void _emit(ChargerState s) {
    _state = s;
    if (!_stateController.isClosed) {
      _stateController.add(s);
    }
  }

  /// Connect to a BLE device identified by MAC [mac]. Reconnects automatically.
  void setTargetDevice(String mac) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _device = BluetoothDevice.fromId(mac);
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _bootstrapTimer?.cancel();
    try {
      await _notifySub?.cancel();
    } catch (_) {}
    try {
      await _connSub?.cancel();
    } catch (_) {}
    try {
      await _device?.disconnect();
    } catch (_) {}
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }

  Future<void> _clearTransport() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    try {
      await _notifySub?.cancel();
    } catch (_) {}
    _notifySub = null;
    _notifyChar = null;
    _writeChar = null;
  }

  Future<void> _connect() async {
    if (_stopped || _connecting || _device == null) return;
    _connecting = true;
    try {
      await _clearTransport();
      _emit(ChargerState(
        connection: ChargerConnectionState.connecting,
        deviceType: _state.deviceType,
        deviceTypeCode: _state.deviceTypeCode,
      ));

      await _connSub?.cancel();
      _connSub = _device!.connectionState.listen(
        (BluetoothConnectionState s) {
          if (_stopped) return;
          if (s == BluetoothConnectionState.disconnected) {
            _onDisconnected();
          }
        },
      );

      await _device!.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 12),
      );
      await _device!.requestMtu(512);

      final List<BluetoothService> services = await _device!.discoverServices();
      _resolveCharacteristics(services);

      if (_notifyChar == null || _writeChar == null) {
        throw StateError('Required BLE characteristics (2AF0/2AF1) not found');
      }

      await _notifyChar!.setNotifyValue(true);
      _notifySub = _notifyChar!.onValueReceived.listen(_onNotify);

      await _send(ChargerProtocol.requestDeviceType);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _send(ChargerProtocol.requestBaseData);

      int bootstrapTick = 0;
      _bootstrapTimer = Timer.periodic(const Duration(seconds: 2), (Timer t) {
        bootstrapTick++;
        if (bootstrapTick >= 8 || _state.realtime != null) {
          t.cancel();
          return;
        }
        _send(ChargerProtocol.requestBaseData);
      });

      _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _send(ChargerProtocol.requestHeartBeat);
      });

      _reconnectAttempt = 0;
      _emit(ChargerState(
        connection: ChargerConnectionState.connected,
        deviceType: _state.deviceType,
        deviceTypeCode: _state.deviceTypeCode,
        realtime: _state.realtime,
        lastUpdateMs: _state.lastUpdateMs,
      ));
    } catch (e) {
      debugPrint('[ChargerService] Connect error: $e');
      _onDisconnected();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _send(List<int> bytes) async {
    try {
      await _writeChar?.write(bytes, withoutResponse: false);
    } catch (_) {}
  }

  void _resolveCharacteristics(List<BluetoothService> services) {
    for (final BluetoothService svc in services) {
      final bool isTarget = svc.uuid.str.toUpperCase().contains('18F0');
      for (final BluetoothCharacteristic c in svc.characteristics) {
        final String uuid = c.uuid.str.toUpperCase();
        if (uuid.contains('2AF0') && isTarget) _notifyChar = c;
        if (uuid.contains('2AF1') && isTarget) _writeChar = c;
      }
      if (_notifyChar != null && _writeChar != null) return;
    }
    // Fallback: search all services if target service UUID not matched.
    for (final BluetoothService svc in services) {
      for (final BluetoothCharacteristic c in svc.characteristics) {
        final String uuid = c.uuid.str.toUpperCase();
        if (_notifyChar == null && uuid.contains('2AF0')) _notifyChar = c;
        if (_writeChar == null && uuid.contains('2AF1')) _writeChar = c;
      }
    }
  }

  void _onNotify(List<int> data) {
    for (final List<int> frame in _parser.appendAndExtract(data)) {
      if (frame.length == 4 && frame[1] == 0xE1) {
        final int code = frame[2] & 0xFF;
        _emit(ChargerState(
          connection: _state.connection,
          deviceType: _deviceTypeNames[code] ?? 'Type 0x${code.toRadixString(16)}',
          deviceTypeCode: code,
          realtime: _state.realtime,
          lastUpdateMs: _state.lastUpdateMs,
        ));
      } else if (frame.length == 40 && frame[1] == 0xE2) {
        try {
          final RealtimeData rd = RealtimeData.fromFrame(frame);
          _emit(ChargerState(
            connection: ChargerConnectionState.connected,
            deviceType: _state.deviceType,
            deviceTypeCode: _state.deviceTypeCode,
            realtime: rd,
            lastUpdateMs: DateTime.now().millisecondsSinceEpoch,
          ));
        } catch (_) {}
      }
    }
  }

  void _onDisconnected() {
    if (_stopped) return;
    _clearTransport();
    _reconnectAttempt++;
    final int delay = _reconnectAttempt <= 2 ? 2 : 5;
    _emit(ChargerState(
      connection: ChargerConnectionState.disconnected,
      deviceType: _state.deviceType,
    ));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      _reconnectTimer = null;
      _connect();
    });
  }
}
