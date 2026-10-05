#pragma once
/*
 * Passive sniffer for the vent remote's MCU (U1) -> LT8920 (U2) SPI bus, on an ESP32-C2.
 *
 *   PROBE mode: counts edges on the 4 wires to verify CLK / MOSI / SS / PKT wiring.
 *   SPI mode:   SPI slave with MISO disconnected (never drives the remote's bus).  Every SS frame is
 *               decoded as LT8920 register access (datasheet V1.1, LT8920.PDF); consecutive r50 FIFO
 *               writes are joined into one TX packet and diffed against the previous one; PKT flag
 *               edges are logged in line.
 * Wiring and procedure: u1u2-spi-sniffer.yaml.
 */

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "driver/gpio.h"
#include "driver/spi_slave.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "soc/gpio_reg.h"
#include "soc/soc.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace spisniff {

static const char *const TAG = "u1u2";

static constexpr int NSLOT = 8;
static constexpr int FRAME_MAX = 128;  // bytes; multiple of 4 for DMA
static constexpr int SHOW_MAX = 40;    // bytes printed per frame
static constexpr int PKT_MAX = 256;    // LT8920 length byte + up to 255 payload bytes
static constexpr uint32_t QUIET_MS = 300;

enum Kind : uint8_t { SPI_FRAME, PKT_EDGE };

struct Frame {
  uint32_t t_ms;
  uint16_t bits;
  uint8_t kind;
  uint8_t d[FRAME_MAX];  // SPI: MOSI bytes; PKT_EDGE: d[0] = pin level
};

struct State {
  bool spi{false};
  int pins[4]{-1, -1, -1, -1};  // clk, data (MOSI), cs (SS), pkt
  QueueHandle_t q{nullptr};
  uint8_t *buf[NSLOT]{};
  volatile uint32_t edges[4]{}, dropped{0};

  // owned by the ESPHome loop
  uint32_t last_report_ms{0}, last_frame_ms{0}, burst_start_ms{0};
  uint32_t frames{0}, burst_frames{0}, burst_packets{0}, burst_reads{0}, burst_flags{0}, total_packets{0};
  Frame last{};
  bool last_valid{false};
  uint32_t repeat{0};
  bool in_burst{false};
  uint16_t regs[64]{};
  uint64_t seen{0};
  uint16_t cfg_shown[64]{};
  bool cfg_printed{false};
  bool fifo_open{false};
  uint32_t fifo_t{0};
  uint16_t fifo_len{0}, prev_len{0};
  uint8_t fifo[PKT_MAX]{}, prev[PKT_MAX]{};
};

static State s;  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

inline uint16_t bytes_(const Frame &f) { return (f.bits + 7) / 8; }

inline void hex_(const uint8_t *d, int n, char *out, size_t size) {
  size_t off = 0;
  out[0] = '\0';
  for (int i = 0; i < n && off + 4 < size; i++)
    off += snprintf(out + off, size - off, "%02X ", d[i]);
  if (off)
    out[off - 1] = '\0';
}

// --- PROBE mode --------------------------------------------------------------------

inline void probe_task_(void *) {
  uint32_t mask = 0;
  for (int p : s.pins)
    mask |= 1UL << p;
  uint32_t prev = REG_READ(GPIO_IN_REG) & mask;
  for (;;) {
    for (int i = 0; i < 20000; i++) {
      const uint32_t v = REG_READ(GPIO_IN_REG) & mask;
      const uint32_t x = v ^ prev;
      if (x) {
        for (int k = 0; k < 4; k++) {
          if (x & (1UL << s.pins[k]))
            s.edges[k] = s.edges[k] + 1;
        }
        prev = v;
      }
    }
    vTaskDelay(1);  // let the ESPHome loop and the idle task (watchdog) run
  }
}

