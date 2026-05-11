class ChargerProtocol {
  static const List<int> requestDeviceType = [0xFF, 0xE1, 0x01, 0xE2];
  static const List<int> requestBaseData = [0xFF, 0xE2, 0x02, 0xE4];
  static const List<int> requestHeartBeat = [0xFF, 0xC2, 0x02, 0xC4];
}

class ProtocolParser {
  final List<int> _buffer = <int>[];

  Iterable<List<int>> appendAndExtract(List<int> chunk) sync* {
    _buffer.addAll(chunk);

    while (true) {
      final int start = _buffer.indexOf(0xFF);
      if (start < 0) {
        _buffer.clear();
        return;
      }

      if (start > 0) {
        _buffer.removeRange(0, start);
      }

      if (_buffer.length < 3) {
        return;
      }

      final int command = _buffer[1];
      final int frameLength = _expectedLength(command);
      if (_buffer.length < frameLength) {
        return;
      }

      final List<int> frame = _buffer.sublist(0, frameLength);
      if (_isValid(frame)) {
        _buffer.removeRange(0, frameLength);
        yield frame;
      } else {
        // Resync conservatively to avoid losing subsequent valid frames.
        _buffer.removeAt(0);
      }
    }
  }

  int _expectedLength(int command) {
    if (command == 0xE1) {
      return 4;
    }
    if (command == 0xE2) {
      return 40;
    }
    return 20;
  }

  bool _isValid(List<int> frame) {
    int sum = 0;
    final int from = frame[1] == 0xE1 ? 1 : 2;
    for (int i = from; i < frame.length - 1; i++) {
      sum += _signedByte(frame[i]);
    }
    return _signedByte(sum) == _signedByte(frame.last);
  }

  int _signedByte(int value) {
    final int v = value & 0xFF;
    return v >= 128 ? v - 256 : v;
  }
}

class RealtimeData {
  const RealtimeData({
    required this.batteryCurrentA,
    required this.batteryVoltageV,
    required this.assistantBatteryCurrentA,
    required this.assistantBatteryVoltageV,
    required this.solarPanelPowerW,
    required this.solarPanelVoltageV,
    required this.loadCurrentA,
    required this.loadVoltageV,
    required this.loadPowerW,
    required this.startingBatteryVoltageV,
    required this.startingBatteryVoltage2V,
    required this.chargeState,
    required this.assistantChargeState,
    required this.fullCharge,
    required this.overTemp,
    required this.batteryOverPressure,
    required this.pvOverPressure,
    required this.batteryUnderVoltage,
    required this.chargeCapacity,
    required this.chargeEnergy,
    required this.assistantChargeCapacity,
    required this.assistantChargeEnergy,
  });

  final double batteryCurrentA;
  final double batteryVoltageV;
  final double assistantBatteryCurrentA;
  final double assistantBatteryVoltageV;
  final int solarPanelPowerW;
  final double solarPanelVoltageV;
  final double loadCurrentA;
  final double loadVoltageV;
  final int loadPowerW;
  final double startingBatteryVoltageV;
  final double startingBatteryVoltage2V;
  final bool chargeState;
  final bool assistantChargeState;
  final bool fullCharge;
  final bool overTemp;
  final bool batteryOverPressure;
  final bool pvOverPressure;
  final bool batteryUnderVoltage;
  final double chargeCapacity;
  final double chargeEnergy;
  final double assistantChargeCapacity;
  final double assistantChargeEnergy;

  factory RealtimeData.fromFrame(List<int> frame) {
    if (frame.length != 40 || frame[0] != 0xFF || frame[1] != 0xE2) {
      throw ArgumentError('Not a base realtime frame');
    }

    final int status = frame[21] & 0xFF;

    return RealtimeData(
      batteryCurrentA: _u16(frame[2], frame[3]) / 10.0,
      batteryVoltageV: _u16(frame[4], frame[5]) / 100.0,
      assistantBatteryCurrentA: _u16(frame[6], frame[7]) / 10.0,
      assistantBatteryVoltageV: _u16(frame[8], frame[9]) / 100.0,
      solarPanelPowerW: _u16(frame[10], frame[11]),
      solarPanelVoltageV: _u16(frame[12], frame[13]) / 10.0,
      loadCurrentA: _u16(frame[14], frame[15]) / 10.0,
      loadVoltageV: _u16(frame[16], frame[17]) / 10.0,
      loadPowerW: _u16(frame[18], frame[19]),
      startingBatteryVoltageV: (frame[20] & 0xFF) / 10.0,
      chargeState: _bit(status, 6),
      assistantChargeState: _bit(status, 5),
      fullCharge: _bit(status, 4),
      overTemp: !_bit(status, 3),
      batteryOverPressure: !_bit(status, 2),
      pvOverPressure: !_bit(status, 1),
      batteryUnderVoltage: !_bit(status, 0),
      chargeCapacity: _u24(frame[22], frame[23], frame[24]).toDouble(),
      chargeEnergy: _u24(frame[25], frame[26], frame[27]).toDouble(),
      assistantChargeCapacity: _u24(frame[28], frame[29], frame[30]).toDouble(),
      assistantChargeEnergy: _u24(frame[31], frame[32], frame[33]).toDouble(),
      startingBatteryVoltage2V: _u16(frame[34], frame[35]) / 10.0,
    );
  }

  static int _u16(int hi, int lo) => ((hi & 0xFF) << 8) | (lo & 0xFF);

  static int _u24(int b1, int b2, int b3) =>
      ((b1 & 0xFF) << 16) | ((b2 & 0xFF) << 8) | (b3 & 0xFF);

  static bool _bit(int byteValue, int index) => ((byteValue >> index) & 1) == 1;
}
