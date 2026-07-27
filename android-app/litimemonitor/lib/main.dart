import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'background_main.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureBackgroundService();
  runApp(const LiTimeMonitorApp());
}

Future<void> _configureBackgroundService() async {
  final FlutterBackgroundService service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundMain,
      autoStart: false,
      isForegroundMode: true,
      initialNotificationTitle: 'LiTimeMonitor',
      initialNotificationContent: 'Battery bridge running',
      foregroundServiceNotificationId: 889,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
  await service.startService();
}

class LiTimeMonitorApp extends StatelessWidget {
  const LiTimeMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiTimeMonitor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
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
  static final Guid _liTimeServiceUuid = Guid(
    'F000FFC0-0451-4000-B000-000000000000',
  );

  final Map<String, ScanResult> _results = <String, ScanResult>{};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  bool _scanning = false;
  String? _issue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestAndScan());
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _requestAndScan() async {
    if (Platform.isAndroid) {
      final Map<Permission, PermissionStatus> statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.notification,
      ].request();
      if (!(statuses[Permission.bluetoothScan]?.isGranted ?? false) ||
          !(statuses[Permission.bluetoothConnect]?.isGranted ?? false)) {
        if (mounted) {
          setState(() => _issue = 'Nearby devices permission is required.');
        }
        return;
      }
    }
    await _scan();
  }

  Future<void> _scan() async {
    if (!await FlutterBluePlus.isSupported) {
      setState(() => _issue = 'Bluetooth LE is not supported.');
      return;
    }
    if (Platform.isAndroid &&
        await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }

    await _scanSubscription?.cancel();
    _results.clear();
    setState(() {
      _scanning = true;
      _issue = null;
    });
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      (List<ScanResult> results) {
        for (final ScanResult result in results) {
          final String remoteId = result.device.remoteId.str;
          if (!_results.containsKey(remoteId)) {
            final AdvertisementData advertisement = result.advertisementData;
            debugPrint(
              '[LiTimeMonitor] Advertisement $remoteId: '
              'name=${_name(result)}, rssi=${result.rssi}, '
              'services=${advertisement.serviceUuids.join(',')}, '
              'manufacturerIds=${advertisement.manufacturerData.keys.join(',')}, '
              'serviceData=${advertisement.serviceData.keys.join(',')}',
            );
          }
          _results[remoteId] = result;
        }
        if (mounted) {
          setState(() {});
        }
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => _issue = 'Scan failed: $error');
        }
      },
    );

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: false,
        androidCheckLocationServices: false,
      );
      await FlutterBluePlus.isScanning.where((bool value) => !value).first;
    } catch (error) {
      _issue = 'Unable to scan: $error';
    }
    if (mounted) {
      setState(() => _scanning = false);
    }
  }

  String _name(ScanResult result) {
    final String advertised = result.advertisementData.advName.trim();
    if (advertised.isNotEmpty) {
      return advertised;
    }
    final String platform = result.device.platformName.trim();
    return platform.isEmpty ? 'Unnamed BLE device' : platform;
  }

  bool _preferred(ScanResult result) {
    final String name = _name(result).toUpperCase();
    return name.contains('LITIME') ||
        name.contains('TIMEUSB') ||
        result.advertisementData.serviceUuids.contains(_liTimeServiceUuid);
  }

  String _details(ScanResult result) {
    final AdvertisementData advertisement = result.advertisementData;
    final List<String> details = <String>[result.device.remoteId.str];
    if (advertisement.serviceUuids.isNotEmpty) {
      details.add('Services: ${advertisement.serviceUuids.join(', ')}');
    }
    if (advertisement.manufacturerData.isNotEmpty) {
      details.add(
        'Manufacturer IDs: ${advertisement.manufacturerData.keys.join(', ')}',
      );
    }
    return details.join('\n');
  }

  Future<void> _selectDevice(ScanResult result, String name) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    debugPrint(
      '[LiTimeMonitor] Selected $name (${result.device.remoteId.str}), '
      'services=${result.advertisementData.serviceUuids.join(',')}',
    );
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BatteryDashboardPage(
          remoteId: result.device.remoteId.str,
          deviceName: name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<ScanResult> devices = _results.values.toList()
      ..sort((ScanResult left, ScanResult right) {
        final int preferred =
            (_preferred(right) ? 1 : 0) - (_preferred(left) ? 1 : 0);
        return preferred != 0 ? preferred : right.rssi.compareTo(left.rssi);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('LiTimeMonitor'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Scan again',
            onPressed: _scanning ? null : _requestAndScan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: devices.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _issue ??
                      (_scanning
                          ? 'Scanning for LiTime batteries...'
                          : 'No Bluetooth devices found.'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final ScanResult result = devices[index];
                final String name = _name(result);
                return ListTile(
                  leading: Icon(
                    _preferred(result)
                        ? Icons.battery_charging_full
                        : Icons.bluetooth,
                  ),
                  title: Text(name),
                  subtitle: Text(_details(result)),
                  isThreeLine:
                      result.advertisementData.serviceUuids.isNotEmpty ||
                      result.advertisementData.manufacturerData.isNotEmpty,
                  trailing: Text('${result.rssi} dBm'),
                  onTap: () => _selectDevice(result, name),
                );
              },
            ),
    );
  }
}