inline void probe_report_(uint32_t now) {
  uint32_t e[4];
  int lvl[4];
  uint32_t total = 0;
  for (int k = 0; k < 4; k++) {
    e[k] = s.edges[k];
    s.edges[k] = 0;
    lvl[k] = gpio_get_level(static_cast<gpio_num_t>(s.pins[k]));
    total += e[k];
  }
  if (total == 0) {
    if (now - s.last_frame_ms >= 10000) {
      s.last_frame_ms = now;
      ESP_LOGI(TAG, "PROBE: no activity on GPIO%d/%d/%d/%d (now %d%d%d%d) - press a remote button", s.pins[0],
               s.pins[1], s.pins[2], s.pins[3], lvl[0], lvl[1], lvl[2], lvl[3]);
    }
    return;
  }
  s.last_frame_ms = now;
  ESP_LOGI(TAG, "PROBE  GPIO%-2d %s %7u | GPIO%-2d %s %7u | GPIO%-2d %s %7u | GPIO%-2d %s %7u  (level, edges/s)",
           s.pins[0], lvl[0] ? "H" : "L", (unsigned) e[0], s.pins[1], lvl[1] ? "H" : "L", (unsigned) e[1],
           s.pins[2], lvl[2] ? "H" : "L", (unsigned) e[2], s.pins[3], lvl[3] ? "H" : "L", (unsigned) e[3]);
  if (total < 50)
    return;
  // Clock toggles most; chip-select idles high and toggles least; data sits in between.
  int clk = 0, cs = -1, data = -1;
  for (int k = 1; k < 4; k++) {
    if (e[k] > e[clk])
      clk = k;
  }
  for (int k = 0; k < 4; k++) {
    if (k != clk && e[k] > 0 && lvl[k] && (cs < 0 || e[k] < e[cs]))
      cs = k;
  }
  for (int k = 0; k < 4; k++) {
    if (k != clk && k != cs && e[k] > 0 && (data < 0 || e[k] > e[data]))
      data = k;
  }
  ESP_LOGW(TAG, "  => guess: CLK=GPIO%d (idles %s -> spi_mode %s)  CS=%s%d  DATA=%s%d  -> %s", s.pins[clk],
           lvl[clk] ? "high" : "low", lvl[clk] ? "2 or 3, NOT LT8920-like" : "0 or 1, LT8920 = 1", cs >= 0 ? "GPIO" : "?",
           cs >= 0 ? s.pins[cs] : 0, data >= 0 ? "GPIO" : "?", data >= 0 ? s.pins[data] : 0,
           clk == 0 && data == 1 && cs == 2 ? "matches pin_clk/pin_data/pin_cs" : "DIFFERS from pin_clk/pin_data/pin_cs");
}

// --- SPI mode ----------------------------------------------------------------------

inline void spi_task_(void *) {
  static spi_slave_transaction_t tr[NSLOT];
  for (int i = 0; i < NSLOT; i++) {
    tr[i] = {};
    tr[i].length = FRAME_MAX * 8;
    tr[i].rx_buffer = s.buf[i];
    spi_slave_queue_trans(SPI2_HOST, &tr[i], portMAX_DELAY);
  }
  Frame f;
  for (;;) {
    spi_slave_transaction_t *r = nullptr;
    if (spi_slave_get_trans_result(SPI2_HOST, &r, portMAX_DELAY) != ESP_OK || r == nullptr)
      continue;
    f.t_ms = static_cast<uint32_t>(esp_timer_get_time() / 1000);
    f.kind = SPI_FRAME;
    f.bits = static_cast<uint16_t>(std::min<size_t>(r->trans_len, FRAME_MAX * 8));
    memcpy(f.d, r->rx_buffer, bytes_(f));
    if (xQueueSend(s.q, &f, 0) != pdTRUE)
      s.dropped = s.dropped + 1;
    r->length = FRAME_MAX * 8;
    spi_slave_queue_trans(SPI2_HOST, r, portMAX_DELAY);
  }
}

