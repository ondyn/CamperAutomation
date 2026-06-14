/// OBD-II protocol layer: PID definitions, response parsing, DTC parsing.
/// Targets standard SAE J1979 (OBD-II) mode 01 / mode 03 / mode 04.
/// Responses assumed to have headers OFF (ATH0) and spaces OFF (ATS0).

// ── Error sentinel values returned by ELM327 ──────────────────────────────

const Set<String> _elmErrors = {
  'NODATA',
  'UNABLETOCONNECT',
  'BUSBUSY',
  'BUSERROR',
  'CANERROR',
  'STOPPED',
  'ERROR',
  'SEARCHING',
};

// ── OBD-II PID constants (service 01) ────────────────────────────────────

class ObdPid {
  const ObdPid._();
  static const int monitorStatus = 0x01;    // MIL + DTC count
  static const int coolantTemp   = 0x05;    // °C = A − 40
  static const int engineRpm     = 0x0C;    // rpm = (A×256+B) / 4
  static const int vehicleSpeed  = 0x0D;    // km/h = A
  static const int intakeAirTemp = 0x0F;    // °C = A − 40
  static const int mafRate       = 0x10;    // g/s = (A×256+B) / 100
  static const int throttlePos   = 0x11;    // % = A × 100/255
  static const int runTime       = 0x1F;    // s = A×256+B
  static const int fuelTankLevel = 0x2F;    // % = A × 100/255
  static const int oilTemp       = 0x5C;    // °C = A − 40
}

// ── Data models ───────────────────────────────────────────────────────────

/// Snapshot of all OBD live-data and DTC information.
class OBDData {
  const OBDData({
    this.engineRpm,
    this.vehicleSpeedKmh,
    this.coolantTempC,
    this.oilTempC,
    this.fuelLevelPct,
    this.throttlePosPct,
    this.intakeAirTempC,
    this.mafGs,
    this.runTimeS,
    this.milOn,
    this.dtcCount,
    this.dtcs = const <String>[],
  });

  final double?       engineRpm;
  final int?          vehicleSpeedKmh;
  final double?       coolantTempC;
  final double?       oilTempC;
  final double?       fuelLevelPct;
  final double?       throttlePosPct;
  final double?       intakeAirTempC;
  final double?       mafGs;
  final int?          runTimeS;
  final bool?         milOn;
  final int?          dtcCount;
  final List<String>  dtcs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'engine_rpm':         engineRpm,
        'vehicle_speed_kmh':  vehicleSpeedKmh,
        'coolant_temp_c':     coolantTempC,
        'oil_temp_c':         oilTempC,
        'fuel_level_pct':     fuelLevelPct,
        'throttle_pos_pct':   throttlePosPct,
        'intake_air_temp_c':  intakeAirTempC,
        'maf_g_s':            mafGs,
        'run_time_s':         runTimeS,
        'mil_on':             milOn,
        'dtc_count':          dtcCount,
        'dtcs':               dtcs,
      };
}

enum OBDConnectionState { disconnected, connecting, connected }

/// Full application state snapshot, JSON-serialisable for the REST API.
class OBDState {
  const OBDState({
    this.connection = OBDConnectionState.disconnected,
    this.deviceName,
    this.deviceAddress,
    this.elmVersion,
    this.protocolDesc,
    this.data,
    this.lastUpdateMs,
  });

  final OBDConnectionState connection;
  final String?   deviceName;
  final String?   deviceAddress;
  final String?   elmVersion;
  final String?   protocolDesc;
  final OBDData?  data;
  final int?      lastUpdateMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'connection':    connection.name,
        'device_name':   deviceName,
        'device_address': deviceAddress,
        'elm_version':   elmVersion,
        'protocol_desc': protocolDesc,
        'last_update_ms': lastUpdateMs,
        'data':          data?.toJson(),
      };
}

// ── Response parsing helpers ──────────────────────────────────────────────

