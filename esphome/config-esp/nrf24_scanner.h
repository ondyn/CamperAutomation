#pragma once
/*
 * nRF24L01(+) tool for the roof-vent remote (2.4 GHz, LT8900/PL1167-class GFSK, 1 Mbps).
 *
 *   sniff_ch = -1 : SCAN mode.  20 s HANDS OFF / 20 s PRESS windows (start with BOOT), per-channel
 *                   RPD statistics and a verdict naming the channel the remote uses.
 *   sniff_ch >= 0 : BUTTON mode.  Raw capture on that channel; every remote press is turned into one
 *                   majority-voted packet and printed next to the earlier presses, button by button.
 *                   BOOT advances to the next button and prints the comparison table.
 *
 * The radio runs in its own FreeRTOS task; the ESPHome loop only analyses and logs.
 * Wiring and procedure: nrf24-sniffer.yaml.
 */

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "driver/gpio.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace nrf24 {

static const char *const TAG = "nrf24";

// EU 2.4 GHz ISM is 2400-2483.5 MHz; nRF24 channel n = 2400 + n MHz.
static constexpr uint8_t NCH = 84;
static constexpr uint16_t SETTLE_US = 170;  // 130 us RX settling + 40 us RPD filter
static constexpr uint16_t DWELL_US = 1000;
static constexpr uint32_t IDLE_MS = 20000;
static constexpr uint32_t PRESS_MS = 20000;

// Button mode
static const char *const BUTTONS[] = {"POWER", "-", "+", "FAN", "IN", "OUT", "UP", "DOWN", "RAIN SENSOR"};
static constexpr uint8_t NBTN = sizeof(BUTTONS) / sizeof(BUTTONS[0]);
static constexpr uint8_t TAIL_FROM = 18;
static constexpr uint8_t TAIL_MIN_ONES = 84;  // of 112 bits; noise sits near 56
static constexpr uint8_t PKT_BYTES = 17;      // bytes printed per packet, starting at the sync word
static constexpr int PKT_BITS = PKT_BYTES * 8;
static constexpr int MAX_SHIFT = 6;
static constexpr float MIN_AGREE = 0.75f;
static constexpr uint32_t BURST_GAP_MS = 300;
static constexpr uint8_t MAX_BURST = 24;
static constexpr uint8_t MAX_PRESSES = 12;
static constexpr uint8_t GOOD_Q = 80;  // presses below this agreement are shown but not analysed
static constexpr uint32_t BOOT_HOLD_MS = 1500;
// Byte (LSB-first) holding the fan level as 8 * level + 6, level 0..10 = 0..100 %.
static constexpr uint8_t FAN_BYTE = 12;

static constexpr uint8_t C_R_REG = 0x00;
static constexpr uint8_t C_W_REG = 0x20;
static constexpr uint8_t C_R_RX_PAYLOAD = 0x61;
static constexpr uint8_t C_FLUSH_RX = 0xE2;
static constexpr uint8_t C_NOP = 0xFF;

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
static constexpr uint8_t R_FIFO_STATUS = 0x17;

enum Mode : uint8_t { MODE_SCAN, MODE_SNIFF };

struct Packet {
  uint8_t data[32];
};

struct Press {
  uint8_t bits[PKT_BYTES];
  uint8_t used, total;
  uint8_t quality;  // mean agreement of the voted packets, %
};

struct State {
  int sck{-1}, miso{-1}, mosi{-1}, csn{-1}, ce{-1}, led{-1}, boot{-1};
  bool ready{false}, started{false}, button_mode{false};
  QueueHandle_t queue{nullptr};

  // shared with the radio task
  volatile uint8_t mode{MODE_SCAN}, sniff_ch{0};
  volatile bool reconfigure{false}, reset_window{false};
  volatile uint16_t win_hits[NCH]{};
  volatile uint32_t win_sweeps{0}, sweep_us{0}, packets{0}, dropped{0};

  // scan mode, owned by the ESPHome loop
  bool press{false}, countdown_logged{false};
  uint32_t phase_end_ms{0}, last_status_ms{0};
  uint16_t press_windows{0}, idle_windows{0};
  uint32_t press_sweeps{0}, idle_sweeps{0};
  uint32_t press_hits[NCH]{}, idle_hits[NCH]{};