static void IRAM_ATTR pkt_isr_(void *) {
  static Frame f;
  f.t_ms = static_cast<uint32_t>(esp_timer_get_time() / 1000);
  f.kind = PKT_EDGE;
  f.bits = 0;
  f.d[0] = (REG_READ(GPIO_IN_REG) >> s.pins[3]) & 1;
  BaseType_t woken = pdFALSE;
  if (xQueueSendFromISR(s.q, &f, &woken) != pdTRUE)
    s.dropped = s.dropped + 1;
  if (woken == pdTRUE)
    portYIELD_FROM_ISR();
}

// --- LT8920 register decoding (datasheet V1.1 ch. 9) -----------------------------------

// Power-up reset values (datasheet table 32) so a config decodes before U1 writes every register.
inline void init_regs_() {
  static const struct {
    uint8_t a;
    uint16_t v;
  } RESET[] = {{7, 0x0030},  {9, 0x3000},  {32, 0x1806}, {35, 0x1300}, {40, 0x2107},
               {41, 0xB800}, {42, 0xFD6B}, {44, 0x0100}, {45, 0x0080}};
  for (const auto &r : RESET)
    s.regs[r.a] = r.v;
}

inline const char *on_(uint16_t v, uint16_t bit) { return (v & bit) ? "on" : "off"; }

inline const char *rate_(uint16_t r44) {
  switch (r44 >> 8) {
    case 0x01:
      return "1 Mbps";
    case 0x04:
      return "250 kbps";
    case 0x08:
      return "125 kbps";
    case 0x10:
      return "62.5 kbps";
    default:
      return "unknown data rate";
  }
}

// r32[12:11] selects 16/32/48/64-bit sync word built from r36..r39 (r36 LSB goes on air first).
inline void sync_word_(char *out, size_t size) {
  static const uint8_t ORDER[4][4] = {{36}, {39, 36}, {39, 38, 36}, {39, 38, 37, 36}};
  const int idx = (s.regs[32] >> 11) & 3;
  size_t off = 0;
  for (int i = 0; i <= idx; i++)
    off += snprintf(out + off, size - off, "r%u ", ORDER[idx][i]);
  off += snprintf(out + off, size - off, "=");
  for (int i = 0; i <= idx; i++)
    off += snprintf(out + off, size - off, " %04X", s.regs[ORDER[idx][i]]);
  snprintf(out + off, size - off, "  (%d bit, r36 LSB first on air)", 16 * (idx + 1));
}

