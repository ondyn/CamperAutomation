import 'dart:typed_data';

class LiTimeProtocol {
  static const int telemetryCommand = 0x13;
  static const int telemetryResponseCommand = 0x93;

  static List<int> requestTelemetry({int address = 0}) =>
      buildCommand(telemetryCommand, address: address);

  static List<int> buildCommand(
    int command, {
    int address = 0,
    List<int> data = const <int>[],
  }) {
    final int contentLength = data.length + 4;
    final List<int> frame = <int>[
      address & 0xFF,
      (contentLength >> 8) & 0xFF,
      contentLength & 0xFF,
      0x01,
      command & 0xFF,
      ...data.map((int value) => value & 0xFF),
      0x55,
      0xAA,
    ];
    frame.add(_checksum(frame));
    return frame;
  }

  static int _checksum(List<int> bytes) {
    int sum = 0;
    for (int index = 1; index < bytes.length; index++) {
      sum += bytes[index];
    }
    return sum & 0xFF;
  }
}

class LiTimeFrame {
  const LiTimeFrame(this.bytes);

  final List<int> bytes;

  int get command => bytes[8] & 0xFF;
  int get status => bytes[7] & 0xFF;
  List<int> get payload => bytes.sublist(9, bytes.length - 1);
}

class LiTimeFrameParser {
  static const int _minimumFrameLength = 10;
  static const int _maximumFrameLength = 4096;

  final List<int> _buffer = <int>[];

  Iterable<LiTimeFrame> appendAndExtract(List<int> chunk) sync* {
    _buffer.addAll(chunk.map((int value) => value & 0xFF));

    while (_buffer.length >= 4) {
      final int contentLength = (_buffer[2] << 8) | _buffer[3];
      final int frameLength = contentLength + 4;
      if (frameLength < _minimumFrameLength ||
          frameLength > _maximumFrameLength) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < frameLength) {
        return;
      }

      final List<int> candidate = _buffer.sublist(0, frameLength);
      if (_isValid(candidate)) {
        _buffer.removeRange(0, frameLength);
        yield LiTimeFrame(candidate);
      } else {
        _buffer.removeAt(0);
      }
    }
  }

  bool _isValid(List<int> frame) {
    if (frame.length < _minimumFrameLength || frame[0] == 0xFB) {
      return false;
    }
    if (frame[7] != 0x00) {
      return false;
    }

    int checksum = 0;
    for (int index = 1; index < frame.length - 1; index++) {
      checksum += frame[index];
    }
    return (checksum & 0xFF) == frame.last;
  }
}

class LiTimeTelemetry {
  const LiTimeTelemetry({
    required this.outputVoltageMv,
    required this.batteryVoltageMv,
    required this.currentMa,
    required this.cellVoltagesMv,
    required this.temperaturesDeciC,
    required this.remainingCapacityRaw,
    required this.fullChargeCapacityRaw,
    required this.ratedCapacityRaw,
    required this.socPercent,
    required this.sohPercent,
    required this.alarmStatus,
    required this.protectionStatus,
    required this.faultStatus,
    required this.balanceStatus,
    required this.batteryStatus,
    required this.dischargeCycles,
    required this.totalDischargeCapacityRaw,
    required this.extendedLayout,
  });

  final int outputVoltageMv;
  final int batteryVoltageMv;
  final int currentMa;
  final List<int> cellVoltagesMv;
  final List<int> temperaturesDeciC;
  final int remainingCapacityRaw;
  final int fullChargeCapacityRaw;
  final int ratedCapacityRaw;
  final int socPercent;
  final int sohPercent;
  final int alarmStatus;
  final int protectionStatus;
  final int faultStatus;
  final int balanceStatus;
  final int batteryStatus;
  final int dischargeCycles;
  final int totalDischargeCapacityRaw;
  final bool extendedLayout;

