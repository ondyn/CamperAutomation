#pragma once
/*
 * Roof-vent remote emulator: an nRF24L01(+) on an ESP32-C3 transmits the remote's LT8920 frames.
 * Protocol in vent_protocol.h; wiring and entities in vent-remote.yaml.
 *
 * The nRF24 runs in ShockBurst-compatible mode (no auto-ack, no packet control field, no CRC): it sends
 * its 0x55 preamble, a 3-byte 0x55 address and a 17-byte payload that holds the LT8920 sync word,
 * trailer, frame and CRC bit for bit.  Like the remote, each command is sent as rounds over the 4
 * hop channels in a background task, so the ESPHome loop never blocks.
 */

#include <cstdio>

#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"
#include "vent_protocol.h"

namespace vent {

static const char *const TAG = "vent";

static constexpr uint8_t R_CONFIG = 0x00, R_EN_AA = 0x01, R_EN_RXADDR = 0x02, R_SETUP_AW = 0x03,
                         R_SETUP_RETR = 0x04, R_RF_CH = 0x05, R_RF_SETUP = 0x06, R_STATUS = 0x07,
                         R_TX_ADDR = 0x10, R_DYNPD = 0x1C, R_FEATURE = 0x1D;
static constexpr uint8_t C_W_REG = 0x20, C_W_TX_PAYLOAD = 0xA0, C_FLUSH_TX = 0xE1, C_NOP = 0xFF;
static constexpr uint32_t BOOT_QUIET_MS = 5000;  // entity restore at boot must not move the vent

struct Radio {
  int sck{-1}, miso{-1}, mosi{-1}, csn{-1}, ce{-1}, led{-1};
  int ch_offset{0}, rounds{10}, round_gap_ms{20};
  uint8_t id[5]{};
  bool ok{false};
  uint32_t boot_ms{0}, sent{0};
  TaskHandle_t task{nullptr};
  portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
  State state;            // what the vent should be doing (as last commanded)
  State pending;          // snapshot for the TX task
  volatile bool dirty{false};
};

static Radio r;  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// --- bit-banged SPI mode 0 (same wiring as nrf24-sniffer.yaml) ------------------------------

inline void lvl_(int pin, int v) { gpio_set_level(static_cast<gpio_num_t>(pin), v); }

inline uint8_t xfer_(uint8_t out) {
  uint8_t in = 0;
  for (int i = 7; i >= 0; i--) {
    lvl_(r.mosi, (out >> i) & 1);
    lvl_(r.sck, 1);
    in = static_cast<uint8_t>((in << 1) | gpio_get_level(static_cast<gpio_num_t>(r.miso)));
    lvl_(r.sck, 0);
  }
  return in;
}

inline uint8_t cmd_(uint8_t c, const uint8_t *data = nullptr, size_t n = 0) {
  lvl_(r.csn, 0);
  const uint8_t st = xfer_(c);
  for (size_t i = 0; i < n; i++)
    xfer_(data[i]);
  lvl_(r.csn, 1);
  return st;
}

inline void write_reg_(uint8_t reg, uint8_t v) { cmd_(C_W_REG | reg, &v, 1); }

inline uint8_t read_reg_(uint8_t reg) {
  lvl_(r.csn, 0);
  xfer_(reg & 0x1F);
  const uint8_t v = xfer_(C_NOP);
  lvl_(r.csn, 1);
  return v;
}

inline void pin_(int pin, bool output) {
  gpio_config_t c = {};
  c.pin_bit_mask = 1ULL << pin;
  c.mode = output ? GPIO_MODE_OUTPUT : GPIO_MODE_INPUT;
  gpio_config(&c);
}

// --- radio ------------------------------------------------------------------------------------

inline bool radio_init_() {
  write_reg_(R_SETUP_AW, 0x02);  // SETUP_AW is writable: a read-back proves SPI works
  if (read_reg_(R_SETUP_AW) != 0x02)
    return false;
  static const uint8_t addr[3] = {0x55, 0x55, 0x55};  // continues the LT8920 preamble
  write_reg_(R_CONFIG, 0x00);
  write_reg_(R_EN_AA, 0x00);
  write_reg_(R_SETUP_RETR, 0x00);
  write_reg_(R_EN_RXADDR, 0x00);
  write_reg_(R_FEATURE, 0x00);
  write_reg_(R_DYNPD, 0x00);
  write_reg_(R_SETUP_AW, 0x01);  // 3-byte address
  cmd_(C_W_REG | R_TX_ADDR, addr, sizeof(addr));
  write_reg_(R_RF_SETUP, 0x06);  // 1 Mbps, 0 dBm
  write_reg_(R_CONFIG, 0x02);    // PWR_UP, PRIM_TX, CRC off
  esphome::delay(2);             // power-down -> standby-I
  cmd_(C_FLUSH_TX);
  write_reg_(R_STATUS, 0x70);
  return true;
}

inline bool send_packet_(uint8_t lt_ch, const uint8_t *air) {
  lvl_(r.ce, 0);
  write_reg_(R_RF_CH, static_cast<uint8_t>(lt_ch + 2 + r.ch_offset));  // nRF f = 2400 + n MHz
  cmd_(C_FLUSH_TX);
  write_reg_(R_STATUS, 0x70);
  cmd_(C_W_TX_PAYLOAD, air, AIR_LEN);
  lvl_(r.ce, 1);
  esphome::delayMicroseconds(15);
  lvl_(r.ce, 0);
  const uint32_t t0 = esphome::micros();
  while (esphome::micros() - t0 < 1000) {  // ~130 us settle + 200 us on air
    if (cmd_(C_NOP) & 0x20)               // TX_DS
      return true;
  }
  return false;
}

inline void hex_(const uint8_t *d, size_t n, char *out, size_t size) {
  size_t off = 0;
  out[0] = '\0';
  for (size_t i = 0; i < n && off + 4 < size; i++)
    off += snprintf(out + off, size - off, "%02X ", d[i]);
  if (off)
    out[off - 1] = '\0';
}

inline void task_(void *) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    State s;
    portENTER_CRITICAL(&r.lock);
    s = r.pending;
    r.dirty = false;
    portEXIT_CRITICAL(&r.lock);