class BatteryDashboardPage extends StatefulWidget {
  const BatteryDashboardPage({
    super.key,
    required this.remoteId,
    required this.deviceName,
  });

  final String remoteId;
  final String deviceName;

  @override
  State<BatteryDashboardPage> createState() => _BatteryDashboardPageState();
}

class _BatteryDashboardPageState extends State<BatteryDashboardPage> {
  StreamSubscription<Map<String, dynamic>?>? _stateSubscription;
  StreamSubscription<Map<String, dynamic>?>? _shutdownSubscription;
  Map<String, dynamic> _state = <String, dynamic>{'connection': 'connecting'};
  bool _shuttingDown = false;

  @override
  void initState() {
    super.initState();
    final FlutterBackgroundService service = FlutterBackgroundService();
    service.invoke('set_device', <String, dynamic>{
      'remote_id': widget.remoteId,
      'name': widget.deviceName,
    });
    _stateSubscription = service.on('state_update').listen((
      Map<String, dynamic>? state,
    ) {
      if (mounted && state != null) {
        setState(() => _state = state);
      }
    });
    _shutdownSubscription = service.on('shutdown_result').listen((
      Map<String, dynamic>? result,
    ) {
      if (!mounted || result == null) {
        return;
      }
      setState(() => _shuttingDown = false);
      final bool success = result['success'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Battery powered off. Connect a charger to power it on.'
                : (result['error'] as String? ?? 'Battery power off failed.'),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _shutdownSubscription?.cancel();
    super.dispose();
  }

  Future<void> _confirmShutdown() async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Power off battery?'),
            content: const Text(
              'Disconnect all chargers first. Powering off immediately stops '
              'the battery and Bluetooth. A charger is required to power it '
              'back on.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Power off'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _shuttingDown = true);
    FlutterBackgroundService().invoke('shutdown_battery');
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? data = _state['data'] as Map<String, dynamic>?;
    final String connection = _state['connection'] as String? ?? 'disconnected';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: <Widget>[
          IconButton(
            tooltip: 'Power off battery',
            onPressed: connection == 'connected' && !_shuttingDown
                ? _confirmShutdown
                : null,
            icon: _shuttingDown
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.power_settings_new),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                connection == 'connected'
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_searching,
              ),
              const SizedBox(width: 10),
              Text(
                connection.toUpperCase(),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (data == null)
            const Text('Waiting for battery telemetry...')
          else ...<Widget>[
            _MetricStrip(data: data),
            const SizedBox(height: 20),
            Text(
              'Cell voltages',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _ValueGrid(
              values: (data['cell_voltages_v'] as List<dynamic>? ?? <dynamic>[])
                  .cast<num>(),
              suffix: 'V',
              decimals: 3,
            ),
            const SizedBox(height: 20),
            Text(
              'Temperatures',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _ValueGrid(
              values: (data['temperatures_c'] as List<dynamic>? ?? <dynamic>[])
                  .cast<num>(),
              suffix: '°C',
              decimals: 0,
            ),
            const SizedBox(height: 20),
            _DetailsSection(
              title: 'Cell health',
              values: <(String, String)>[
                ('Active cells', '${data['cell_count']}'),
                ('Minimum', _number(data, 'minimum_cell_voltage_v', 'V', 3)),
                ('Maximum', _number(data, 'maximum_cell_voltage_v', 'V', 3)),
                ('Delta', _number(data, 'cell_voltage_delta_v', 'V', 3)),
              ],
            ),
            const SizedBox(height: 20),
            _DetailsSection(
              title: 'Balance',
              values: <(String, String)>[
                (
                  'Status',
                  data['balancing_active'] == true ? 'Active' : 'Idle',
                ),
                ('Cells', _integerList(data['balancing_cells'])),
                ('Raw mask', _hex(data['balance_status'])),
              ],
            ),
            const SizedBox(height: 20),
            _DetailsSection(
              title: 'Capacity',
              values: <(String, String)>[
                ('Remaining', _number(data, 'remaining_capacity_ah', 'Ah', 2)),
                (
                  'Full charge',
                  _number(data, 'full_charge_capacity_ah', 'Ah', 2),
                ),
                ('Rated', _number(data, 'rated_capacity_ah', 'Ah', 2)),
                ('Discharge cycles', '${data['discharge_cycles']}'),
                (
                  'Total discharge raw',
                  '${data['total_discharge_capacity_raw']}',
                ),
              ],
            ),
            const SizedBox(height: 20),
            _DetailsSection(
              title: 'Diagnostics',
              values: <(String, String)>[
                ('Battery status', _hex(data['battery_status'])),
                ('Alarm status', _hex(data['alarm_status'])),
                ('Protection status', _hex(data['protection_status'])),
                ('Fault status', _hex(data['fault_status'])),
                ('Other information', _hex(data['other_information'])),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final List<(String, String)> metrics = <(String, String)>[
      ('Battery', '${(data['battery_voltage_v'] as num).toStringAsFixed(2)} V'),
      ('Output', '${(data['output_voltage_v'] as num).toStringAsFixed(2)} V'),
      ('Current', '${(data['current_a'] as num).toStringAsFixed(2)} A'),
      ('Power', '${(data['power_w'] as num).toStringAsFixed(1)} W'),
      ('Charge', '${data['soc_percent']}%'),
      ('Health', '${data['soh_percent']}%'),
      ('Cycles', '${data['discharge_cycles']}'),
    ];
    return Wrap(
      spacing: 20,
      runSpacing: 16,
      children: metrics
          .map(
            ((String, String) metric) => SizedBox(
              width: 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    metric.$1,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  Text(
                    metric.$2,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class _DetailsSection extends StatelessWidget {
  const _DetailsSection({required this.title, required this.values});

  final String title;
  final List<(String, String)> values;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        for (final (String, String) value in values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(value.$1)),
                Text(value.$2, style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
      ],
    );
  }
}

String _number(
  Map<String, dynamic> data,
  String key,
  String suffix,
  int decimals,
) {
  final Object? value = data[key];
  return value is num ? '${value.toStringAsFixed(decimals)} $suffix' : 'N/A';
}

String _integerList(Object? value) {
  if (value is! List<dynamic> || value.isEmpty) {
    return 'None';
  }
  return value.join(', ');
}

String _hex(Object? value) {
  return value is int
      ? '0x${value.toRadixString(16).toUpperCase().padLeft(2, '0')}'
      : 'N/A';
}

class _ValueGrid extends StatelessWidget {
  const _ValueGrid({
    required this.values,
    required this.suffix,
    required this.decimals,
  });

  final List<num> values;
  final String suffix;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisExtent: 54,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: values.length,
      itemBuilder: (BuildContext context, int index) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text(
            '${index + 1}: ${values[index].toStringAsFixed(decimals)} $suffix',
          ),
        ),
      ),
    );
  }
}