  double get outputVoltageV => outputVoltageMv / 1000.0;
  double get batteryVoltageV => batteryVoltageMv / 1000.0;
  double get currentA => currentMa / 1000.0;
  double get powerW => batteryVoltageV * currentA;
  List<double> get cellVoltagesV =>
      cellVoltagesMv.map((int value) => value / 1000.0).toList();
  List<double> get temperaturesC =>
      temperaturesDeciC.map((int value) => value / 10.0).toList();

  factory LiTimeTelemetry.fromFrame(LiTimeFrame frame) {
    if (frame.command != LiTimeProtocol.telemetryResponseCommand) {
      throw ArgumentError('Not a LiTime command 0x13 response');
    }
    return LiTimeTelemetry.fromPayload(frame.payload);
  }

  factory LiTimeTelemetry.fromPayload(List<int> payload) {
    final bool extended = payload.length == 0x132;
    final int cellCount = extended ? 32 : 16;
    final int currentOffset = extended ? 80 : 48;
    final int temperatureOffset = extended ? 84 : 52;
    final int temperatureCount = extended ? 13 : 5;
    final int capacityOffset = extended ? 110 : 62;
    final int minimumLength = extended ? 152 : 104;
    if (payload.length < minimumLength) {
      throw ArgumentError(
        'LiTime telemetry payload is too short: ${payload.length}',
      );
    }

    final ByteData data = ByteData.sublistView(Uint8List.fromList(payload));
    final List<int> cells = List<int>.generate(
      cellCount,
      (int index) => data.getUint16(16 + index * 2, Endian.little),
    );
    final List<int> temperatures = List<int>.generate(
      temperatureCount,
      (int index) =>
          data.getInt16(temperatureOffset + index * 2, Endian.little),
    );

    return LiTimeTelemetry(
      outputVoltageMv: data.getUint32(8, Endian.little),
      batteryVoltageMv: data.getUint32(12, Endian.little),
      currentMa: data.getInt32(currentOffset, Endian.little),
      cellVoltagesMv: List<int>.unmodifiable(cells),
      temperaturesDeciC: List<int>.unmodifiable(temperatures),
      remainingCapacityRaw: data.getUint16(capacityOffset, Endian.little),
      fullChargeCapacityRaw: data.getUint16(capacityOffset + 2, Endian.little),
      ratedCapacityRaw: data.getUint16(capacityOffset + 4, Endian.little),
      alarmStatus: data.getUint32(capacityOffset + 10, Endian.little),
      protectionStatus: data.getUint32(capacityOffset + 14, Endian.little),
      faultStatus: data.getUint32(capacityOffset + 18, Endian.little),
      balanceStatus: data.getUint32(capacityOffset + 22, Endian.little),
      batteryStatus: data.getUint16(capacityOffset + 26, Endian.little),
      socPercent: data.getUint16(capacityOffset + 28, Endian.little),
      sohPercent: data.getUint32(capacityOffset + 30, Endian.little),
      dischargeCycles: data.getUint32(capacityOffset + 34, Endian.little),
      totalDischargeCapacityRaw:
          data.getUint32(capacityOffset + 38, Endian.little),
      extendedLayout: extended,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'output_voltage_v': outputVoltageV,
        'battery_voltage_v': batteryVoltageV,
        'current_a': currentA,
        'power_w': powerW,
        'soc_percent': socPercent,
        'soh_percent': sohPercent,
        'cell_voltages_v': cellVoltagesV,
        'temperatures_c': temperaturesC,
        'remaining_capacity_raw': remainingCapacityRaw,
        'full_charge_capacity_raw': fullChargeCapacityRaw,
        'rated_capacity_raw': ratedCapacityRaw,
        'discharge_cycles': dischargeCycles,
        'total_discharge_capacity_raw': totalDischargeCapacityRaw,
        'alarm_status': alarmStatus,
        'protection_status': protectionStatus,
        'fault_status': faultStatus,
        'balance_status': balanceStatus,
        'battery_status': batteryStatus,
        'extended_layout': extendedLayout,
      };
}
