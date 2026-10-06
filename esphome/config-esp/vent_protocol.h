#pragma once
// Roof-vent remote protocol (LT8920, decoded from the remote's SPI bus). No ESPHome dependencies so
// it can be unit-tested on the host. Reference: docs/architecture/vent-rf-integration.md,
// vent/vent_protocol.py.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace vent {

struct State {
  bool power{false};
  bool rain{false};     // rain detection enabled
  bool opening{false};  // lid moving up
  bool closing{false};  // lid moving down
  bool fan_out{true};   // fan direction: true = OUT (exhaust), false = IN
  uint8_t level{0};     // fan level 0..10 (x10 %), 0 = fan off
};

static constexpr size_t FRAME_LEN = 12;  // length byte + 9 payload bytes + 2 CRC bytes
static constexpr size_t AIR_LEN = 17;    // sync word + trailer + frame as nRF24 payload bytes
static const uint8_t SYNC[4] = {0x16, 0x05, 0x82, 0x19};  // LT8920 r36=0516, r39=1982
static const uint8_t CHANNELS[4] = {6, 26, 62, 78};       // LT8920 channels, f = 2402 + ch MHz

inline uint16_t crc16_kermit(const uint8_t *d, size_t n) {
  uint16_t c = 0;  // LT8920 r41 CRC seed 00
  for (size_t i = 0; i < n; i++) {
    c ^= d[i];
    for (int b = 0; b < 8; b++)
      c = (c & 1) ? (c >> 1) ^ 0x8408 : c >> 1;
  }
  return c;
}

inline void build_frame(const State &s, const uint8_t id[5], uint8_t out[FRAME_LEN]) {
  out[0] = 9;
  memcpy(out + 1, id, 5);
  out[6] = static_cast<uint8_t>(s.power << 7 | s.rain << 6 | s.closing << 5 | s.opening << 4);
  out[7] = 0xCF;
  out[8] = static_cast<uint8_t>(s.fan_out << 7 | (s.level > 10 ? 10 : s.level));
  uint8_t sum = 0;
  for (int i = 0; i < 9; i++)
    sum += out[i];
  out[9] = sum;
  const uint16_t crc = crc16_kermit(out, 10);
  out[10] = crc & 0xFF;
  out[11] = crc >> 8;
}

// The nRF24 sends its 0x55 preamble + 3-byte 0x55 address (= LT8920 preamble), then this payload MSB
// first; the LT8920 stream is LSB first per byte, so the bits are re-packed here.
inline void build_air(const uint8_t frame[FRAME_LEN], uint8_t out[AIR_LEN]) {
  memset(out, 0, AIR_LEN);
  size_t pos = 0;
  auto put = [&](int bit) {
    if (bit)
      out[pos >> 3] |= 0x80 >> (pos & 7);
    pos++;
  };
  for (uint8_t b : SYNC)
    for (int i = 0; i < 8; i++)
      put(b >> i & 1);
  for (int bit : {1, 0, 1, 0})  // 4-bit trailer as captured on air
    put(bit);
  for (size_t k = 0; k < FRAME_LEN; k++)
    for (int i = 0; i < 8; i++)
      put(frame[k] >> i & 1);
  while (pos < AIR_LEN * 8)
    put(1);  // idle level seen after the remote's CRC
}

}  // namespace vent
