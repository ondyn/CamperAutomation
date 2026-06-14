import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'obd_service.dart';
import 'rest_server.dart';

/// Entry point for the Android foreground service.
/// Runs in its own Flutter engine context (separate isolate).
@pragma('vm:entry-point')
void backgroundMain(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  final OBDService obd = OBDService();
  final OBDRestServer httpServer = OBDRestServer(obd);

  await httpServer.start();

  // Push state updates to the UI isolate.
  obd.stateStream.listen((state) {
    service.invoke('state_update', state.toJson());
  });

  // Periodic push so the UI always receives fresh data.
  Timer.periodic(const Duration(seconds: 2), (_) {
    service.invoke('state_update', obd.state.toJson());
  });

  // UI sends the selected BT device MAC + optional name.
  service.on('set_device').listen((Map<String, dynamic>? data) {
    final String? mac  = data?['mac']  as String?;
    final String? name = data?['name'] as String?;
    if (mac != null && mac.isNotEmpty) {
      obd.setTargetDevice(mac, name: name);
    }
  });

  // UI requests DTC clear.
  service.on('clear_dtcs').listen((_) => obd.clearDtcs());

  // Graceful stop.
  service.on('stop_service').listen((_) async {
    await obd.stop();
    await httpServer.stop();
    await service.stopSelf();
  });
}