inline void reg_note_(uint8_t a, uint16_t v, char *out, size_t size) {
  static const char *const CODING[] = {"NRZ", "Manchester", "8b/10b", "interleave"};
  static const char *const FEC[] = {"no FEC", "FEC 1/3", "FEC 2/3", "FEC ?"};
  char t[128] = "";
  switch (a) {
    case 7:
      snprintf(t, sizeof(t), "%s ch %u = %u MHz", v & 0x100 ? "TX_EN" : v & 0x80 ? "RX_EN" : "TX/RX off", v & 0x7F,
               2402 + (v & 0x7F));
      break;
    case 9:
      snprintf(t, sizeof(t), "TX power: PA current %u, gain %u", v >> 12, (v >> 7) & 0xF);
      break;
    case 23:
      snprintf(t, sizeof(t), "VCO calibration before each TX/RX %s", on_(v, 0x4));
      break;
    case 27:
      snprintf(t, sizeof(t), "crystal trim %u", v & 0x3F);
      break;
    case 32:
      snprintf(t, sizeof(t), "preamble %u B, sync %u bit, trailer %u bit, %s, %s", (v >> 13) + 1,
               16 * (((v >> 11) & 3) + 1), ((v >> 8) & 7) * 2 + 4, CODING[(v >> 6) & 3], FEC[(v >> 4) & 3]);
      break;
    case 33:
      snprintf(t, sizeof(t), "VCO on delay %u us, PA on delay %u us", v >> 8, v & 0x3F);
      break;
    case 35:
      snprintf(t, sizeof(t), "%sauto-ack retries %u, whitening seed %02X",
               v & 0x8000   ? "POWER DOWN, "
               : v & 0x4000 ? "SLEEP (wakes on SS low), "
                            : "",
               (v >> 8) & 0xF, v & 0x7F);
      break;
    case 36:
    case 37:
    case 38:
    case 39:
      snprintf(t, sizeof(t), "SYNC WORD [%u:%u]", (a - 36) * 16 + 15, (a - 36) * 16);
      break;
    case 40:
      snprintf(t, sizeof(t), "FIFO empty/full thr %u/%u, sync bit errors allowed %d", v >> 11, (v >> 6) & 0x1F,
               static_cast<int>(v & 0x3F) - 1);
      break;
    case 41:
      snprintf(t, sizeof(t), "CRC %s, scramble %s, length byte %s, FIFO-empty ends TX %s, auto-ack %s, flags active-%s, "
               "CRC seed %02X",
               on_(v, 0x8000), on_(v, 0x4000), on_(v, 0x2000), on_(v, 0x1000), on_(v, 0x800),
               v & 0x400 ? "low" : "high", v & 0xFF);
      break;
    case 42:
      snprintf(t, sizeof(t), "wait for ACK %u us", v & 0xFF);
      break;
    case 43:
      snprintf(t, sizeof(t), "RSSI scan %s", on_(v, 0x8000));
      break;
    case 44:
      snprintf(t, sizeof(t), "data rate %s", rate_(v));
      break;
    case 45:
      snprintf(t, sizeof(t), "modem option (0080/0152 = 1 Mbps, 0552 = slower)");
      break;
    case 52:
      snprintf(t, sizeof(t), "%s%s", v & 0x8000 ? "clear TX FIFO ptr " : "", v & 0x80 ? "clear RX FIFO ptr" : "");
      break;
    default:
      break;
  }
  snprintf(out, size, "r%u=%04X %s", a, v, t);
}

inline void read_note_(uint8_t a, uint16_t n, char *out, size_t size) {
  if (a == 50) {
    snprintf(out, size, "FIFO READ %u B = remote RECEIVED a packet (MISO)", n - 1);
    return;
  }
  const char *what = "";
  switch (a) {
    case 3:
      what = "(synth lock)";
      break;
    case 6:
      what = "(RSSI)";
      break;
    case 29:
    case 30:
    case 31:
      what = "(chip ID)";
      break;
    case 48:
      what = "(status: CRC err/sync/PKT/FIFO)";
      break;
    case 52:
      what = "(FIFO ptrs = auto-ack result)";
      break;
    default:
      break;
  }
  const unsigned words = n > 1 ? (n - 1) / 2 : 0;
  if (words > 1)
    snprintf(out, size, "read r%u..r%u %s", a, a + words - 1, what);
  else
    snprintf(out, size, "read r%u %s", a, what);
}

inline uint16_t word_(const Frame &f, int i) { return (f.d[1 + 2 * i] << 8) | f.d[2 + 2 * i]; }

// --- frame stream -------------------------------------------------------------------------

inline void flush_repeat_() {
  if (s.repeat)
    ESP_LOGI(TAG, "          (same frame x%u more)", (unsigned) s.repeat);
  s.repeat = 0;
}

