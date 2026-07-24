import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'protocol.dart';

enum BatteryConnectionState {
  disconnected,
  connecting,
  connected;

  String get jsonValue => name;
}

class BatteryState {
  const BatteryState({
    this.connection = BatteryConnectionState.disconnected,
    this.deviceName,
    this.telemetry,
    this.lastUpdateMs,
  });

  final BatteryConnectionState connection;
  final String? deviceName;
  final LiTimeTelemetry? telemetry;
  final int? lastUpdateMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'connection': connection.jsonValue,
        'device_name': deviceName,
        'last_update_ms': lastUpdateMs,
        'data': telemetry?.toJson(),
      };
}

class LiTimeBatteryService {
  static final Guid _serviceUuid =
      Guid('F000FFC0-0451-4000-B000-000000000000');
  static final Guid _ffc1Uuid =
      Guid('F000FFC1-0451-4000-B000-000000000000');
  static final Guid _ffc2Uuid =
      Guid('F000FFC2-0451-4000-B000-000000000000');

  final LiTimeFrameParser _parser = LiTimeFrameParser();
  final StreamController<BatteryState> _stateController =
      StreamController<BatteryState>.broadcast();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCharacteristic;
  final List<StreamSubscription<List<int>>> _notificationSubscriptions =
      <StreamSubscription<List<int>>>[];
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  BatteryState _state = const BatteryState();
  bool _connecting = false;
  bool _stopped = false;
  int _reconnectAttempt = 0;

  Stream<BatteryState> get stateStream => _stateController.stream;
  BatteryState get state => _state;

  void setTargetDevice(String remoteId, {String? name}) {
    _stopped = false;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _device = BluetoothDevice.fromId(remoteId);
    debugPrint('[LiTimeBatteryService] Target $name ($remoteId)');
    _emit(BatteryState(deviceName: name));
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    await _clearTransport();
    try {
      await _connectionSubscription?.cancel();
    } catch (_) {}
    try {
      await _device?.disconnect();
    } catch (_) {}
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }

