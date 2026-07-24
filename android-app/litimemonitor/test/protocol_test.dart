import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:litimemonitor/protocol.dart';

void main() {
  test('builds the recovered command 0x13 request', () {
    expect(
      LiTimeProtocol.requestTelemetry(),
      <int>[0x00, 0x00, 0x04, 0x01, 0x13, 0x55, 0xAA, 0x17],
    );
  });

  test('reassembles and validates fragmented ordinary responses', () {
    final List<int> payload = _telemetryPayload();
    final List<int> response = _response(payload);
    final LiTimeFrameParser parser = LiTimeFrameParser();

    expect(parser.appendAndExtract(response.sublist(0, 17)), isEmpty);
    final List<LiTimeFrame> frames =
        parser.appendAndExtract(response.sublist(17)).toList();

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
    final LiTimeTelemetry telemetry =
        LiTimeTelemetry.fromPayload(_telemetryPayload());

    expect(telemetry.batteryVoltageV, 13.24);
    expect(telemetry.currentA, -4.5);
    expect(telemetry.cellVoltagesMv.first, 3301);
    expect(telemetry.cellVoltagesMv.last, 3316);
    expect(telemetry.temperaturesC, <double>[21.5, 22, 22.5, 23, 23.5]);
    expect(telemetry.socPercent, 73);
    expect(telemetry.dischargeCycles, 42);
  });
}

List<int> _telemetryPayload() {
  final Uint8List payload = Uint8List(104);
  final ByteData data = ByteData.sublistView(payload);
  data.setUint32(8, 13220, Endian.little);
  data.setUint32(12, 13240, Endian.little);
  for (int index = 0; index < 16; index++) {
    data.setUint16(16 + index * 2, 3301 + index, Endian.little);
  }
  data.setInt32(48, -4500, Endian.little);
  for (int index = 0; index < 5; index++) {
    data.setInt16(52 + index * 2, 215 + index * 5, Endian.little);
  }
  data.setUint16(62, 730, Endian.little);
  data.setUint16(64, 1000, Endian.little);
  data.setUint16(66, 1000, Endian.little);
  data.setUint16(90, 73, Endian.little);
  data.setUint32(92, 98, Endian.little);
  data.setUint32(96, 42, Endian.little);
  return payload;
}

List<int> _response(List<int> payload) {
  final int frameLength = 9 + payload.length + 1;
  final int contentLength = frameLength - 4;
  final List<int> frame = <int>[
    0x00,
    0x01,
    (contentLength >> 8) & 0xFF,
    contentLength & 0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x93,
    ...payload,
  ];
  int checksum = 0;
  for (int index = 1; index < frame.length; index++) {
    checksum += frame[index];
  }
  frame.add(checksum & 0xFF);
  return frame;
}
