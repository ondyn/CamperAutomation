import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:litimemonitor/protocol.dart';

void main() {
  test('builds the recovered command 0x13 request', () {
    expect(LiTimeProtocol.requestTelemetry(), <int>[
      0x00,
      0x00,
      0x04,
      0x01,
      0x13,
      0x55,
      0xAA,
      0x17,
    ]);
  });

  test('builds the official command 0x60 shutdown request', () {
    expect(LiTimeProtocol.shutdown(), <int>[
      0x00,
      0x00,
      0x04,
      0x01,
      0x60,
      0x55,
      0xAA,
      0x64,
    ]);
  });

  test('builds the official discharge MOS requests', () {
    expect(LiTimeProtocol.setDischargeEnabled(true), <int>[
      0x00,
      0x00,
      0x04,
      0x01,
      0x0C,
      0x55,
      0xAA,
      0x10,
    ]);
    expect(LiTimeProtocol.setDischargeEnabled(false), <int>[
      0x00,
      0x00,
      0x04,
      0x01,
      0x0D,
      0x55,
      0xAA,
      0x11,
    ]);
  });

  test('reassembles and validates fragmented ordinary responses', () {
    final List<int> payload = _telemetryPayload();
    final List<int> response = _response(payload);
    final LiTimeFrameParser parser = LiTimeFrameParser();

    expect(parser.appendAndExtract(response.sublist(0, 17)), isEmpty);
    final List<LiTimeFrame> frames = parser
        .appendAndExtract(response.sublist(17))
        .toList();

    expect(frames, hasLength(1));
    expect(frames.single.command, 0x93);
    expect(frames.single.payload, payload);
  });

  test('rejects responses with an invalid checksum', () {
    final List<int> response = _response(_telemetryPayload());
    response[response.length - 1] ^= 0x01;

    expect(LiTimeFrameParser().appendAndExtract(response), isEmpty);
  });

  test('decodes command 0x13 V1 telemetry offsets', () {
    final List<int> payload = _telemetryPayload();
    final LiTimeTelemetry telemetry = LiTimeTelemetry.fromPayload(payload);

    expect(telemetry.batteryVoltageV, 13.24);
    expect(telemetry.currentA, -4.5);
    expect(telemetry.cellVoltagesMv.first, 3301);
    expect(telemetry.cellVoltagesMv.last, 3316);
    expect(telemetry.temperaturesC, <double>[21, 22, 23]);
    expect(telemetry.remainingCapacityAh, 7.3);
    expect(telemetry.balancingActive, isTrue);
    expect(telemetry.balancingCells, <int>[2, 3, 4]);
    expect(telemetry.dischargeEnabled, isTrue);
    payload[80] = 0x80;
    expect(LiTimeTelemetry.fromPayload(payload).dischargeEnabled, isFalse);
    expect(telemetry.cellVoltageDeltaV, closeTo(0.015, 0.000001));
    expect(telemetry.socPercent, 73);
    expect(telemetry.dischargeCycles, 42);
  });

  test('matches native app discharge estimate rounding', () {
    final Uint8List payload = Uint8List.fromList(_telemetryPayload());
    final ByteData data = ByteData.sublistView(payload);
    data.setInt32(40, -1049, Endian.little);
    data.setUint16(80, 2, Endian.little);
    final LiTimeTelemetry telemetry = LiTimeTelemetry.fromPayload(payload);

    expect(telemetry.estimatedHoursToEmpty, 7.3);
    expect(telemetry.estimatedHoursToFull, isNull);
    expect(telemetry.operatingState, 'discharging');
    expect(telemetry.toJson()['estimated_hours_to_empty'], 7.3);
    expect(telemetry.toJson()['operating_state'], 'discharging');
  });

  test('matches native app charge estimate rounding', () {
    final Uint8List payload = Uint8List.fromList(_telemetryPayload());
    final ByteData data = ByteData.sublistView(payload);
    data.setInt32(40, 1050, Endian.little);
    data.setUint16(80, 1, Endian.little);
    final LiTimeTelemetry telemetry = LiTimeTelemetry.fromPayload(payload);

    expect(telemetry.estimatedHoursToFull, 2.45);
    expect(telemetry.estimatedHoursToEmpty, isNull);
    expect(telemetry.operatingState, 'charging');
  });

  test('omits estimates while idle or below rounded current resolution', () {
    final Uint8List payload = Uint8List.fromList(_telemetryPayload());
    final ByteData data = ByteData.sublistView(payload);
    data.setInt32(40, 49, Endian.little);
    data.setUint16(80, 1, Endian.little);
    final LiTimeTelemetry telemetry = LiTimeTelemetry.fromPayload(payload);

    expect(telemetry.estimatedHoursToFull, isNull);
    expect(telemetry.estimatedHoursToEmpty, isNull);
  });

  test('decodes native app standby, full, and unknown states', () {
    final Uint8List payload = Uint8List.fromList(_telemetryPayload());
    final ByteData data = ByteData.sublistView(payload);

    expect(LiTimeTelemetry.fromPayload(payload).operatingState, 'standby');
    data.setUint16(80, 4, Endian.little);
    expect(LiTimeTelemetry.fromPayload(payload).operatingState, 'full');
    data.setUint16(80, 8, Endian.little);
    expect(LiTimeTelemetry.fromPayload(payload).operatingState, 'unknown');
  });
}

List<int> _telemetryPayload() {
  final Uint8List payload = Uint8List(104);
  final ByteData data = ByteData.sublistView(payload);
  data.setUint32(0, 13220, Endian.little);
  data.setUint32(4, 13240, Endian.little);
  for (int index = 0; index < 16; index++) {
    data.setUint16(8 + index * 2, 3301 + index, Endian.little);
  }
  data.setInt32(40, -4500, Endian.little);
  data.setInt16(44, 21, Endian.little);
  data.setInt16(46, 22, Endian.little);
  data.setInt16(48, 23, Endian.little);
  data.setUint16(54, 730, Endian.little);
  data.setUint16(56, 1000, Endian.little);
  data.setUint16(58, 1000, Endian.little);
  data.setUint32(76, 14, Endian.little);
  data.setUint16(82, 73, Endian.little);
  data.setUint32(84, 98, Endian.little);
  data.setUint32(88, 42, Endian.little);
  return payload;
}

List<int> _response(List<int> payload) {
  final int frameLength = 8 + payload.length + 1;
  final int contentLength = frameLength - 4;
  final List<int> frame = <int>[
    0x00,
    (contentLength >> 8) & 0xFF,
    contentLength & 0xFF,
    0x01,
    0x93,
    0x55,
    0xAA,
    0x00,
    ...payload,
  ];
  int checksum = 0;
  for (int index = 1; index < frame.length; index++) {
    checksum += frame[index];
  }
  frame.add(checksum & 0xFF);
  return frame;
}
