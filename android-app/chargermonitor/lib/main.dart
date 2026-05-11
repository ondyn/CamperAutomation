import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'protocol.dart';

void main() {
  runApp(const ChargerMonitorApp());
}

class ChargerMonitorApp extends StatelessWidget {
  const ChargerMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChargerConnect Viewer',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const DeviceScanPage(),
    );
  }
}

class DeviceScanPage extends StatefulWidget {
  const DeviceScanPage({super.key});

  @override
  State<DeviceScanPage> createState() => _DeviceScanPageState();
}

class _DeviceScanPageState extends State<DeviceScanPage> {
  final Map<String, ScanResult> _resultsById = <String, ScanResult>{};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  bool _isScanning = false;
  bool _permissionsGranted = false;
  bool _askingPermissions = false;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  String? _scanIssue;
  bool _permissionsPermanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((
      BluetoothAdapterState state,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        _adapterState = state;
      });
      if (state == BluetoothAdapterState.on && _permissionsGranted) {
        _startScan();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePermissionsAndStartScan();
    });
  }

  @override
  void dispose() {
    _adapterStateSubscription?.cancel();
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _ensurePermissionsAndStartScan() async {
    if (_askingPermissions) {
      return;
    }

    _askingPermissions = true;
    bool granted = false;
    try {
      granted = await _requestPermissions();
    } finally {
      _askingPermissions = false;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _permissionsGranted = granted;
      _permissionsPermanentlyDenied = !granted && _permissionsPermanentlyDenied;
      _scanIssue = granted
          ? null
          : _permissionsPermanentlyDenied
          ? 'Nearby devices permission is permanently denied. Open settings and allow it.'
          : 'Nearby devices permission is required to scan Bluetooth devices.';
    });

    if (!granted) {
      return;
    }

    if (await FlutterBluePlus.isSupported == false) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanIssue = 'This device does not support Bluetooth LE.';
      });
      return;
    }

    if (!Platform.isIOS && _adapterState != BluetoothAdapterState.on) {
      try {
        if (Platform.isAndroid) {
          await FlutterBluePlus.turnOn();
        }
      } catch (_) {
        // User may reject enable dialog; we still wait for state stream updates.
      }
    }

    await _startScan();
  }

  Future<void> _startScan() async {
    if (!_permissionsGranted) {
      return;
    }

    if (_adapterState != BluetoothAdapterState.on) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanIssue = 'Turn on Bluetooth to start scanning.';
      });
      return;
    }

    await _scanSubscription?.cancel();
    _resultsById.clear();
    setState(() {
      _isScanning = true;
      _scanIssue = null;
    });

    _scanSubscription = FlutterBluePlus.onScanResults.listen((
      List<ScanResult> results,
    ) {
      for (final ScanResult result in results) {
        _resultsById[result.device.remoteId.str] = result;
      }
      if (mounted) {
        setState(() {});
      }
    }, onError: (Object e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanIssue = 'Scan failed: $e';
      });
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: false,
        androidCheckLocationServices: false,
      );
      await FlutterBluePlus.isScanning.where((bool v) => v == false).first;
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanIssue = 'Unable to start scan: $e';
      });
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isScanning = false;
    });
  }

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final PermissionStatus scanStatus = await Permission.bluetoothScan.request();
    final PermissionStatus connectStatus =
        await Permission.bluetoothConnect.request();

    final bool permanentlyDenied =
        scanStatus.isPermanentlyDenied || connectStatus.isPermanentlyDenied;
    _permissionsPermanentlyDenied = permanentlyDenied;

    final bool nearbyGranted = scanStatus.isGranted && connectStatus.isGranted;
    if (nearbyGranted) {
      return true;
    }

    // Fallback for some older Android BLE stacks where location permission
    // can still affect discovery behavior.
    final PermissionStatus locationStatus =
        await Permission.locationWhenInUse.request();

    _permissionsPermanentlyDenied =
        _permissionsPermanentlyDenied || locationStatus.isPermanentlyDenied;

    return locationStatus.isGranted;
  }

  String _displayName(ScanResult result) {
    final String advName = result.advertisementData.advName.trim();
    if (advName.isNotEmpty) {
      return advName;
    }
    final String platformName = result.device.platformName.trim();
    if (platformName.isNotEmpty) {
      return platformName;
    }
    return 'Unnamed device';
  }

  bool _isPreferredDevice(ScanResult result) {
    final String name = _displayName(result).toUpperCase();
    return name.startsWith('SOLAR') || name.startsWith('BT10');
  }

  @override
  Widget build(BuildContext context) {
    final List<ScanResult> devices = _resultsById.values.toList()
      ..sort((ScanResult a, ScanResult b) {
        final int pref = (_isPreferredDevice(b) ? 1 : 0) -
            (_isPreferredDevice(a) ? 1 : 0);
        if (pref != 0) {
          return pref;
        }
        return b.rssi.compareTo(a.rssi);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Charger Device'),
        actions: <Widget>[
          IconButton(
            onPressed: _isScanning ? null : _ensurePermissionsAndStartScan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_permissionsGranted
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.bluetooth_searching, size: 52),
                    const SizedBox(height: 12),
                    const Text(
                      'Nearby devices permission is required to scan Bluetooth devices.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _ensurePermissionsAndStartScan,
                      child: const Text('Grant Nearby devices'),
                    ),
                    if (_permissionsPermanentlyDenied) ...<Widget>[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: openAppSettings,
                        child: const Text('Open app settings'),
                      ),
                    ],
                    if (_scanIssue != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        _scanIssue!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : devices.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _isScanning
                          ? 'Scanning for Bluetooth devices...'
                          : 'No devices found. Tap refresh.',
                      textAlign: TextAlign.center,
                    ),
                    if (_adapterState != BluetoothAdapterState.on) ...<Widget>[
                      const SizedBox(height: 8),
                      const Text(
                        'Bluetooth is currently off.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (_scanIssue != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        _scanIssue!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : ListView.separated(
              itemBuilder: (BuildContext context, int index) {
                final ScanResult result = devices[index];
                final BluetoothDevice device = result.device;
                final String name = _displayName(result);
                final bool preferred = _isPreferredDevice(result);
                return ListTile(
                  title: Text(name),
                  subtitle: Text(device.remoteId.str),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text('${result.rssi} dBm'),
                      if (preferred)
                        const Text(
                          'recommended',
                          style: TextStyle(fontSize: 11),
                        ),
                    ],
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DeviceDashboardPage(device: device),
                      ),
                    );
                  },
                );
              },
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemCount: devices.length,
            ),
    );
  }
}