/// Parse an ELM327 mode-01 response (ATH0 + ATS0).
/// Expected raw form: "410C1AF8" (service 0x41, PID, data bytes)
/// Returns data bytes after [service+0x40, pid], or null on invalid/error.
List<int>? parseMode01(String raw, int pid) {
  final clean = raw.replaceAll(RegExp(r'\s'), '').toUpperCase();
  if (_elmErrors.contains(clean)) return null;

  // Strip any leading line content (multi-line responses: take last non-empty)
  final line = clean.split(RegExp(r'[\r\n]+')).lastWhere(
    (s) => s.isNotEmpty,
    orElse: () => clean,
  );

  // Must start with expected service byte (0x41 for mode 01)
  final expectedSvc = (0x41).toRadixString(16).padLeft(2, '0').toUpperCase();
  final expectedPid = pid.toRadixString(16).padLeft(2, '0').toUpperCase();

  if (line.length < 4) return null;
  if (!line.startsWith('$expectedSvc$expectedPid')) return null;

  // Remaining bytes are the data
  final dataHex = line.substring(4);
  if (dataHex.length % 2 != 0) return null;
  return <int>[
    for (int i = 0; i < dataHex.length; i += 2)
      int.parse(dataHex.substring(i, i + 2), radix: 16),
  ];
}

/// Parse engine RPM from mode-01 PID 0x0C response.
/// Formula: (A×256 + B) / 4
double? parseRpm(String raw) {
  final bytes = parseMode01(raw, ObdPid.engineRpm);
  if (bytes == null || bytes.length < 2) return null;
  return (bytes[0] * 256 + bytes[1]) / 4.0;
}

/// Parse vehicle speed (km/h) from mode-01 PID 0x0D.
int? parseSpeed(String raw) {
  final bytes = parseMode01(raw, ObdPid.vehicleSpeed);
  if (bytes == null || bytes.isEmpty) return null;
  return bytes[0];
}

/// Parse a temperature PID (0x05 coolant / 0x0F intake / 0x5C oil).
/// Formula: A − 40
double? parseTemp(String raw, int pid) {
  final bytes = parseMode01(raw, pid);
  if (bytes == null || bytes.isEmpty) return null;
  return (bytes[0] - 40).toDouble();
}

/// Parse fuel tank level (PID 0x2F) or throttle position (PID 0x11).
/// Formula: A × 100/255
double? parsePercent(String raw, int pid) {
  final bytes = parseMode01(raw, pid);
  if (bytes == null || bytes.isEmpty) return null;
  return bytes[0] * 100.0 / 255.0;
}

/// Parse MAF air flow rate (PID 0x10).
/// Formula: (A×256+B) / 100 g/s
double? parseMaf(String raw) {
  final bytes = parseMode01(raw, ObdPid.mafRate);
  if (bytes == null || bytes.length < 2) return null;
  return (bytes[0] * 256 + bytes[1]) / 100.0;
}

/// Parse engine run time (PID 0x1F).
/// Formula: A×256+B seconds
int? parseRunTime(String raw) {
  final bytes = parseMode01(raw, ObdPid.runTime);
  if (bytes == null || bytes.length < 2) return null;
  return bytes[0] * 256 + bytes[1];
}

/// Parse MIL status and DTC count from PID 0x01 response.
/// Byte A: bit7 = MIL on, bits 0-6 = DTC count
({bool milOn, int dtcCount})? parseMonitorStatus(String raw) {
  final bytes = parseMode01(raw, ObdPid.monitorStatus);
  if (bytes == null || bytes.isEmpty) return null;
  return (milOn: (bytes[0] & 0x80) != 0, dtcCount: bytes[0] & 0x7F);
}

/// Parse DTC list from mode-03 response (ATH0 + ATS0).
/// Format: "4301C000000000" (service 0x43, then pairs of DTC bytes)
/// Returns list of standard 5-char DTC codes like "P0171", "U0001".
List<String> parseDtcs(String raw) {
  final clean = raw.replaceAll(RegExp(r'\s'), '').toUpperCase();
  if (_elmErrors.contains(clean)) return const <String>[];

  final dtcs = <String>[];
  // Handle multi-line response (multiple 0x43 frames)
  for (final line in clean.split(RegExp(r'[\r\n]+'))) {
    if (!line.startsWith('43')) continue;
    final payload = line.substring(2);
    // Each DTC is 2 bytes
    for (int i = 0; i + 3 < payload.length; i += 4) {
      final highHex = payload.substring(i, i + 2);
      final lowHex  = payload.substring(i + 2, i + 4);
      final high    = int.tryParse(highHex, radix: 16) ?? 0;
      final low     = int.tryParse(lowHex, radix: 16) ?? 0;
      if (high == 0 && low == 0) continue; // padding / no DTC

      // Upper 2 bits of high byte encode category
      const prefixes = ['P', 'C', 'B', 'U'];
      final prefix = prefixes[(high >> 6) & 0x03];
      final code = ((high & 0x3F) << 8) | low;
      dtcs.add('$prefix${code.toRadixString(16).padLeft(4, '0').toUpperCase()}');
    }
  }
  return dtcs;
}
