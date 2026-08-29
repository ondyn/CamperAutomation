import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'charger_service.dart';
import 'device_preferences.dart';
import 'rest_server.dart';

/// Entry point for the Android foreground service.
/// Runs in its own Flutter engine context inside BackgroundService.
@pragma('vm:entry-point')
void backgroundMain(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  final ChargerService charger = ChargerService();
  final ChargerRestServer httpServer = ChargerRestServer(charger);

  await httpServer.start();

  // Forward every state change to the UI isolate.
  charger.stateStream.listen((ChargerState state) {
    service.invoke('state_update', state.toJson());
  });

  // Periodic push so the UI always has fresh data (covers missed stream events).
  Timer.periodic(const Duration(seconds: 3), (_) {
    service.invoke('state_update', charger.state.toJson());
  });

  final SavedChargerDevice? savedDevice = await ChargerDevicePreferences.load();
  if (savedDevice != null) {
    charger.setTargetDevice(savedDevice.mac);
  }

  // Handle device selection sent from the UI.
  service.on('set_device').listen((Map<String, dynamic>? data) async {
    final String? mac = data?['mac'] as String?;
    final String? name = data?['name'] as String?;
    if (mac != null && mac.isNotEmpty) {
      await ChargerDevicePreferences.save(mac, name: name);
      charger.setTargetDevice(mac);
    }
  });

  service.on('disconnect_device').listen((_) async {
    await ChargerDevicePreferences.clear();
    await charger.disconnect();
  });

  // Handle graceful stop.
  service.on('stop_service').listen((_) async {
    await charger.stop();
    await httpServer.stop();
    await service.stopSelf();
  });
}