class DeviceDashboardPage extends StatefulWidget {
  const DeviceDashboardPage({super.key, required this.device});

  final BluetoothDevice device;

  @override
  State<DeviceDashboardPage> createState() => _DeviceDashboardPageState();
}

class _DeviceDashboardPageState extends State<DeviceDashboardPage> {
  final ProtocolParser _parser = ProtocolParser();
  static const String _serviceUuid = '000018F0-0000-1000-8000-00805F9B34FB';
  static const String _notifyUuid = '00002AF0-0000-1000-8000-00805F9B34FB';
  static const String _writeUuid = '00002AF1-0000-1000-8000-00805F9B34FB';
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

  BluetoothCharacteristic? _notifyCharacteristic;
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSub;
  Timer? _heartbeatTimer;
  Timer? _bootstrapBaseDataTimer;
  Timer? _reconnectTimer;

  bool _isDisposed = false;
  bool _isConnecting = false;
  int _reconnectAttempt = 0;
  int _rxBytes = 0;
  int _rxFrames = 0;

  String _connectionState = 'Connecting...';
  int? _deviceType;
  RealtimeData? _realtime;
  String? _error;

  @override
  void initState() {
    super.initState();
    _observeConnectionState();
    _connect();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _connectionStateSub?.cancel();
    _notifySub?.cancel();
    _heartbeatTimer?.cancel();
    _bootstrapBaseDataTimer?.cancel();
    _reconnectTimer?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  void _observeConnectionState() {
    _connectionStateSub = widget.device.connectionState.listen((
      BluetoothConnectionState state,
    ) {
      if (_isDisposed || !mounted) {
        return;
      }

      if (state == BluetoothConnectionState.connected) {
        setState(() {
          _connectionState = 'Connected';
        });
        _reconnectAttempt = 0;
        _reconnectTimer?.cancel();
      } else if (state == BluetoothConnectionState.disconnected) {
        _handleDisconnected();
      }
    });
  }

  Future<void> _resetTransportSubscriptions() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _bootstrapBaseDataTimer?.cancel();
    _bootstrapBaseDataTimer = null;
    await _notifySub?.cancel();
    _notifySub = null;
    _notifyCharacteristic = null;
    _writeCharacteristic = null;
  }

  void _handleDisconnected() {
    _resetTransportSubscriptions();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed || _reconnectTimer != null) {
      return;
    }

    _reconnectAttempt++;
    final int seconds = _reconnectAttempt <= 2 ? 2 : 5;