    uint8_t frame[FRAME_LEN], air[AIR_LEN];
    build_frame(s, r.id, frame);
    build_air(frame, air);
    char hex[3 * FRAME_LEN + 1];
    hex_(frame, FRAME_LEN, hex, sizeof(hex));
    ESP_LOGI(TAG, "TX %s | power %s rain %s lid %s fan %s %u0%%", hex, s.power ? "ON" : "OFF",
             s.rain ? "on" : "off", s.opening ? "OPENING" : s.closing ? "CLOSING" : "stop", s.fan_out ? "OUT" : "IN",
             s.level);

    int fails = 0;
    if (r.led >= 0)
      lvl_(r.led, 0);
    for (int round = 0; round < r.rounds && !r.dirty; round++) {
      for (uint8_t ch : CHANNELS) {
        fails += !send_packet_(ch, air);
        esphome::delayMicroseconds(900);  // remote spaces packets ~1.2 ms
      }
      vTaskDelay(pdMS_TO_TICKS(r.round_gap_ms));
    }
    if (r.led >= 0)
      lvl_(r.led, 1);
    r.sent++;
    if (fails)
      ESP_LOGW(TAG, "%d packets without TX_DS - check nRF24 power/cap", fails);
  }
}

// --- API for vent-remote.yaml -------------------------------------------------------------------

inline void begin(int sck, int miso, int mosi, int csn, int ce, int led, int ch_offset, int rounds,
                  uint64_t remote_id) {
  r.sck = sck, r.miso = miso, r.mosi = mosi, r.csn = csn, r.ce = ce, r.led = led;
  r.ch_offset = ch_offset;
  r.rounds = rounds;
  for (int i = 0; i < 5; i++)
    r.id[i] = static_cast<uint8_t>(remote_id >> (8 * (4 - i)));  // 0x5F1802000E -> 5F 18 02 00 0E
  for (int p : {sck, mosi, csn, ce, led})
    if (p >= 0)
      pin_(p, true);
  pin_(miso, false);
  lvl_(sck, 0), lvl_(csn, 1), lvl_(ce, 0);
  if (led >= 0)
    lvl_(led, 1);  // C3 Super Mini LED is active-low
  esphome::delay(5);  // nRF24 power-on reset
  r.boot_ms = esphome::millis();
  r.ok = radio_init_();
  if (!r.ok) {
    ESP_LOGE(TAG, "nRF24 not responding on SPI - check wiring, 3.3 V and the 10 uF cap");
    return;
  }
  ESP_LOGI(TAG, "nRF24 ready: remote ID %02X %02X %02X %02X %02X, %d rounds x 4 ch, channel offset %+d MHz",
           r.id[0], r.id[1], r.id[2], r.id[3], r.id[4], rounds, ch_offset);
  xTaskCreate(task_, "vent_tx", 4096, nullptr, 5, &r.task);
}

inline bool radio_ok() { return r.ok; }
inline const State &state() { return r.state; }

// Queues the current state for transmission; a newer command interrupts a running burst.
inline void send() {
  portENTER_CRITICAL(&r.lock);
  r.pending = r.state;
  r.dirty = true;
  portEXIT_CRITICAL(&r.lock);
  xTaskNotifyGive(r.task);
}

// Entity restores at boot run before this window ends and must neither move the vent nor alter state.
inline bool accepting_() {
  if (!r.ok || r.task == nullptr || esphome::millis() - r.boot_ms < BOOT_QUIET_MS) {
    ESP_LOGD(TAG, "command ignored (radio not ready or boot restore)");
    return false;
  }
  return true;
}

inline void resend() {
  if (accepting_())
    send();
}

// Remote's OFF -> ON frame carries flags 80 (rain off, lid stop).
inline void power_on_() {
  if (!r.state.power)
    r.state.rain = r.state.opening = r.state.closing = false;
  r.state.power = true;
}

// The remote transmits nothing while it is OFF, so every command except power-off switches power on.
inline void set_power(bool on) {
  if (!accepting_())
    return;
  if (on) {
    power_on_();
  } else {
    r.state.power = false;
    r.state.opening = false;
    r.state.closing = true;  // remote's OFF frame: flags 20
  }
  send();
}

inline void set_fan(bool on, int speed, bool out) {
  if (!accepting_())
    return;
  power_on_();
  r.state.level = on ? static_cast<uint8_t>(speed < 1 ? 1 : speed > 10 ? 10 : speed) : 0;
  r.state.fan_out = out;
  send();
}

inline void set_lid(int dir) {  // 1 open, -1 close, 0 stop
  if (!accepting_())
    return;
  power_on_();
  r.state.opening = dir > 0;
  r.state.closing = dir < 0;
  send();
}

inline void set_rain(bool on) {
  if (!accepting_())
    return;
  power_on_();
  r.state.rain = on;
  send();
}

}  // namespace vent
