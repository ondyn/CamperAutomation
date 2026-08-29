import 'package:shared_preferences/shared_preferences.dart';

class SavedLiTimeDevice {
  const SavedLiTimeDevice({required this.remoteId, this.name});

  final String remoteId;
  final String? name;
}

class LiTimeDevicePreferences {
  static const String _remoteIdKey = 'selected_remote_id';
  static const String _nameKey = 'selected_device_name';

  static Future<SavedLiTimeDevice?> load() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? remoteId = preferences.getString(_remoteIdKey);
    if (remoteId == null || remoteId.isEmpty) {
      return null;
    }
    return SavedLiTimeDevice(
      remoteId: remoteId,
      name: preferences.getString(_nameKey),
    );
  }

  static Future<void> save(String remoteId, {String? name}) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(_remoteIdKey, remoteId);
    if (name == null || name.isEmpty) {
      await preferences.remove(_nameKey);
    } else {
      await preferences.setString(_nameKey, name);
    }
  }

  static Future<void> clear() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove(_remoteIdKey);
    await preferences.remove(_nameKey);
  }
}