// Consecutive r50 writes = one TX packet (FIFO bytes may be split over several SS frames).
inline void end_fifo_() {
  if (!s.fifo_open)
    return;
  s.fifo_open = false;
  flush_repeat_();
  s.last_valid = false;
  s.burst_packets++;
  s.total_packets++;
  const uint16_t len = s.fifo_len;
  const unsigned ch = s.regs[7] & 0x7F;
  ESP_LOGW(TAG, "+%4u ms  TX PACKET %u B  (last r7: ch %u = %u MHz, %s)", (unsigned) s.fifo_t, len, ch, 2402 + ch,
           rate_(s.regs[44]));
  char hex[3 * SHOW_MAX + 1];
  const int shown = std::min<int>(len, SHOW_MAX);
  hex_(s.fifo, shown, hex, sizeof(hex));
  ESP_LOGW(TAG, "          %s%s", hex, len > SHOW_MAX ? " ..." : "");
  if (s.prev_len) {
    char diff[3 * SHOW_MAX + 1] = "";
    for (int i = 0; i < shown; i++)
      memcpy(diff + 3 * i, (i < s.prev_len && s.fifo[i] == s.prev[i]) ? ".. " : "^^ ", 3);
    diff[shown ? 3 * shown - 1 : 0] = '\0';
    ESP_LOGI(TAG, "          %s  (^^ = differs from previous packet)", diff);
  }
  if ((s.regs[41] & 0x2000) && len)
    ESP_LOGI(TAG, "          byte 0 = length byte %u -> %s", s.fifo[0],
             s.fifo[0] + 1 == len ? "matches" : "does NOT match the FIFO byte count");
  memcpy(s.prev, s.fifo, len);
  s.prev_len = len;
}

inline void pkt_edge_(const Frame &f, uint32_t t) {
  end_fifo_();
  flush_repeat_();
  s.last_valid = false;
  const bool active_low = s.regs[41] & 0x400;
  if ((f.d[0] != 0) == active_low)
    return;  // flag went inactive
  s.burst_flags++;
  const uint16_t r7 = s.regs[7];
  ESP_LOGI(TAG, "+%4u ms  PKT flag active: %s", (unsigned) t,
           r7 & 0x100  ? "TX packet sent"
           : r7 & 0x80 ? "RX sync/packet received"
                       : "(TX/RX off)");
}

inline void print_config_() {
  static const uint8_t CFG[] = {7, 44, 45, 32, 36, 37, 38, 39, 41, 35, 40, 9};
  uint64_t mask = 0;
  bool changed = !s.cfg_printed;
  for (uint8_t a : CFG) {
    mask |= 1ULL << a;
    changed |= s.regs[a] != s.cfg_shown[a];
  }
  if (!(s.seen & mask) || !changed)
    return;
  s.cfg_printed = true;
  for (uint8_t a : CFG)
    s.cfg_shown[a] = s.regs[a];

  char line[192];
  ESP_LOGW(TAG, "LT8920 CONFIG  (* = never written by U1, power-up default)");
  for (uint8_t a : CFG) {
    if (a >= 37 && a <= 39)
      continue;
    const bool def = !(s.seen >> a & 1);
    if (a == 36) {
      sync_word_(line, sizeof(line));
      ESP_LOGW(TAG, "  %s SYNC WORD %s", (s.seen >> 36 & 0xF) ? " " : "*", line);
      continue;
    }
    reg_note_(a, s.regs[a], line, sizeof(line));
    ESP_LOGW(TAG, "  %s %s", def ? "*" : " ", line);
  }
  size_t off = 0;
  char list[64 * 4 + 1] = "";
  for (int a = 0; a < 64; a++) {
    if (s.seen >> a & 1)
      off += snprintf(list + off, sizeof(list) - off, "r%d ", a);
  }
  ESP_LOGI(TAG, "  registers written so far: %s", list);
}

inline void end_burst_() {
  end_fifo_();
  flush_repeat_();
  ESP_LOGI(TAG, "---- quiet: %u frames, %u TX packets, %u FIFO reads, %u PKT flags ----", (unsigned) s.burst_frames,
           (unsigned) s.burst_packets, (unsigned) s.burst_reads, (unsigned) s.burst_flags);
  print_config_();
  s.in_burst = false;
}

