import 'package:shared_preferences/shared_preferences.dart';

class SavedChargerDevice {
  const SavedChargerDevice({required this.mac, this.name});

  final String mac;
  final String? name;
}

class ChargerDevicePreferences {
  static const String _macKey = 'selected_mac';
  static const String _nameKey = 'selected_device_name';

  static Future<SavedChargerDevice?> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? mac = preferences.getString(_macKey);
    if (mac == null || mac.isEmpty) {
      return null;
    }
    return SavedChargerDevice(mac: mac, name: preferences.getString(_nameKey));
  }

  static Future<void> save(String mac, {String? name}) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(_macKey, mac);
    if (name == null || name.isEmpty) {
      await preferences.remove(_nameKey);
    } else {
      await preferences.setString(_nameKey, name);
    }
  }

  static Future<void> clear() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove(_macKey);
    await preferences.remove(_nameKey);
  }
}