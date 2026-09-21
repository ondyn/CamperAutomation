#pragma once
/*
 * Minimal nRF24L01(+) driver used as a 2.4 GHz band scanner.
 *
 * It exists to answer one question: does the roof-vent remote transmit
 * anywhere between 2400 and 2525 MHz? Wiring, usage and the history of what
 * was already tried live in nrf24-sniffer.yaml.
 *
 * Bit-banged SPI on purpose: the nRF24 needs at most a few hundred kbit/s here
 * and this keeps the whole radio self-contained with no bus/pin-matrix config.
 */

#include <cstdint>
#include <cstdio>

#include "driver/gpio.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace nrf24 {

static const char *const TAG = "nrf24";

static constexpr uint8_t CH_MAX = 125;     // RF channel n sits at 2400 + n MHz
static constexpr uint16_t DWELL_US = 200;  // RPD latches after ~170 us in RX

// SPI commands
static constexpr uint8_t C_R_REG = 0x00;
static constexpr uint8_t C_W_REG = 0x20;
static constexpr uint8_t C_R_RX_PAYLOAD = 0x61;
static constexpr uint8_t C_FLUSH_RX = 0xE2;
static constexpr uint8_t C_NOP = 0xFF;

// Registers
static constexpr uint8_t R_CONFIG = 0x00;
static constexpr uint8_t R_EN_AA = 0x01;
static constexpr uint8_t R_EN_RXADDR = 0x02;
static constexpr uint8_t R_SETUP_AW = 0x03;
static constexpr uint8_t R_SETUP_RETR = 0x04;
static constexpr uint8_t R_RF_CH = 0x05;
static constexpr uint8_t R_RF_SETUP = 0x06;
static constexpr uint8_t R_STATUS = 0x07;
static constexpr uint8_t R_RPD = 0x09;
static constexpr uint8_t R_RX_ADDR_P0 = 0x0A;
static constexpr uint8_t R_RX_PW_P0 = 0x11;

struct State {
  int sck{-1}, miso{-1}, mosi{-1}, csn{-1}, ce{-1};
  bool ready{false};
  uint8_t cursor{0};
  uint32_t sweeps{0};
  uint16_t hits[CH_MAX + 1]{};
};

static State s;  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// --- bit-banged SPI mode 0, MSB first -------------------------------------

inline void cfg_pin_(int pin, bool output) {
  gpio_config_t c = {};
  c.pin_bit_mask = 1ULL << pin;
  c.mode = output ? GPIO_MODE_OUTPUT : GPIO_MODE_INPUT;
  c.pull_up_en = GPIO_PULLUP_DISABLE;
  c.pull_down_en = GPIO_PULLDOWN_DISABLE;
  c.intr_type = GPIO_INTR_DISABLE;
  gpio_config(&c);
}

inline void lvl_(int pin, int value) { gpio_set_level(static_cast<gpio_num_t>(pin), value); }

inline uint8_t xfer_(uint8_t out) {
  uint8_t in = 0;
  for (int i = 7; i >= 0; i--) {
    lvl_(s.mosi, (out >> i) & 1);
    lvl_(s.sck, 1);
    in = static_cast<uint8_t>((in << 1) | gpio_get_level(static_cast<gpio_num_t>(s.miso)));
    lvl_(s.sck, 0);
  }
  return in;
}

inline uint8_t cmd_(uint8_t c) {
  lvl_(s.csn, 0);
  const uint8_t st = xfer_(c);
  lvl_(s.csn, 1);
  return st;
}

inline uint8_t read_reg_(uint8_t reg) {
  lvl_(s.csn, 0);
  xfer_(C_R_REG | (reg & 0x1F));
  const uint8_t v = xfer_(C_NOP);
  lvl_(s.csn, 1);
  return v;
}

inline void write_reg_(uint8_t reg, uint8_t value) {
  lvl_(s.csn, 0);
  xfer_(C_W_REG | (reg & 0x1F));
  xfer_(value);
  lvl_(s.csn, 1);
}

