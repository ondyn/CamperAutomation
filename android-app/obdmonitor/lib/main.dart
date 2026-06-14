import 'dart:async';
import 'dart:io';

import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';

import 'background_main.dart';
import 'obd_protocol.dart';
import 'obd_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureBackgroundService();
  runApp(const OBDMonitorApp());
}

Future<void> _configureBackgroundService() async {
  final FlutterBackgroundService svc = FlutterBackgroundService();
  await svc.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundMain,
      autoStart: false,
      isForegroundMode: true,
      initialNotificationTitle: 'OBD Monitor',
      initialNotificationContent: 'Waiting for device selection',
      foregroundServiceNotificationId: 889,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
  await svc.startService();
}

// ── App root ──────────────────────────────────────────────────────────────

class OBDMonitorApp extends StatelessWidget {
  const OBDMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OBD Monitor',
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// ── Home / device picker page ─────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final FlutterBackgroundService _bgService = FlutterBackgroundService();

  List<Device> _pairedDevices = <Device>[];
  String? _selectedMac;
  OBDState _obdState = const OBDState();
  StreamSubscription<Map<String, dynamic>?>? _stateSub;
  bool _loadingDevices = false;
  bool _permissionsGranted = false;
  bool _permissionsPermanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissionsAndLoad();
    _stateSub = _bgService.on('state_update').listen(_onStateUpdate);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stateSub?.cancel();
    super.dispose();
  }

  // Re-check permissions when user returns from the Android settings screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_permissionsGranted) {
      _requestPermissionsAndLoad();
    }
  }

  // ── Permissions ─────────────────────────────────────────────────────────

  Future<void> _requestPermissionsAndLoad() async {
    if (!Platform.isAndroid) {
      if (mounted) setState(() => _permissionsGranted = true);
      await _loadPairedDevices();
      return;
    }

    // On Android 12+ (API 31+), BLUETOOTH_CONNECT and BLUETOOTH_SCAN are the
    // runtime permissions. The legacy Permission.bluetooth is a normal
    // (install-time) permission and always returns 'denied' when requested at
    // runtime on Android 12+, so we must NOT include it in the check.
    final PermissionStatus connectStatus =
        await Permission.bluetoothConnect.request();
    final PermissionStatus scanStatus =
        await Permission.bluetoothScan.request();
    await Permission.notification.request();

    final bool granted = connectStatus.isGranted && scanStatus.isGranted;
    final bool permanentlyDenied =
        connectStatus.isPermanentlyDenied || scanStatus.isPermanentlyDenied;

    if (mounted) {
      setState(() {
        _permissionsGranted = granted;
        _permissionsPermanentlyDenied = permanentlyDenied;
      });
    }
    if (granted) {
      await _loadPairedDevices();
    }
  }

  Future<void> _loadPairedDevices() async {
    setState(() => _loadingDevices = true);
    try {
      final devices = await OBDService.pairedDevices();
      if (mounted) {
        setState(() => _pairedDevices = devices);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('BT error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  // ── State update from background service ─────────────────────────────────

  void _onStateUpdate(Map<String, dynamic>? data) {
    if (data == null || !mounted) return;
    final conn = data['connection'] as String? ?? 'disconnected';
    final obdData = data['data'] as Map<String, dynamic>?;
    List<String> dtcs = const <String>[];
    if (obdData != null && obdData['dtcs'] is List) {
      dtcs = List<String>.from(obdData['dtcs'] as List);
    }
    setState(() {
      _obdState = OBDState(
        connection: OBDConnectionState.values.firstWhere(
          (e) => e.name == conn,
          orElse: () => OBDConnectionState.disconnected,
        ),
        deviceName:   data['device_name']   as String?,
        deviceAddress: data['device_address'] as String?,
        elmVersion:   data['elm_version']   as String?,
        protocolDesc: data['protocol_desc'] as String?,
        lastUpdateMs: data['last_update_ms'] as int?,
        data: obdData == null
            ? null
            : OBDData(
                engineRpm:       (obdData['engine_rpm'] as num?)?.toDouble(),
                vehicleSpeedKmh: (obdData['vehicle_speed_kmh'] as num?)?.toInt(),
                coolantTempC:    (obdData['coolant_temp_c'] as num?)?.toDouble(),
                oilTempC:        (obdData['oil_temp_c'] as num?)?.toDouble(),
                fuelLevelPct:    (obdData['fuel_level_pct'] as num?)?.toDouble(),
                throttlePosPct:  (obdData['throttle_pos_pct'] as num?)?.toDouble(),
                intakeAirTempC:  (obdData['intake_air_temp_c'] as num?)?.toDouble(),
                mafGs:           (obdData['maf_g_s'] as num?)?.toDouble(),
                runTimeS:        (obdData['run_time_s'] as num?)?.toInt(),
                milOn:           obdData['mil_on'] as bool?,
                dtcCount:        (obdData['dtc_count'] as num?)?.toInt(),
                dtcs:            dtcs,
              ),
      );
    });
  }

  // ── Device selection ─────────────────────────────────────────────────────

  void _selectDevice(Device device) {
    setState(() => _selectedMac = device.address);
    _bgService.invoke('set_device', {
      'mac': device.address,
      'name': device.name ?? device.address,
    });
  }

  void _clearDtcs() {
    _bgService.invoke('clear_dtcs', {});
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBD Monitor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh paired devices',
            onPressed: _loadPairedDevices,
          ),
        ],
      ),
      body: !_permissionsGranted
          ? _buildPermissionPrompt()
          : Column(
              children: [
                _buildConnectionBanner(),
                _buildDevicePicker(),
                const Divider(height: 1),
                Expanded(child: _buildDashboard()),
              ],
            ),
    );
  }

  Widget _buildPermissionPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              _permissionsPermanentlyDenied
                  ? 'Bluetooth permission is permanently denied. Open Android Settings → Permissions and allow "Nearby devices".'
                  : 'Bluetooth permissions are required to connect to the ELM327 adapter.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_permissionsPermanentlyDenied)
              ElevatedButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('Open Settings'),
                onPressed: () => openAppSettings(),
              )
            else
              ElevatedButton(
                onPressed: _requestPermissionsAndLoad,
                child: const Text('Grant Permissions'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionBanner() {
    final Color color;
    final String label;
    final IconData icon;
    switch (_obdState.connection) {
      case OBDConnectionState.connected:
        color = Colors.green;
        label = 'Connected – ${_obdState.deviceName ?? ""}';
        icon = Icons.bluetooth_connected;
      case OBDConnectionState.connecting:
        color = Colors.orange;
        label = 'Connecting…';
        icon = Icons.bluetooth_searching;
      case OBDConnectionState.disconnected:
        color = Colors.grey;
        label = 'Disconnected';
        icon = Icons.bluetooth_disabled;
    }
    return Container(
      color: color.withOpacity(0.15),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ),
          if (_obdState.protocolDesc != null)
            Text(
              _obdState.protocolDesc!,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
        ],
      ),
    );
  }

  Widget _buildDevicePicker() {
    if (_loadingDevices) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Row(children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Loading paired devices…'),
        ]),
      );
    }
    if (_pairedDevices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'No paired Bluetooth devices found. Pair the ELM327 adapter in Android settings first.',
          style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Text('ELM327 adapter:'),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              hint: const Text('Select device'),
              value: _selectedMac,
              items: _pairedDevices.map((d) {
                return DropdownMenuItem<String>(
                  value: d.address,
                  child: Text(d.name ?? d.address, overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (mac) {
                if (mac == null) return;
                final device = _pairedDevices.firstWhere((d) => d.address == mac);
                _selectDevice(device);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    final data = _obdState.data;
    if (data == null) {
      return const Center(
        child: Text(
          'No OBD data yet.\nSelect an ELM327 adapter above and start the engine.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // MIL warning
        if (data.milOn == true)
          Card(
            color: Colors.red.shade50,
            child: ListTile(
              leading: const Icon(Icons.warning_amber, color: Colors.red),
              title: const Text('Check Engine Light (MIL) is ON',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              subtitle: Text('${data.dtcCount ?? 0} DTC(s) stored'),
            ),
          ),

        // Live data grid
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tile('Engine RPM', data.engineRpm?.toStringAsFixed(0), 'rpm', Icons.speed),
            _tile('Speed', data.vehicleSpeedKmh?.toString(), 'km/h', Icons.directions_car),
            _tile('Coolant', data.coolantTempC?.toStringAsFixed(1), '°C', Icons.thermostat),
            _tile('Oil Temp', data.oilTempC?.toStringAsFixed(1), '°C', Icons.oil_barrel),
            _tile('Fuel Level', data.fuelLevelPct?.toStringAsFixed(1), '%', Icons.local_gas_station),
            _tile('Throttle', data.throttlePosPct?.toStringAsFixed(1), '%', Icons.tune),
            _tile('Intake Air', data.intakeAirTempC?.toStringAsFixed(1), '°C', Icons.air),
            _tile('MAF', data.mafGs?.toStringAsFixed(2), 'g/s', Icons.waves),
            _tile('Run Time', _formatRunTime(data.runTimeS), '', Icons.timer),
          ],
        ),

        const SizedBox(height: 16),

        // DTCs
        Row(
          children: [
            Text(
              'Diagnostic Trouble Codes (${data.dtcs.length})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Clear DTCs'),
              onPressed: _clearDtcs,
            ),
          ],
        ),
        if (data.dtcs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No DTCs stored.', style: TextStyle(color: Colors.grey)),
          )
        else
          ...data.dtcs.map(
            (dtc) => ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline, color: Colors.orange, size: 20),
              title: Text(dtc, style: const TextStyle(fontFamily: 'monospace')),
            ),
          ),
      ],
    );
  }

  Widget _tile(String label, String? value, String unit, IconData icon) {
    return SizedBox(
      width: 160,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ]),
              const SizedBox(height: 4),
              Text(
                value != null ? '$value $unit' : '—',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatRunTime(int? seconds) {
    if (seconds == null) return '—';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}