inline void handle_frame_(const Frame &f) {
  s.frames++;
  if (!s.in_burst) {
    s.in_burst = true;
    s.burst_start_ms = f.t_ms;
    s.burst_frames = s.burst_packets = s.burst_reads = s.burst_flags = 0;
    s.last_valid = false;
    ESP_LOGI(TAG, "---- activity ----");
  }
  s.burst_frames++;
  s.last_frame_ms = f.t_ms;
  const uint32_t t = f.t_ms - s.burst_start_ms;
  if (f.kind == PKT_EDGE) {
    pkt_edge_(f, t);
    return;
  }

  const uint16_t n = bytes_(f);
  if (n > 0 && f.d[0] == 50) {  // write to r50 = TX FIFO
    if (!s.fifo_open) {
      s.fifo_open = true;
      s.fifo_len = 0;
      s.fifo_t = t;
    }
    for (uint16_t i = 1; i < n && s.fifo_len < PKT_MAX; i++)
      s.fifo[s.fifo_len++] = f.d[i];
    return;
  }
  end_fifo_();
  if (n > 0 && f.d[0] == (0x80 | 50))
    s.burst_reads++;

  if (s.last_valid && f.bits == s.last.bits && memcmp(f.d, s.last.d, n) == 0) {
    s.repeat++;
    return;
  }
  flush_repeat_();
  s.last = f;
  s.last_valid = true;

  if (n == 0) {
    ESP_LOGI(TAG, "+%4u ms  SS pulse without clock (wake-up from SLEEP)", (unsigned) t);
    return;
  }
  char hex[3 * SHOW_MAX + 1], note[192];
  hex_(f.d, std::min<int>(n, SHOW_MAX), hex, sizeof(hex));
  const char *more = n > SHOW_MAX ? " ..." : "";
  const char *partial = f.bits % 8 ? "  (partial byte: check wiring / spi_mode)" : "";
  const uint8_t a = f.d[0] & 0x7F;
  if (f.d[0] & 0x80) {
    read_note_(a, n, note, sizeof(note));
    ESP_LOGI(TAG, "+%4u ms  %-50s %s%s%s", (unsigned) t, note, hex, more, partial);
    return;
  }
  const int words = (n - 1) / 2;
  if (words == 0 || (n - 1) % 2) {
    ESP_LOGI(TAG, "+%4u ms  write r%u, %u B (not whole 16-bit words)  %s%s%s", (unsigned) t, a, n - 1, hex, more,
             partial);
    return;
  }
  for (int i = 0; i < words; i++) {
    if (a + i < 64) {
      s.regs[a + i] = word_(f, i);
      s.seen |= 1ULL << (a + i);
    }
  }
  if (words == 1) {
    reg_note_(a, word_(f, 0), note, sizeof(note));
    ESP_LOGI(TAG, "+%4u ms  %-50s %s%s", (unsigned) t, note, hex, partial);
    return;
  }
  ESP_LOGI(TAG, "+%4u ms  write r%u..r%u (auto-increment)  %s%s%s", (unsigned) t, a, a + words - 1, hex, more, partial);
  for (int i = 0; i < words; i++) {
    reg_note_(a + i, word_(f, i), note, sizeof(note));
    ESP_LOGI(TAG, "            %s", note);
  }
}

// --- ESPHome entry points ------------------------------------------------------------

