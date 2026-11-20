#pragma once

#include <cstddef>
#include <cstdint>

namespace waste_valve::tmc2209 {

inline uint8_t crc(const uint8_t *data, size_t length) {
  uint8_t result = 0;
  for (size_t i = 0; i < length; ++i) {
    uint8_t byte = data[i];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      result = ((result >> 7) ^ (byte & 1)) ? static_cast<uint8_t>((result << 1) ^ 0x07)
                                             : static_cast<uint8_t>(result << 1);
      byte >>= 1;
    }
  }
  return result;
}

inline void read_request(uint8_t address, uint8_t reg, uint8_t (&request)[4]) {
  request[0] = 0x05;
  request[1] = address;
  request[2] = reg;
  request[3] = crc(request, 3);
}

inline void write_request(uint8_t address, uint8_t reg, uint32_t value, uint8_t (&request)[8]) {
  request[0] = 0x05;
  request[1] = address;
  request[2] = reg | 0x80;
  request[3] = value >> 24;
  request[4] = value >> 16;
  request[5] = value >> 8;
  request[6] = value;
  request[7] = crc(request, 7);
}

inline bool decode_reply(uint8_t reg, const uint8_t (&reply)[8], uint32_t &value) {
  if (reply[0] != 0x05 || reply[1] != 0xFF || reply[2] != reg || reply[7] != crc(reply, 7))
    return false;
  value = (static_cast<uint32_t>(reply[3]) << 24) | (static_cast<uint32_t>(reply[4]) << 16) |
          (static_cast<uint32_t>(reply[5]) << 8) | reply[6];
  return true;
}

}  // namespace waste_valve::tmc2209