inline void write_buf_(uint8_t reg, const uint8_t *buf, uint8_t len) {
  lvl_(s.csn, 0);
  xfer_(C_W_REG | (reg & 0x1F));
  for (uint8_t i = 0; i < len; i++)
    xfer_(buf[i]);
  lvl_(s.csn, 1);
}

inline void read_buf_(uint8_t command, uint8_t *buf, uint8_t len) {
  lvl_(s.csn, 0);
  xfer_(command);
  for (uint8_t i = 0; i < len; i++)
    buf[i] = xfer_(C_NOP);
  lvl_(s.csn, 1);
}

// --- radio modes ----------------------------------------------------------

// Carrier-detect only: no pipes, no auto-ack, 2 Mbps for the widest (2 MHz) RX
// filter so a transmitter that sits between two channels is still seen.
inline void scan_mode_() {
  lvl_(s.ce, 0);
  write_reg_(R_EN_AA, 0x00);
  write_reg_(R_EN_RXADDR, 0x00);
  write_reg_(R_SETUP_RETR, 0x00);
  write_reg_(R_SETUP_AW, 0x03);
  write_reg_(R_RF_SETUP, 0x0E);  // 2 Mbps, 0 dBm
  write_reg_(R_CONFIG, 0x03);    // PWR_UP | PRIM_RX, CRC off
  esphome::delay_microseconds_safe(2000);
  cmd_(C_FLUSH_RX);
  write_reg_(R_STATUS, 0x70);
}

inline bool begin(int sck, int miso, int mosi, int csn, int ce) {
  s.sck = sck;
  s.miso = miso;
  s.mosi = mosi;
  s.csn = csn;
  s.ce = ce;

  cfg_pin_(sck, true);
  cfg_pin_(mosi, true);
  cfg_pin_(csn, true);
  cfg_pin_(ce, true);
  cfg_pin_(miso, false);
  lvl_(s.sck, 0);
  lvl_(s.mosi, 0);
  lvl_(s.csn, 1);
  lvl_(s.ce, 0);
  esphome::delay_microseconds_safe(5000);  // power-on reset

  // Presence check: SETUP_AW is writable, so a read-back proves SPI really works.
  write_reg_(R_SETUP_AW, 0x02);
  const uint8_t aw = read_reg_(R_SETUP_AW);
  write_reg_(R_SETUP_AW, 0x03);
  if (aw != 0x02) {
    s.ready = false;
    ESP_LOGE(TAG, "nRF24 not responding (SETUP_AW read back 0x%02X, expected 0x02).", aw);
    ESP_LOGE(TAG, "Check: VCC on 3.3V (never 5V), 10 uF cap at the module, MISO/MOSI not swapped.");
    return false;
  }

  scan_mode_();
  s.ready = true;
  ESP_LOGI(TAG, "nRF24 ready. Hold the vent remote ~10 cm from the antenna and press its buttons.");
  return true;
}

// --- scanning -------------------------------------------------------------

// Visit `count` channels, sampling the Received Power Detector on each.
// ~230 us per channel, so keep `count` small enough to stay under the
// ESPHome loop budget (32 channels ~= 7 ms).
inline void scan(uint8_t count) {
  if (!s.ready)
    return;
  for (uint8_t i = 0; i < count; i++) {
    write_reg_(R_RF_CH, s.cursor);
    lvl_(s.ce, 1);
    esphome::delay_microseconds_safe(DWELL_US);
    lvl_(s.ce, 0);
    if ((read_reg_(R_RPD) & 0x01) != 0)
      s.hits[s.cursor]++;

    if (s.cursor >= CH_MAX) {
      s.cursor = 0;
      s.sweeps++;
    } else {
      s.cursor++;
    }
  }
}

inline char glyph_(uint16_t hits, uint32_t sweeps) {
  if (hits == 0)
    return '.';
  const uint32_t pct = (100UL * hits) / sweeps;
  if (pct >= 60)
    return '#';
  if (pct >= 30)
    return '+';
  if (pct >= 10)
    return ':';
  return '-';
}