    setState(() {
      _connectionState = 'Disconnected (reconnect in ${seconds}s)';
    });

    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      _connect();
    });
  }

  Future<void> _connect() async {
    if (_isDisposed || _isConnecting) {
      return;
    }

    _isConnecting = true;
    try {
      await _resetTransportSubscriptions();

      setState(() {
        _connectionState = 'Connecting...';
      });

      await widget.device.connect(timeout: const Duration(seconds: 12));
      final List<BluetoothService> services =
          await widget.device.discoverServices();

      _resolveProtocolCharacteristics(services);

      if (_notifyCharacteristic == null || _writeCharacteristic == null) {
        throw StateError(
          'Required protocol characteristics were not found. '
          'Discovered: ${_describeServices(services)}',
        );
      }

      await _notifyCharacteristic!.setNotifyValue(true);
      _notifySub = _notifyCharacteristic!.onValueReceived.listen(_onNotifyData);

      await _send(ChargerProtocol.requestDeviceType);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _send(ChargerProtocol.requestBaseData);

      // Bootstraps data flow on devices that do not immediately push base data.
      _bootstrapBaseDataTimer = Timer.periodic(
        const Duration(seconds: 2),
        (Timer t) {
          if (_realtime != null || _isDisposed) {
            t.cancel();
            return;
          }
          _send(ChargerProtocol.requestBaseData);
          if (t.tick >= 8) {
            t.cancel();
          }
        },
      );

      _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _send(ChargerProtocol.requestHeartBeat);
      });

      if (!mounted) {
        return;
      }
      setState(() {
        _connectionState = 'Connected';
        _error = null;
      });
    } catch (e) {
      if (!mounted) {
        _isConnecting = false;
        return;
      }
      setState(() {
        _connectionState = 'Disconnected';
        _error = e.toString();
      });
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _send(List<int> bytes) async {
    final BluetoothCharacteristic? writer = _writeCharacteristic;
    if (writer == null) {
      return;
    }
    await writer.write(bytes, withoutResponse: false);
  }

  void _resolveProtocolCharacteristics(List<BluetoothService> services) {
    BluetoothCharacteristic? notifyByPropertyInService;
    BluetoothCharacteristic? writeByPropertyInService;

    for (final BluetoothService service in services) {
      final bool isProtocolService = _uuidEquals(service.uuid.str, _serviceUuid);
      for (final BluetoothCharacteristic c in service.characteristics) {
        if (_uuidEquals(c.uuid.str, _notifyUuid)) {
          _notifyCharacteristic = c;
        }
        if (_uuidEquals(c.uuid.str, _writeUuid)) {
          _writeCharacteristic = c;
        }

        if (c.properties.notify || c.properties.indicate) {
          if (isProtocolService) {
            notifyByPropertyInService ??= c;
          }
        }

        if (c.properties.write || c.properties.writeWithoutResponse) {
          if (isProtocolService) {
            writeByPropertyInService ??= c;
          }
        }
      }
    }

    _notifyCharacteristic ??= notifyByPropertyInService;
    _writeCharacteristic ??= writeByPropertyInService;
  }

  String _describeServices(List<BluetoothService> services) {
    return services
        .map((BluetoothService s) {
          final String chars = s.characteristics
              .map(
                (BluetoothCharacteristic c) =>
                    '${c.uuid.str}[n=${c.properties.notify},'
                    'i=${c.properties.indicate},'
                    'w=${c.properties.write},'
                    'wwr=${c.properties.writeWithoutResponse}]',
              )
              .join(', ');
          return '{service:${s.uuid.str}, chars:[$chars]}';
        })
        .join('; ');
  }

  bool _uuidEquals(String discovered, String expected) {
    final String a = _normalize(discovered).replaceAll('-', '');
    final String b = _normalize(expected).replaceAll('-', '');

    if (a == b) {
      return true;
    }

    final int? shortA = _shortUuid16(a);
    final int? shortB = _shortUuid16(b);
    if (shortA != null && shortB != null && shortA == shortB) {
      return true;
    }

    return false;
  }

  int? _shortUuid16(String value) {
    if (value.isEmpty) {
      return null;
    }

    final String trimmed = value.toUpperCase();
    if (trimmed.length <= 8) {
      return int.tryParse(trimmed, radix: 16);
    }

    if (trimmed.length == 32) {
      final String leading32 = trimmed.substring(0, 8);
      return int.tryParse(leading32, radix: 16);
    }

    return null;
  }

  void _onNotifyData(List<int> data) {
    _rxBytes += data.length;
    for (final List<int> frame in _parser.appendAndExtract(data)) {
      _rxFrames++;
      if (frame.length == 4 && frame[0] == 0xFF && frame[1] == 0xE1) {
        setState(() {
          _deviceType = frame[2] & 0xFF;
        });
      } else if (frame.length == 40 && frame[0] == 0xFF && frame[1] == 0xE2) {
        try {
          final RealtimeData parsed = RealtimeData.fromFrame(frame);
          setState(() {
            _realtime = parsed;
          });
        } catch (_) {
          // Ignore malformed frames.
        }
      }
    }
  }

  String _normalize(String uuid) {
    return uuid.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final RealtimeData? d = _realtime;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName),
      ),
      body: SafeArea(
        child: _error != null
            ? Center(child: Text(_error!))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Text(
                    widget.device.remoteId.str,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  _StatusCard(
                    connectionState: _connectionState,
                    deviceType: _deviceType,
                    deviceTypeName: _deviceType == null
                        ? null
                        : (_deviceTypeNames[_deviceType!] ?? 'Unknown Type'),
                    rxBytes: _rxBytes,
                    rxFrames: _rxFrames,
                  ),
                  const SizedBox(height: 12),
                  if (d == null)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Waiting for realtime protocol frames...'),
                      ),
                    )
                  else ...<Widget>[
                    _MetricGrid(data: d),
                    const SizedBox(height: 12),
                    _FlagCard(data: d),
                  ],
                ],
              ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.connectionState,
    required this.deviceType,
    required this.deviceTypeName,
    required this.rxBytes,
    required this.rxFrames,
  });

  final String connectionState;
  final int? deviceType;
  final String? deviceTypeName;
  final int rxBytes;
  final int rxFrames;

  @override
  Widget build(BuildContext context) {
    final String typeText = deviceType == null
        ? 'unknown'
      : '${deviceTypeName ?? 'Unknown'} '
        '(0x${deviceType!.toRadixString(16).padLeft(2, '0').toUpperCase()})';

    return Card(
      child: ListTile(
        leading: const Icon(Icons.bluetooth_connected),
        title: Text('State: $connectionState'),
        subtitle: Text(
          'Device type: $typeText\nRX: $rxBytes bytes / $rxFrames frames',
        ),
      ),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.data});

  final RealtimeData data;

  @override
  Widget build(BuildContext context) {
    final List<_MetricItem> items = <_MetricItem>[
      _MetricItem('Battery Current', '${data.batteryCurrentA.toStringAsFixed(1)} A'),
      _MetricItem('Battery Voltage', '${data.batteryVoltageV.toStringAsFixed(2)} V'),
      _MetricItem('Assistant Current', '${data.assistantBatteryCurrentA.toStringAsFixed(1)} A'),
      _MetricItem('Assistant Voltage', '${data.assistantBatteryVoltageV.toStringAsFixed(2)} V'),
      _MetricItem('Solar Power', '${data.solarPanelPowerW} W'),
      _MetricItem('Solar Voltage', '${data.solarPanelVoltageV.toStringAsFixed(1)} V'),
      _MetricItem('Load Current', '${data.loadCurrentA.toStringAsFixed(1)} A'),
      _MetricItem('Load Voltage', '${data.loadVoltageV.toStringAsFixed(1)} V'),
      _MetricItem('Load Power', '${data.loadPowerW} W'),
      _MetricItem('Start Batt 1', '${data.startingBatteryVoltageV.toStringAsFixed(1)} V'),
      _MetricItem('Start Batt 2', '${data.startingBatteryVoltage2V.toStringAsFixed(1)} V'),
      _MetricItem('Charge Capacity', '${data.chargeCapacity.toStringAsFixed(0)} AH'),
      _MetricItem('Charge Energy', '${data.chargeEnergy.toStringAsFixed(0)} WH'),
      _MetricItem('Asst Capacity', '${data.assistantChargeCapacity.toStringAsFixed(0)} AH'),
      _MetricItem('Asst Energy', '${data.assistantChargeEnergy.toStringAsFixed(0)} WH'),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.25,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final _MetricItem item = items[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  item.label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  item.value,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FlagCard extends StatelessWidget {
  const _FlagCard({required this.data});

  final RealtimeData data;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _flag('Charge', data.chargeState),
            _flag('Assistant Charge', data.assistantChargeState),
            _flag('Full Charge', data.fullCharge),
            _flag('Over Temp', data.overTemp),
            _flag('Battery Over-Voltage', data.batteryOverPressure),
            _flag('PV Over-Voltage', data.pvOverPressure),
            _flag('Battery Under-Voltage', data.batteryUnderVoltage),
          ],
        ),
      ),
    );
  }

  Widget _flag(String label, bool value) {
    return Chip(
      avatar: Icon(
        value ? Icons.check_circle : Icons.cancel,
        size: 18,
        color: value ? Colors.green : Colors.red,
      ),
      label: Text(label),
    );
  }
}

class _MetricItem {
  const _MetricItem(this.label, this.value);

  final String label;
  final String value;
}