  // button mode, owned by the ESPHome loop
  Packet burst[MAX_BURST]{};
  uint8_t burst_n{0}, button{0};
  uint32_t burst_last_ms{0}, noise_bursts{0}, boot_ms{0}, boot_down_ms{0};
  bool boot_was_down{false}, boot_long_done{false}, have_ref{false};
  uint8_t ref[PKT_BYTES]{};
  Press presses[NBTN][MAX_PRESSES]{};
  uint8_t n_press[NBTN]{};
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

inline void led_(bool on) {
  if (s.led >= 0)
    lvl_(s.led, on ? 0 : 1);  // Super Mini LED is active-low
}

// --- radio task ---------------------------------------------------------------

// Carrier detect only: no pipes, 2 Mbps for the widest (2 MHz) RX filter.
inline void scan_mode_() {
  lvl_(s.ce, 0);
  write_reg_(R_EN_AA, 0x00);
  write_reg_(R_EN_RXADDR, 0x00);
  write_reg_(R_SETUP_RETR, 0x00);
  write_reg_(R_SETUP_AW, 0x03);
  write_reg_(R_RF_SETUP, 0x0E);
  write_reg_(R_CONFIG, 0x03);  // PWR_UP | PRIM_RX, CRC off
  cmd_(C_FLUSH_RX);
  write_reg_(R_STATUS, 0x70);
}

// Goodspeed's trick: an illegal 2-byte address 0x0055 with CRC off makes the end of the remote's
// preamble an address match, so its packets are dumped raw (plus noise, filtered later).
inline void sniff_mode_(uint8_t ch) {
  static const uint8_t addr[2] = {0x55, 0x00};  // LSB first over SPI
  lvl_(s.ce, 0);
  write_reg_(R_EN_AA, 0x00);
  write_reg_(R_SETUP_RETR, 0x00);
  write_reg_(R_SETUP_AW, 0x00);
  write_buf_(R_RX_ADDR_P0, addr, 2);
  write_reg_(R_EN_RXADDR, 0x01);
  write_reg_(R_RX_PW_P0, 32);
  write_reg_(R_RF_CH, ch);
  write_reg_(R_RF_SETUP, 0x06);  // 1 Mbps
  write_reg_(R_CONFIG, 0x03);
  cmd_(C_FLUSH_RX);
  write_reg_(R_STATUS, 0x70);
  lvl_(s.ce, 1);
}

inline void sweep_() {
  if (s.reset_window) {
    for (auto &h : s.win_hits)
      h = 0;
    s.win_sweeps = 0;
    s.reset_window = false;
  }
  const uint32_t t0 = esphome::micros();
  for (uint8_t ch = 0; ch < NCH; ch++) {
    lvl_(s.ce, 0);
    write_reg_(R_RF_CH, ch);
    lvl_(s.ce, 1);
    esphome::delayMicroseconds(SETTLE_US);
    // RPD is a live snapshot while in RX, so poll it through the whole dwell, not once.
    const uint32_t t = esphome::micros();
    while (esphome::micros() - t < DWELL_US - SETTLE_US) {
      if (read_reg_(R_RPD) & 0x01) {
        s.win_hits[ch] = s.win_hits[ch] + 1;
        break;
      }
    }
  }
  lvl_(s.ce, 0);
  s.sweep_us = esphome::micros() - t0;
  s.win_sweeps = s.win_sweeps + 1;
}

inline void sniff_poll_(uint32_t ms) {
  Packet p;
  const uint32_t t0 = esphome::millis();
  while (esphome::millis() - t0 < ms) {
    if (read_reg_(R_FIFO_STATUS) & 0x01)  // RX_EMPTY
      continue;
    read_buf_(C_R_RX_PAYLOAD, p.data, sizeof(p.data));
    write_reg_(R_STATUS, 0x40);
    s.packets = s.packets + 1;
    if (xQueueSend(s.queue, &p, 0) != pdTRUE)
      s.dropped = s.dropped + 1;
  }
}

inline void task_(void *) {
  uint8_t active = MODE_SCAN;
  for (;;) {
    const uint8_t want = s.mode;
    if (want != active || s.reconfigure) {
      s.reconfigure = false;
      if (want == MODE_SNIFF)
        sniff_mode_(s.sniff_ch);
      else
        scan_mode_();
      active = want;
    }
    if (active == MODE_SCAN)
      sweep_();
    else
      sniff_poll_(20);
    vTaskDelay(1);  // let the ESPHome loop and the idle task (watchdog) run
  }
}

// --- bit helpers for button mode ---------------------------------------------------

inline int bit_(const uint8_t *d, int nbits, int i) {
  if (i < 0)
    return i & 1;  // pretend the alternating preamble continues to the left
  if (i >= nbits)
    return 1;  // the demodulator reads 1s after the packet ends
  return (d[i >> 3] >> (7 - (i & 7))) & 1;
}

inline void set_bit_(uint8_t *d, int i, int v) {
  const uint8_t m = 1 << (7 - (i & 7));
  d[i >> 3] = v ? (d[i >> 3] | m) : (d[i >> 3] & ~m);
}

// The capture starts inside the alternating 0101 preamble; the first repeated bit is the sync word.
inline int data_start_(const uint8_t *d) {
  for (int i = 1; i < 64; i++) {
    if (bit_(d, 256, i) == bit_(d, 256, i - 1))
      return i - 1;
  }
  return -1;
}

inline float agree_(const uint8_t *a, int na, int sa, const uint8_t *b, int nb, int sb) {
  int same = 0;
  for (int k = 8; k < PKT_BITS; k++)
    same += bit_(a, na, sa + k) == bit_(b, nb, sb + k);
  return static_cast<float>(same) / (PKT_BITS - 8);
}

inline int best_shift_(const uint8_t *a, int na, int sa, const uint8_t *b, int nb, int sb, float *score) {
  int best = 0;
  *score = -1.0f;
  for (int sh = -MAX_SHIFT; sh <= MAX_SHIFT; sh++) {
    const float g = agree_(a, na, sa, b, nb, sb + sh);
    if (g > *score) {
      *score = g;
      best = sh;
    }
  }
  return best;
}

inline void hex_(const uint8_t *d, uint8_t n, char *out, size_t size) {
  size_t off = 0;
  for (uint8_t i = 0; i < n && off + 3 < size; i++)
    off += snprintf(out + off, size - off, "%02X ", d[i]);
  if (off)
    out[off - 1] = '\0';
}

// Shifts a voted packet onto the common reference framing so bytes line up across presses/buttons.
inline float align_to_ref_(uint8_t *bits) {
  if (!s.have_ref)
    return 1.0f;
  float score;
  const int sh = best_shift_(s.ref, PKT_BITS, 0, bits, PKT_BITS, 0, &score);
  uint8_t out[PKT_BYTES] = {};
  for (int k = 0; k < PKT_BITS; k++)
    set_bit_(out, k, bit_(bits, PKT_BITS, k + sh));
  memcpy(bits, out, PKT_BYTES);
  return score;
}

// --- button mode -----------------------------------------------------------------

inline void prompt_() {
  ESP_LOGW(TAG, "################################################################");
  ESP_LOGW(TAG, " BUTTON %u/%u: [%s]", s.button + 1, NBTN, BUTTONS[s.button]);
  ESP_LOGW(TAG, " Press it 4-10x, ~2 s apart; note what the remote display / vent does each time.");
  ESP_LOGW(TAG, " BOOT tap = analyse this button + next one.  BOOT hold 2 s = restart this button.");
  ESP_LOGW(TAG, "################################################################");
}

inline bool good_(const Press &p) { return p.used >= 2 && p.quality >= GOOD_Q; }

inline uint8_t rev8_(uint8_t x) {
  x = static_cast<uint8_t>((x & 0xF0) >> 4 | (x & 0x0F) << 4);
  x = static_cast<uint8_t>((x & 0xCC) >> 2 | (x & 0x33) << 2);
  return static_cast<uint8_t>((x & 0xAA) >> 1 | (x & 0x55) << 1);
}

inline int label_w_(uint8_t b) { return static_cast<int>(std::max<size_t>(6, strlen(BUTTONS[b]))); }

// LT8920 frame as configured by the remote (seen on its SPI bus): preamble, 32-bit sync word
// r36=0516 r39=1982 (bytes 16 05 82 19, each LSB first), 4-bit trailer, length byte, payload,
// CRC-16/KERMIT over length+payload (low byte first).  All bytes LSB first.
static const uint8_t SYNC_BYTES[4] = {0x16, 0x05, 0x82, 0x19};
static constexpr int SYNC_MATCH = 24;  // the nRF24 address match may eat the first sync bits
static constexpr int MAX_FRAME = 32;

inline uint16_t crc_kermit_(const uint8_t *d, int n) {
  uint16_t c = 0;
  for (int i = 0; i < n; i++) {
    c ^= d[i];
    for (int b = 0; b < 8; b++)
      c = (c & 1) ? (c >> 1) ^ 0x8408 : c >> 1;
  }
  return c;
}

// Returns the frame length (len byte + payload + 2 CRC bytes) if a CRC-valid frame is found, else 0.
inline int decode_frame_(const uint8_t *d, int nbits, uint8_t *out) {
  int sync[32];
  for (int i = 0; i < 32; i++)
    sync[i] = (SYNC_BYTES[i >> 3] >> (i & 7)) & 1;
  for (int pos = 0; pos <= 96; pos++) {
    int errors = 0;
    for (int k = 0; k < SYNC_MATCH && errors <= 1; k++)
      errors += bit_(d, nbits, pos + k) != sync[32 - SYNC_MATCH + k];
    if (errors > 1)  // the CRC check below rejects false sync hits
      continue;
    const int at = pos + SYNC_MATCH + 4;
    auto rd = [&](int i) {
      uint8_t v = 0;
      for (int b = 0; b < 8; b++)
        v |= bit_(d, nbits, at + 8 * i + b) << b;
      return v;
    };
    const uint8_t len = rd(0);
    if (len == 0 || len + 3 > MAX_FRAME)
      continue;
    for (int i = 0; i < len + 3; i++)
      out[i] = rd(i);
    const uint16_t c = crc_kermit_(out, len + 1);
    if (out[len + 1] == (c & 0xFF) && out[len + 2] == (c >> 8))
      return len + 3;
  }
  return 0;
}

// Logs every distinct CRC-valid frame of a burst - exact bytes, no voting needed.
inline void log_frames_() {
  uint8_t frames[MAX_BURST][MAX_FRAME];
  int lens[MAX_BURST], counts[MAX_BURST], nf = 0, ok = 0;
  for (uint8_t i = 0; i < s.burst_n; i++) {
    uint8_t f[MAX_FRAME];
    const int n = decode_frame_(s.burst[i].data, 256, f);
    if (!n)
      continue;
    ok++;
    int j = 0;
    while (j < nf && !(lens[j] == n && memcmp(frames[j], f, n) == 0))
      j++;
    if (j == nf) {
      memcpy(frames[nf], f, n);
      lens[nf] = n;
      counts[nf++] = 0;
    }
    counts[j]++;
  }
  if (!ok)
    return;
  for (int j = 0; j < nf; j++) {
    char hex[3 * MAX_FRAME + 1];
    hex_(frames[j], lens[j], hex, sizeof(hex));
    ESP_LOGW(TAG, "[%s] radio CRC OK x%d/%u: %s", BUTTONS[s.button], counts[j], s.burst_n, hex);
  }
}

inline void analyse_press_() {
  log_frames_();
  const uint8_t n = s.burst_n;
  s.burst_n = 0;
  int start[MAX_BURST];
  uint8_t valid = 0;
  for (uint8_t i = 0; i < n; i++) {
    start[i] = data_start_(s.burst[i].data);
    valid += start[i] >= 0;
  }
  if (valid < 2) {
    s.noise_bursts++;
    return;
  }

  // Medoid = the packet that agrees best with all others; vote everything close enough to it.
  int med = -1;
  float med_sum = -1.0f;
  for (uint8_t i = 0; i < n; i++) {
    if (start[i] < 0)
      continue;
    float sum = 0.0f, sc;
    for (uint8_t j = 0; j < n; j++) {
      if (j == i || start[j] < 0)
        continue;
      best_shift_(s.burst[i].data, 256, start[i], s.burst[j].data, 256, start[j], &sc);
      sum += sc;
    }
    if (sum > med_sum) {
      med_sum = sum;
      med = i;
    }
  }

  int shift[MAX_BURST];
  bool use[MAX_BURST] = {};
  uint8_t used = 0;
  float qsum = 0.0f;
  for (uint8_t j = 0; j < n; j++) {
    if (start[j] < 0)
      continue;
    float sc = 1.0f;
    shift[j] = j == med ? 0 : best_shift_(s.burst[med].data, 256, start[med], s.burst[j].data, 256, start[j], &sc);
    if (sc >= MIN_AGREE) {
      use[j] = true;
      used++;
      if (j != med)
        qsum += sc;
    }
  }
  if (used < 2) {
    s.noise_bursts++;
    return;
  }

  Press p{};
  for (int k = 0; k < PKT_BITS; k++) {
    int ones = 0;
    for (uint8_t j = 0; j < n; j++) {
      if (use[j])
        ones += bit_(s.burst[j].data, 256, start[j] + shift[j] + k);
    }
    set_bit_(p.bits, k, ones * 2 > used);
  }
  p.used = used;
  p.total = n;
  p.quality = static_cast<uint8_t>(100.0f * qsum / (used - 1));

  uint8_t frame[MAX_FRAME];
  const int flen = decode_frame_(p.bits, PKT_BITS, frame);
  if (flen) {
    char fhex[3 * MAX_FRAME + 1];
    hex_(frame, flen, fhex, sizeof(fhex));
    ESP_LOGW(TAG, "[%s] radio voted frame CRC OK (%u pkts): %s", BUTTONS[s.button], used, fhex);
  } else {
    ESP_LOGI(TAG, "[%s] radio voted frame: CRC mismatch (%u pkts, q %u%%)", BUTTONS[s.button], used, p.quality);
  }

  if (!s.have_ref && used >= 3 && p.quality >= 80) {
    memcpy(s.ref, p.bits, PKT_BYTES);
    s.have_ref = true;
    ESP_LOGI(TAG, "Reference framing taken from this press; all packets below are aligned to it.");
  }
  const float ref_score = align_to_ref_(p.bits);
  // The remote's radio sends each byte LSB first; flip them so values read as plain numbers.
  for (auto &x : p.bits)
    x = rev8_(x);

  const uint8_t b = s.button;
  const uint8_t k = s.n_press[b];
  if (k >= MAX_PRESSES) {
    ESP_LOGW(TAG, "[%s] already %u presses stored - tap BOOT to analyse", BUTTONS[b], MAX_PRESSES);
    return;
  }
  s.presses[b][k] = p;
  s.n_press[b]++;

  char hex[3 * PKT_BYTES + 1], fan[16] = "fan ?";
  hex_(p.bits, PKT_BYTES, hex, sizeof(hex));
  if ((p.bits[FAN_BYTE] & 7) == 6 && (p.bits[FAN_BYTE] >> 3) <= 10)
    snprintf(fan, sizeof(fan), "fan %u%%", (p.bits[FAN_BYTE] >> 3) * 10);
  const bool ok = good_(p);
  ESP_LOGW(TAG, "[%-*s] #%-2u %s | %s | q %u%% %u/%u%s", label_w_(b), BUTTONS[b], k + 1, hex, fan, p.quality,
           p.used, p.total, !ok ? " | LOW QUALITY, not analysed" : ref_score < 0.7f ? " | POOR ALIGNMENT" : "");
  if (!ok)
    return;
  int prev = -1;
  for (int i = k - 1; i >= 0 && prev < 0; i--) {
    if (good_(s.presses[b][i]))
      prev = i;
  }
  if (prev < 0)
    return;
  char line[128];
  size_t off = 0;
  int nchg = 0;
  for (uint8_t i = 0; i < PKT_BYTES; i++) {
    const uint8_t was = s.presses[b][prev].bits[i];
    if (was == p.bits[i])
      continue;
    if (++nchg <= 6)
      off += snprintf(line + off, sizeof(line) - off, "  b%u %02X>%02X", i, was, p.bits[i]);
  }
  if (nchg > 6)
    snprintf(line + off, sizeof(line) - off, "  (+%d more)", nchg - 6);
  ESP_LOGI(TAG, "%*s vs #%d:%s", label_w_(b) + 2, "", prev + 1, nchg ? line : "  identical");
}

inline uint8_t mode_(const uint8_t *v, uint8_t n) {
  uint8_t best = v[0], best_n = 0;
  for (uint8_t i = 0; i < n; i++) {
    uint8_t c = 0;
    for (uint8_t j = 0; j < n; j++)
      c += v[j] == v[i];
    if (c > best_n) {
      best_n = c;
      best = v[i];
    }
  }
  return best;
}

// Most common non-zero press-to-press difference.
inline int8_t common_step_(const uint8_t *v, uint8_t n, uint8_t *count) {
  int8_t best = 0;
  *count = 0;
  for (uint8_t i = 1; i < n; i++) {
    const int8_t d = static_cast<int8_t>(v[i] - v[i - 1]);
    if (d == 0)
      continue;
    uint8_t c = 0;
    for (uint8_t k = 1; k < n; k++)
      c += static_cast<int8_t>(v[k] - v[k - 1]) == d;
    if (c > *count) {
      *count = c;
      best = d;
    }
  }
  return best;
}

// One byte position over consecutive presses: '.' same, 'A' alternates, '+'/'-' steps, '~' irregular.
// Tolerates a few presses hit by radio bit errors (roughly 1 in 5 at q 85-95 %).
inline char classify_(const uint8_t *v, uint8_t n) {
  if (n < 3)
    return ' ';
  const uint8_t slack = n >= 6 ? n / 5 : 0;
  const uint8_t m = mode_(v, n);
  uint8_t same = 0;
  bool near = true;
  for (uint8_t i = 0; i < n; i++) {
    same += v[i] == m;
    if (v[i] != m && __builtin_popcount(v[i] ^ m) > 2)
      near = false;
  }
  if (same == n || (n >= 4 && near && same + std::max<uint8_t>(1, slack) >= n))
    return '.';
  uint8_t alt_bad = 0;
  for (uint8_t k = 2; k < n; k++)
    alt_bad += v[k] != v[k - 2];
  // One corrupted press spoils two comparisons; only forgive that for multi-bit value pairs,
  // since a single flickering bit is the typical radio error.
  const uint8_t alt_slack = __builtin_popcount(v[0] ^ v[1]) > 1 ? 2 * slack : slack;
  if (v[0] != v[1] && alt_bad <= alt_slack)
    return 'A';
  // Equal steps, holding at the limits, with a real net change from first to last press.
  uint8_t good = 0, zero = 0;
  const int8_t step = common_step_(v, n, &good);
  for (uint8_t k = 1; k < n; k++)
    zero += v[k] == v[k - 1];
  const int net = static_cast<int8_t>(v[n - 1] - v[0]);
  if (step != 0 && good >= 3 && (n - 1) - good - zero <= 2 * slack + 1 && net * step > 0 &&
      std::abs(net) >= 2 * std::abs(step))
    return step > 0 ? '+' : '-';
  return '~';
}

// Byte values of the good presses of button b, oldest first.
inline uint8_t good_values_(uint8_t b, uint8_t byte, uint8_t *v) {
  uint8_t n = 0;
  for (uint8_t i = 0; i < s.n_press[b]; i++) {
    if (good_(s.presses[b][i]))
      v[n++] = s.presses[b][i].bits[byte];
  }
  return n;
}

inline void report_button_(uint8_t b) {
  uint8_t v[MAX_PRESSES];
  char pat[PKT_BYTES];
  uint8_t cols[PKT_BYTES], nc = 0, n = 0;
  for (uint8_t i = 0; i < PKT_BYTES; i++) {
    n = good_values_(b, i, v);
    pat[i] = classify_(v, n);
    if (pat[i] != '.' && pat[i] != ' ')
      cols[nc++] = i;
  }
  ESP_LOGI(TAG, "==== [%s] %u presses, %u good ====", BUTTONS[b], s.n_press[b], n);
  if (n < 3) {
    ESP_LOGW(TAG, "  need >= 3 good presses to judge [%s]", BUTTONS[b]);
    return;
  }
  if (nc == 0) {
    ESP_LOGW(TAG, "VERDICT [%s]: SAME CODE on every press -> stateless command, the vent decides what it does",
             BUTTONS[b]);
    return;
  }

  char line[16 + 4 * PKT_BYTES];
  size_t off = snprintf(line, sizeof(line), "  byte  ");
  for (uint8_t c = 0; c < nc; c++)
    off += snprintf(line + off, sizeof(line) - off, "%3u ", cols[c]);
  ESP_LOGI(TAG, "%s", line);
  for (uint8_t i = 0; i < s.n_press[b]; i++) {
    off = snprintf(line, sizeof(line), "  #%-2u%c  ", i + 1, good_(s.presses[b][i]) ? ' ' : '*');
    for (uint8_t c = 0; c < nc; c++)
      off += snprintf(line + off, sizeof(line) - off, " %02X ", s.presses[b][i].bits[cols[c]]);
    ESP_LOGI(TAG, "%s", line);
  }
  off = snprintf(line, sizeof(line), "  type  ");
  for (uint8_t c = 0; c < nc; c++)
    off += snprintf(line + off, sizeof(line) - off, "  %c ", pat[cols[c]]);
  ESP_LOGI(TAG, "%s   (* = low quality, ignored)", line);

  bool alt = false, step = false, irr = false;
  for (uint8_t c = 0; c < nc; c++) {
    const uint8_t i = cols[c];
    n = good_values_(b, i, v);
    if (pat[i] == 'A') {
      alt = true;
      ESP_LOGI(TAG, "  b%-2u alternates %02X / %02X", i, v[0], v[1]);
    } else if (pat[i] == '+' || pat[i] == '-') {
      step = true;
      uint8_t cnt;
      ESP_LOGI(TAG, "  b%-2u steps %+d per press: %02X -> %02X", i, common_step_(v, n, &cnt), v[0], v[n - 1]);
    } else {
      irr = true;
      ESP_LOGI(TAG, "  b%-2u changes without a simple pattern", i);
    }
  }
  if (alt)
    ESP_LOGW(TAG, "VERDICT [%s]: ALTERNATES between two codes -> the remote sends explicit state (e.g. ON/OFF, "
                  "OPEN/STOP)", BUTTONS[b]);
  if (step)
    ESP_LOGW(TAG, "VERDICT [%s]: a byte STEPS each press -> absolute level, or a press counter if it also "
                  "steps for other buttons", BUTTONS[b]);
  if (irr && !alt && !step)
    ESP_LOGW(TAG, "VERDICT [%s]: bytes change without a pattern -> rolling code, or radio noise (check q)",
             BUTTONS[b]);
}

inline void print_table_() {
  ESP_LOGI(TAG, "============ per-button code (most common value per byte, good presses) ============");
  uint8_t first[PKT_BYTES], code[PKT_BYTES], v[MAX_PRESSES];
  bool any = false, differs[PKT_BYTES] = {};
  char hex[3 * PKT_BYTES + 1], pat[3 * PKT_BYTES + 1];
  size_t off = 0;
  for (uint8_t i = 0; i < PKT_BYTES; i++)
    off += snprintf(hex + off, sizeof(hex) - off, "%02u ", i);
  hex[off - 1] = '\0';
  ESP_LOGI(TAG, "%-12s %s", "byte", hex);
  for (uint8_t b = 0; b < NBTN; b++) {
    uint8_t n = 0;
    for (uint8_t i = 0; i < PKT_BYTES; i++) {
      n = good_values_(b, i, v);
      code[i] = n ? mode_(v, n) : 0;
      pat[3 * i] = ' ';
      pat[3 * i + 1] = classify_(v, n);
      pat[3 * i + 2] = ' ';
    }
    if (n == 0)
      continue;
    pat[3 * PKT_BYTES - 1] = '\0';
    if (!any) {
      memcpy(first, code, PKT_BYTES);
      any = true;
    }
    for (uint8_t i = 0; i < PKT_BYTES; i++)
      differs[i] |= code[i] != first[i];
    hex_(code, PKT_BYTES, hex, sizeof(hex));
    ESP_LOGI(TAG, "%-12s %s  (%u good)", BUTTONS[b], hex, n);
    if (n >= 3)
      ESP_LOGI(TAG, "%-12s %s", "", pat);
  }
  if (!any) {
    ESP_LOGI(TAG, "(no good presses yet)");
    return;
  }
  char row[3 * PKT_BYTES + 1];
  for (uint8_t i = 0; i < PKT_BYTES; i++)
    memcpy(row + 3 * i, differs[i] ? "^^ " : ".. ", 3);
  row[3 * PKT_BYTES - 1] = '\0';
  ESP_LOGW(TAG, "%-12s %s", "BUTTON BYTES", row);
  ESP_LOGI(TAG, "^^ = differs between buttons | per button: . same every press, A alternates, +/- steps, ~ irregular");
}

inline void button_tick_(uint32_t now) {
  Packet p;
  while (xQueueReceive(s.queue, &p, 0) == pdTRUE) {
    // A real short packet ends inside the 32-byte capture and the demodulator then reads ~all 1s.
    int ones = 0;
    for (uint8_t i = TAIL_FROM; i < 32; i++)
      ones += __builtin_popcount(p.data[i]);
    if (ones < TAIL_MIN_ONES)
      continue;
    if (s.burst_n < MAX_BURST)
      s.burst[s.burst_n++] = p;
    s.burst_last_ms = now;
  }
  if (s.burst_n && now - s.burst_last_ms > BURST_GAP_MS)
    analyse_press_();
  led_(s.burst_n > 0 || now % 2000 < 100);

  const bool down = gpio_get_level(static_cast<gpio_num_t>(s.boot)) == 0;
  if (down && !s.boot_was_down) {
    s.boot_down_ms = now;
    s.boot_long_done = false;
  }
  if (down && !s.boot_long_done && now - s.boot_down_ms >= BOOT_HOLD_MS) {
    s.boot_long_done = true;
    s.n_press[s.button] = 0;
    ESP_LOGW(TAG, "BOOT held: presses of [%s] cleared - start again", BUTTONS[s.button]);
    prompt_();
  }
  if (!down && s.boot_was_down && !s.boot_long_done && now - s.boot_ms > 300) {
    s.boot_ms = now;
    report_button_(s.button);
    print_table_();
    s.button = (s.button + 1) % NBTN;
    if (s.button == 0)
      ESP_LOGW(TAG, "All %u buttons done - starting over from the first one (results are kept).", NBTN);
    prompt_();
  }
  s.boot_was_down = down;

  if (now - s.last_status_ms >= 15000) {
    s.last_status_ms = now;
    ESP_LOGI(TAG, "waiting for [%s] presses | decoded %u | noise bursts %u | up %us", BUTTONS[s.button],
             s.n_press[s.button], (unsigned) s.noise_bursts, (unsigned) (now / 1000));
  }
}

// --- scan mode -------------------------------------------------------------------

inline void print_spectrum_(const uint16_t *hits, uint32_t sweeps) {
  char line[NCH + 1], ruler[NCH + 1];
  for (uint8_t c = 0; c < NCH; c++) {
    const uint32_t pct = sweeps ? 100UL * hits[c] / sweeps : 0;
    line[c] = hits[c] == 0 ? '.' : pct < 2 ? '-' : pct < 10 ? ':' : pct < 30 ? '+' : '#';
    ruler[c] = (c % 10 == 0) ? static_cast<char>('0' + (c / 10) % 10) : ((c % 5 == 0) ? '+' : '-');
  }
  line[NCH] = ruler[NCH] = '\0';
  ESP_LOGI(TAG, "%s window #%u done, %u sweeps. RPD hits per channel: . none - <2%% : <10%% + <30%% # >=30%%",
           s.press ? "PRESS" : "IDLE", s.press ? s.press_windows + 1 : s.idle_windows + 1, (unsigned) sweeps);
  ESP_LOGI(TAG, "2400 %s %u MHz", ruler, 2400 + NCH - 1);
  ESP_LOGI(TAG, "RF   %s", line);
}

inline void verdict_() {
  if (s.press_windows == 0 || s.idle_sweeps == 0)
    return;
  int best = -1;
  float best_z = 0, best_ex = 0, best_pp = 0, best_pi = 0;
  for (int ch = 0; ch < NCH; ch++) {
    const float pi = (s.idle_hits[ch] + 0.5f) / (s.idle_sweeps + 1.0f);
    const float pp = static_cast<float>(s.press_hits[ch]) / s.press_sweeps;
    const float expected = pi * s.press_sweeps;
    const float ex = s.press_hits[ch] - expected;
    const float z = ex / std::sqrt(expected + 1.0f);
    if (z > 3.0f)
      ESP_LOGI(TAG, "  ch %2d = %u MHz (LT89xx ch %d): pressing %.1f%% vs hands-off %.1f%% of sweeps, z=%.1f", ch,
               2400 + ch, ch - 2, pp * 100, pi * 100, z);
    if (z > best_z) {
      best = ch;
      best_z = z;
      best_ex = ex;
      best_pp = pp;
      best_pi = pi;
    }
  }
  ESP_LOGI(TAG, "Totals: %u PRESS / %u IDLE windows", s.press_windows, s.idle_windows);
  if (s.press_windows >= 2 && best >= 0 && best_ex >= 6 && best_z >= 4 && best_pp >= 3 * best_pi) {
    ESP_LOGW(TAG, "VERDICT: YES - remote-correlated activity on ch %d = %u MHz (z=%.1f); set sniff_ch: \"%d\"", best,
             2400 + best, best_z, best);
  } else if (s.press_windows >= 3) {
    ESP_LOGW(TAG, "VERDICT: NO remote-correlated channel yet (best ch %d, z=%.1f)", best, best_z);
  } else {
    ESP_LOGI(TAG, "VERDICT: not enough data yet - keep going");
  }
}

inline void end_window_() {
  uint16_t hits[NCH];
  const uint32_t sweeps = s.win_sweeps;
  for (uint8_t c = 0; c < NCH; c++)
    hits[c] = s.win_hits[c];
  print_spectrum_(hits, sweeps);
  uint32_t *acc = s.press ? s.press_hits : s.idle_hits;
  for (uint8_t c = 0; c < NCH; c++)
    acc[c] += hits[c];
  if (s.press) {
    s.press_windows++;
    s.press_sweeps += sweeps;
  } else {
    s.idle_windows++;
    s.idle_sweeps += sweeps;
  }
  verdict_();
}

inline void start_window_(bool press, uint32_t now) {
  s.press = press;
  s.countdown_logged = false;
  s.phase_end_ms = now + (press ? PRESS_MS : IDLE_MS);
  s.reset_window = true;
  if (press) {
    ESP_LOGW(TAG, "######## PRESS NOW - %u s, LED solid on ########", (unsigned) (PRESS_MS / 1000));
    ESP_LOGW(TAG, "  remote 10-30 cm from the nRF24 antenna; hold a button ~1 s, release ~1 s, repeat");
  } else {
    ESP_LOGI(TAG, "-------- HANDS OFF - %u s --------", (unsigned) (IDLE_MS / 1000));
  }
}

inline void scan_tick_(uint32_t now) {
  if (!s.started) {
    led_((now / 500) % 2 == 0);
    if (gpio_get_level(static_cast<gpio_num_t>(s.boot)) == 0) {
      s.started = true;
      ESP_LOGW(TAG, "BOOT pressed - schedule started, first PRESS window in %u s", (unsigned) (IDLE_MS / 1000));
      start_window_(false, now);
    } else if (now - s.last_status_ms >= 5000) {
      s.last_status_ms = now;
      ESP_LOGI(TAG, "Waiting: press the ESP BOOT button once when you have the remote in hand | up %us",
               (unsigned) (now / 1000));
    }
    return;
  }

  if (static_cast<int32_t>(now - s.phase_end_ms) >= 0) {
    end_window_();
    start_window_(!s.press, now);
  }

  led_(s.press || now % 1000 < 100);

  const uint32_t left_s = (s.phase_end_ms - now + 999) / 1000;
  if (!s.press && left_s <= 5 && !s.countdown_logged) {
    s.countdown_logged = true;
    ESP_LOGW(TAG, "PRESS window starts in 5 s - pick up the remote");
  }
  if (now - s.last_status_ms >= 5000) {
    s.last_status_ms = now;
    ESP_LOGI(TAG, "[%s] %u s left | %u sweeps (%.0f ms each) | up %us", s.press ? "PRESSING" : "HANDS OFF",
             (unsigned) left_s, (unsigned) s.win_sweeps, s.sweep_us / 1000.0f, (unsigned) (now / 1000));
  }
}

// --- ESPHome entry points -----------------------------------------------------------

inline void begin(int sck, int miso, int mosi, int csn, int ce, int led, int boot, int sniff_ch) {
  s.sck = sck;
  s.miso = miso;
  s.mosi = mosi;
  s.csn = csn;
  s.ce = ce;
  s.led = led;
  s.boot = boot;
  cfg_pin_(sck, true);
  cfg_pin_(mosi, true);
  cfg_pin_(csn, true);
  cfg_pin_(ce, true);
  cfg_pin_(led, true);
  cfg_pin_(miso, false);
  cfg_pin_(boot, false);
  gpio_pullup_en(static_cast<gpio_num_t>(boot));
  lvl_(sck, 0);
  lvl_(mosi, 0);
  lvl_(csn, 1);
  lvl_(ce, 0);
  led_(false);
  esphome::delayMicroseconds(5000);  // power-on reset

  // SETUP_AW is writable, so a read-back proves SPI really works.
  write_reg_(R_SETUP_AW, 0x02);
  const uint8_t aw = read_reg_(R_SETUP_AW);
  write_reg_(R_SETUP_AW, 0x03);
  if (aw != 0x02) {
    ESP_LOGE(TAG, "nRF24 not responding (SETUP_AW read back 0x%02X, expected 0x02).", aw);
    ESP_LOGE(TAG, "Check: VCC on 3.3V (never 5V), 10 uF cap at the module, MISO/MOSI not swapped.");
    return;
  }

  scan_mode_();
  esphome::delayMicroseconds(2000);  // power-up to standby
  s.queue = xQueueCreate(32, sizeof(Packet));
  s.last_status_ms = esphome::millis();
  s.ready = true;

  ESP_LOGI(TAG, "==================================================================");
  if (sniff_ch >= 0 && sniff_ch < NCH) {
    s.button_mode = true;
    s.sniff_ch = sniff_ch;
    s.mode = MODE_SNIFF;
    ESP_LOGI(TAG, " BUTTON mode on %u MHz, 1 Mbps.  Remote 10-30 cm from the nRF24 antenna.", 2400 + sniff_ch);
    ESP_LOGI(TAG, " One line per press: the majority-voted packet, then '^^' under bytes that differ");
    ESP_LOGI(TAG, " from the first press of the same button.  BOOT = next button + comparison table.");
  } else {
    ESP_LOGI(TAG, " SCAN mode 2400-%u MHz.  Press the ESP BOOT button once to start the schedule:", 2400 + NCH - 1);
    ESP_LOGI(TAG, " %u s HANDS OFF (LED blips) / %u s PRESS NOW (LED solid on), repeating",
             (unsigned) (IDLE_MS / 1000), (unsigned) (PRESS_MS / 1000));
  }
  ESP_LOGI(TAG, "==================================================================");
  xTaskCreate(task_, "nrf24", 4096, nullptr, 1, nullptr);
  if (s.button_mode)
    prompt_();
}

inline void tick() {
  const uint32_t now = esphome::millis();
  if (!s.ready) {
    led_((now / 100) % 2 == 0);  // fast blink = hardware fault
    if (now - s.last_status_ms >= 5000) {
      s.last_status_ms = now;
      ESP_LOGE(TAG, "STOPPED: nRF24 not answering on SPI");
    }
    return;
  }
  if (s.button_mode)
    button_tick_(now);
  else
    scan_tick_(now);
}

}  // namespace nrf24