// Dump the accumulated spectrum and clear the window. Returns the busiest
// channel, or 0xFF when the band was silent.
inline uint8_t report(bool marked) {
  if (!s.ready)
    return 0xFF;
  if (s.sweeps == 0) {
    ESP_LOGW(TAG, "No full sweep completed yet.");
    return 0xFF;
  }

  char spectrum[CH_MAX + 2];
  char ruler[CH_MAX + 2];
  uint16_t top_hits = 0;
  uint8_t top_ch = 0;
  for (uint8_t c = 0; c <= CH_MAX; c++) {
    spectrum[c] = glyph_(s.hits[c], s.sweeps);
    ruler[c] = (c % 10 == 0) ? static_cast<char>('0' + (c / 10) % 10) : ((c % 5 == 0) ? '+' : '-');
    if (s.hits[c] > top_hits) {
      top_hits = s.hits[c];
      top_ch = c;
    }
  }
  spectrum[CH_MAX + 1] = '\0';
  ruler[CH_MAX + 1] = '\0';

  ESP_LOGI(TAG, "--- %s  sweeps=%u  legend: . none  - <10%%  : <30%%  + <60%%  # >=60%% ---",
           marked ? "BUTTON HELD" : "idle window", static_cast<unsigned>(s.sweeps));
  ESP_LOGI(TAG, "2400 %s 2525 MHz", ruler);
  ESP_LOGI(TAG, "RF   %s", spectrum);

  if (top_hits == 0) {
    ESP_LOGI(TAG, "Band silent - nothing above the -64 dBm RPD threshold.");
  } else {
    ESP_LOGI(TAG, "Busiest: ch%u = %u MHz, %u%% of sweeps.", top_ch, 2400 + top_ch,
             static_cast<unsigned>((100UL * top_hits) / s.sweeps));
  }

  s.sweeps = 0;
  for (uint8_t c = 0; c <= CH_MAX; c++)
    s.hits[c] = 0;
  return top_hits == 0 ? 0xFF : top_ch;
}

// --- pseudo-promiscuous capture -------------------------------------------

// With CRC off and an (illegal but functional) 2-byte address of 0x00AA, the
// tail of the nRF24 preamble acts as the address match, so nearby packets are
// dumped raw. Output is noisy by design - it is only worth running once the
// scan has pinned a channel down.
inline void sniff(uint8_t channel, uint32_t duration_ms) {
  if (!s.ready || channel > CH_MAX)
    return;

  static const uint8_t promisc_addr[2] = {0xAA, 0x00};  // LSB first over SPI
  lvl_(s.ce, 0);
  write_reg_(R_CONFIG, 0x00);
  write_reg_(R_SETUP_AW, 0x00);
  write_buf_(R_RX_ADDR_P0, promisc_addr, 2);
  write_reg_(R_EN_RXADDR, 0x01);
  write_reg_(R_RX_PW_P0, 32);
  write_reg_(R_RF_CH, channel);
  write_reg_(R_CONFIG, 0x03);
  esphome::delay_microseconds_safe(2000);
  cmd_(C_FLUSH_RX);
  write_reg_(R_STATUS, 0x70);
  lvl_(s.ce, 1);

  uint8_t payload[32];
  uint8_t logged = 0;
  const uint32_t started = esphome::millis();
  while (esphome::millis() - started < duration_ms) {
    if ((read_reg_(R_STATUS) & 0x40) == 0)
      continue;
    read_buf_(C_R_RX_PAYLOAD, payload, sizeof(payload));
    write_reg_(R_STATUS, 0x40);
    if (logged >= 4)
      continue;
    logged++;

    char hex[3 * sizeof(payload) + 1];
    size_t off = 0;
    for (uint8_t i = 0; i < sizeof(payload); i++)
      off += snprintf(hex + off, sizeof(hex) - off, "%02X ", payload[i]);
    ESP_LOGI(TAG, "PKT ch%u (%u MHz): %s", channel, 2400 + channel, hex);
  }

  lvl_(s.ce, 0);
  cmd_(C_FLUSH_RX);
  scan_mode_();
}

}  // namespace nrf24
