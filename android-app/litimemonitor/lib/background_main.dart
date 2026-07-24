import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'battery_service.dart';
import 'rest_server.dart';

@pragma('vm:entry-point')
void backgroundMain(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  final LiTimeBatteryService battery = LiTimeBatteryService();
  final LiTimeRestServer httpServer = LiTimeRestServer(battery);
  await httpServer.start();

  battery.stateStream.listen((BatteryState state) {
    service.invoke('state_update', state.toJson());
  });
  final Timer stateTimer = Timer.periodic(const Duration(seconds: 3), (_) {
    service.invoke('state_update', battery.state.toJson());
  });

  service.on('set_device').listen((Map<String, dynamic>? data) {
    final String? remoteId = data?['remote_id'] as String?;
    final String? name = data?['name'] as String?;
    if (remoteId != null && remoteId.isNotEmpty) {
      battery.setTargetDevice(remoteId, name: name);
    }
  });

  service.on('stop_service').listen((_) async {
    stateTimer.cancel();
    await battery.stop();
    await httpServer.stop();
    await service.stopSelf();
  });
}
