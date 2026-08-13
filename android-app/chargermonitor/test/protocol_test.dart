import 'package:chargermonitor/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RealtimeData alarm flags', () {
    test('are clear for the live normal charging status', () {
      final RealtimeData data = RealtimeData.fromFrame(_frameWithStatus(0x50));

      expect(data.chargeState, isTrue);
      expect(data.fullCharge, isTrue);
      expect(data.overTemp, isFalse);
      expect(data.batteryOverPressure, isFalse);
      expect(data.pvOverPressure, isFalse);
      expect(data.batteryUnderVoltage, isFalse);
    });

    test('are set when the charger alarm bits are set', () {
      final RealtimeData data = RealtimeData.fromFrame(_frameWithStatus(0x5F));

      expect(data.overTemp, isTrue);
      expect(data.batteryOverPressure, isTrue);
      expect(data.pvOverPressure, isTrue);
      expect(data.batteryUnderVoltage, isTrue);
    });
  });
}

List<int> _frameWithStatus(int status) {
  final List<int> frame = List<int>.filled(40, 0);
  frame[0] = 0xFF;
  frame[1] = 0xE2;
  frame[21] = status;
  return frame;
}