inline void begin(bool spi, int clk, int data, int cs, int pkt, int mode) {
  s.spi = spi;
  s.pins[0] = clk;
  s.pins[1] = data;
  s.pins[2] = cs;
  s.pins[3] = pkt;
  ESP_LOGI(TAG, "==================================================================");
  if (!spi) {
    if (clk < 0 || data < 0 || cs < 0 || pkt < 0) {
      ESP_LOGE(TAG, " PROBE mode needs all 4 pins (pin_pkt is %d)", pkt);
      return;
    }
    for (int p : s.pins) {
      gpio_config_t c = {};
      c.pin_bit_mask = 1ULL << p;
      c.mode = GPIO_MODE_INPUT;
      c.pull_down_en = GPIO_PULLDOWN_ENABLE;  // unconnected probes read 0 instead of floating
      gpio_config(&c);
    }
    ESP_LOGI(TAG, " PROBE mode on GPIO%d, %d, %d, %d.  Press remote buttons; the log shows each", clk, data, cs,
             pkt);
    ESP_LOGI(TAG, " wire's idle level and edges per second plus a CLK/CS/DATA guess.");
    ESP_LOGI(TAG, "==================================================================");
    xTaskCreate(probe_task_, "probe", 3072, nullptr, 1, nullptr);
    return;
  }

  init_regs_();
  s.q = xQueueCreate(64, sizeof(Frame));
  spi_bus_config_t bus = {};
  bus.mosi_io_num = data;
  bus.miso_io_num = -1;  // never drive the remote's bus
  bus.sclk_io_num = clk;
  bus.quadwp_io_num = -1;
  bus.quadhd_io_num = -1;
  bus.max_transfer_sz = FRAME_MAX;
  spi_slave_interface_config_t slv = {};
  slv.spics_io_num = cs;
  slv.mode = static_cast<uint8_t>(mode);
  slv.queue_size = NSLOT;
  const esp_err_t err = spi_slave_initialize(SPI2_HOST, &bus, &slv, SPI_DMA_CH_AUTO);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "spi_slave_initialize failed: %s", esp_err_to_name(err));
    return;
  }
  for (auto &b : s.buf)
    b = static_cast<uint8_t *>(heap_caps_calloc(1, FRAME_MAX, MALLOC_CAP_DMA));
  if (pkt >= 0) {
    gpio_config_t c = {};
    c.pin_bit_mask = 1ULL << pkt;
    c.mode = GPIO_MODE_INPUT;
    c.pull_down_en = GPIO_PULLDOWN_ENABLE;
    c.intr_type = GPIO_INTR_ANYEDGE;
    gpio_config(&c);
    const esp_err_t e = gpio_install_isr_service(0);
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE)  // INVALID_STATE = already installed
      ESP_LOGE(TAG, "gpio_install_isr_service failed: %s", esp_err_to_name(e));
    else
      gpio_isr_handler_add(static_cast<gpio_num_t>(pkt), pkt_isr_, nullptr);
  }
  ESP_LOGI(TAG, " LT8920 SPI sniffer: CLK=GPIO%d MOSI=GPIO%d SS=GPIO%d PKT=GPIO%d, SPI mode %d, listen-only.", clk,
           data, cs, pkt, mode);
  ESP_LOGI(TAG, " One line per SS frame; identical repeats are folded.  [W] lines = TX packets / config.");
  ESP_LOGI(TAG, " Take a remote battery out and back in to capture its start-up config (sync word).");
  ESP_LOGI(TAG, "==================================================================");
  xTaskCreate(spi_task_, "spisniff", 4096, nullptr, 5, nullptr);
}

inline void tick() {
  const uint32_t now = static_cast<uint32_t>(esp_timer_get_time() / 1000);
  if (!s.spi) {
    if (now - s.last_report_ms >= 1000) {
      s.last_report_ms = now;
      probe_report_(now);
    }
    return;
  }
  if (s.q == nullptr)
    return;
  Frame f;
  while (xQueueReceive(s.q, &f, 0) == pdTRUE)
    handle_frame_(f);
  if (s.in_burst && now - s.last_frame_ms > QUIET_MS)
    end_burst_();
  if (now - s.last_report_ms >= 30000) {
    s.last_report_ms = now;
    ESP_LOGI(TAG, "listening | frames %u | TX packets %u | dropped %u | up %us", (unsigned) s.frames,
             (unsigned) s.total_packets, (unsigned) s.dropped, (unsigned) (now / 1000));
  }
}

}  // namespace spisniff