  void _emit(BatteryState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  Future<void> _connect() async {
    if (_stopped || _connecting || _device == null) {
      return;
    }
    _connecting = true;
    try {
      final BluetoothDevice device = _device!;
      await _clearTransport();
      debugPrint(
        '[LiTimeBatteryService] Connecting to ${device.remoteId.str} '
        '(attempt ${_reconnectAttempt + 1})',
      );
      _emit(BatteryState(
        connection: BatteryConnectionState.connecting,
        deviceName: _state.deviceName,
        telemetry: _state.telemetry,
        lastUpdateMs: _state.lastUpdateMs,
      ));

      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 30),
      );
      debugPrint('[LiTimeBatteryService] GATT connected');

      await _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen(
        (BluetoothConnectionState state) {
          debugPrint('[LiTimeBatteryService] Connection state: $state');
          if (!_stopped && state == BluetoothConnectionState.disconnected) {
            _onDisconnected();
          }
        },
      );

      final int mtu = await device.requestMtu(512);
      debugPrint('[LiTimeBatteryService] MTU: $mtu');
      final List<BluetoothService> services = await device.discoverServices();
      debugPrint(
        '[LiTimeBatteryService] Services: '
        '${services.map((BluetoothService service) => service.uuid).join(',')}',
      );
      await _configureCharacteristics(services);

      if (_writeCharacteristic == null) {
        throw StateError('No writable LiTime FFC1/FFC2 characteristic found');
      }

      _reconnectTimer?.cancel();
      _reconnectAttempt = 0;
      _emit(BatteryState(
        connection: BatteryConnectionState.connected,
        deviceName: _state.deviceName,
        telemetry: _state.telemetry,
        lastUpdateMs: _state.lastUpdateMs,
      ));
      await _requestTelemetry();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _requestTelemetry(),
      );
    } catch (error) {
      debugPrint('[LiTimeBatteryService] Connect error: $error');
      _onDisconnected();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _configureCharacteristics(
    List<BluetoothService> services,
  ) async {
    final List<BluetoothCharacteristic> candidates = <BluetoothCharacteristic>[];
    for (final BluetoothService service in services) {
      if (service.uuid != _serviceUuid) {
        continue;
      }
      for (final BluetoothCharacteristic characteristic
          in service.characteristics) {
        if (characteristic.uuid == _ffc1Uuid ||
            characteristic.uuid == _ffc2Uuid) {
          debugPrint(
            '[LiTimeBatteryService] Characteristic ${characteristic.uuid}: '
            'notify=${characteristic.properties.notify}, '
            'indicate=${characteristic.properties.indicate}, '
            'write=${characteristic.properties.write}, '
            'writeWithoutResponse='
            '${characteristic.properties.writeWithoutResponse}',
          );
          candidates.add(characteristic);
        }
      }
    }

    for (final BluetoothCharacteristic characteristic in candidates) {
      final bool canNotify =
          characteristic.properties.notify || characteristic.properties.indicate;
      if (canNotify) {
        await characteristic.setNotifyValue(true);
        debugPrint(
          '[LiTimeBatteryService] Notifications enabled on '
          '${characteristic.uuid}',
        );
        _notificationSubscriptions.add(
          characteristic.onValueReceived.listen(_onNotification),
        );
      }
    }

    final Iterable<BluetoothCharacteristic> writable = candidates.where(
      (BluetoothCharacteristic characteristic) =>
          characteristic.properties.write ||
          characteristic.properties.writeWithoutResponse,
    );
    _writeCharacteristic = writable
        .where((BluetoothCharacteristic characteristic) =>
            characteristic.uuid == _ffc1Uuid)
        .firstOrNull;
    _writeCharacteristic ??= writable.firstOrNull;
    debugPrint(
      '[LiTimeBatteryService] Write characteristic: '
      '${_writeCharacteristic?.uuid}',
    );
  }

  Future<void> _requestTelemetry() async {
    final BluetoothCharacteristic? characteristic = _writeCharacteristic;
    if (characteristic == null) {
      return;
    }
    try {
      debugPrint(
        '[LiTimeBatteryService] Requesting telemetry on '
        '${characteristic.uuid}',
      );
      await characteristic.write(
        LiTimeProtocol.requestTelemetry(),
        withoutResponse: !characteristic.properties.write &&
            characteristic.properties.writeWithoutResponse,
      );
    } catch (error) {
      debugPrint('[LiTimeBatteryService] Telemetry request failed: $error');
    }
  }

  void _onNotification(List<int> bytes) {
    debugPrint(
      '[LiTimeBatteryService] Notification: ${bytes.length} bytes '
      '${bytes.map((int value) => value.toRadixString(16).padLeft(2, '0')).join()}',
    );
    for (final LiTimeFrame frame in _parser.appendAndExtract(bytes)) {
      if (frame.command != LiTimeProtocol.telemetryResponseCommand) {
        continue;
      }
      try {
        final LiTimeTelemetry telemetry = LiTimeTelemetry.fromFrame(frame);
        _emit(BatteryState(
          connection: BatteryConnectionState.connected,
          deviceName: _state.deviceName,
          telemetry: telemetry,
          lastUpdateMs: DateTime.now().millisecondsSinceEpoch,
        ));
      } catch (error) {
        debugPrint('[LiTimeBatteryService] Invalid telemetry: $error');
      }
    }
  }

  Future<void> _clearTransport() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final StreamSubscription<List<int>> subscription
        in _notificationSubscriptions) {
      try {
        await subscription.cancel();
      } catch (_) {}
    }
    _notificationSubscriptions.clear();
    _writeCharacteristic = null;
  }

  void _onDisconnected() {
    if (_stopped) {
      return;
    }
    _clearTransport();
    _emit(BatteryState(
      connection: BatteryConnectionState.disconnected,
      deviceName: _state.deviceName,
      telemetry: _state.telemetry,
      lastUpdateMs: _state.lastUpdateMs,
    ));
    _reconnectAttempt++;
    final int delaySeconds = _reconnectAttempt <= 2 ? 2 : 5;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), _connect);
  }
}
