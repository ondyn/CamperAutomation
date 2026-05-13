import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'background_main.dart';
import 'charger_service.dart';
import 'protocol.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureBackgroundService();
  runApp(const ChargerMonitorApp());
}

Future<void> _configureBackgroundService() async {
  final FlutterBackgroundService bgService = FlutterBackgroundService();
  await bgService.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundMain,
      autoStart: false,
      isForegroundMode: true,
      // No custom notificationChannelId → plugin creates FOREGROUND_DEFAULT channel automatically
      initialNotificationTitle: 'Charger Monitor',
      initialNotificationContent: 'Running',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
  await bgService.startService();
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
                        builder: (_) => DeviceDashboardPage(
                          deviceMac: device.remoteId.str,
                          deviceName: name,
                        ),
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
  const DeviceDashboardPage({
    super.key,
    required this.deviceMac,
    required this.deviceName,
  });

  final String deviceMac;
  final String deviceName;

  @override
  State<DeviceDashboardPage> createState() => _DeviceDashboardPageState();
}

class _DeviceDashboardPageState extends State<DeviceDashboardPage> {
  StreamSubscription<Map<String, dynamic>?>? _stateSub;
  String _connectionState = 'Connecting…';
  int? _deviceTypeCode;
  String? _deviceTypeName;
  RealtimeData? _realtime;
  int _rxFrames = 0;
  int _rxBytes = 0;

  @override
  void initState() {
    super.initState();
    // Tell background service which device to connect to.
    FlutterBackgroundService().invoke('set_device', <String, dynamic>{
      'mac': widget.deviceMac,
    });
    // Listen for state updates from the background service.
    _stateSub = FlutterBackgroundService()
        .on('state_update')
        .listen((Map<String, dynamic>? data) {
      if (data == null || !mounted) return;
      _applyState(data);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  void _applyState(Map<String, dynamic> data) {
    final String conn = data['connection'] as String? ?? 'disconnected';
    final String? dt = data['device_type'] as String?;
    final int? dtCode = (data['device_type_code'] as num?)?.toInt();
    final Map<String, dynamic>? rawData =
        data['data'] as Map<String, dynamic>?;
    final Map<String, dynamic>? rawFlags =
        data['flags'] as Map<String, dynamic>?;

    RealtimeData? rd;
    if (rawData != null && rawFlags != null) {
      try {
        rd = RealtimeData(
          batteryCurrentA:
              (rawData['battery_current_a'] as num).toDouble(),
          batteryVoltageV:
              (rawData['battery_voltage_v'] as num).toDouble(),
          assistantBatteryCurrentA:
              (rawData['assistant_battery_current_a'] as num).toDouble(),
          assistantBatteryVoltageV:
              (rawData['assistant_battery_voltage_v'] as num).toDouble(),
          solarPanelPowerW:
              (rawData['solar_panel_power_w'] as num).toInt(),
          solarPanelVoltageV:
              (rawData['solar_panel_voltage_v'] as num).toDouble(),
          loadCurrentA: (rawData['load_current_a'] as num).toDouble(),
          loadVoltageV: (rawData['load_voltage_v'] as num).toDouble(),
          loadPowerW: (rawData['load_power_w'] as num).toInt(),
          startingBatteryVoltageV:
              (rawData['starting_battery_voltage_v'] as num).toDouble(),
          startingBatteryVoltage2V:
              (rawData['starting_battery_voltage2_v'] as num).toDouble(),
          chargeState: rawFlags['charge_state'] as bool,
          assistantChargeState:
              rawFlags['assistant_charge_state'] as bool,
          fullCharge: rawFlags['full_charge'] as bool,
          overTemp: rawFlags['over_temp'] as bool,
          batteryOverPressure:
              rawFlags['battery_over_pressure'] as bool,
          pvOverPressure: rawFlags['pv_over_pressure'] as bool,
          batteryUnderVoltage:
              rawFlags['battery_under_voltage'] as bool,
          chargeCapacity:
              (rawData['charge_capacity_ah'] as num).toDouble(),
          chargeEnergy: (rawData['charge_energy_wh'] as num).toDouble(),
          assistantChargeCapacity:
              (rawData['assistant_charge_capacity_ah'] as num).toDouble(),
          assistantChargeEnergy:
              (rawData['assistant_charge_energy_wh'] as num).toDouble(),
        );
      } catch (_) {}
    }

    setState(() {
      _connectionState = switch (conn) {
        'connected' => 'Connected',
        'connecting' => 'Connecting…',
        _ => 'Disconnected',
      };
      _deviceTypeCode = dtCode;
      _deviceTypeName = dt;
      if (rd != null) {
        _realtime = rd;
        _rxFrames++;
        _rxBytes += 40;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final RealtimeData? d = _realtime;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              widget.deviceMac,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _StatusCard(
              connectionState: _connectionState,
              deviceType: _deviceTypeCode,
              deviceTypeName: _deviceTypeName,
              rxBytes: _rxBytes,
              rxFrames: _rxFrames,
            ),
            const SizedBox(height: 12),
            if (d == null)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Waiting for realtime protocol frames…'),
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
