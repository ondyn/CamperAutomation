#pragma once
/*
 * CC1101 RSSI scanner: does the roof-vent remote transmit anywhere in 862-871 MHz?
 *
 * The sweep runs in its own FreeRTOS task so it never blocks the ESPHome loop.  The loop
 * side runs a fixed hands-off / press schedule, drives the LED cue, prints one line per
 * RF burst and a verdict comparing PRESS windows against IDLE windows.
 * Wiring and procedure: vent-868-sniffer.yaml.
 *
 * Bit-banged SPI (same pins as nrf24_scanner.h): only ~14 bytes are exchanged per hop.
 */

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"

namespace rf868 {

static const char *const TAG = "rf868";

// 46 channels 862.0..871.0 MHz, 199.95 kHz apart, 325 kHz RX filter each: every
// frequency in the range falls inside at least one channel's passband.
static constexpr double XOSC_HZ = 26e6;
static constexpr double BASE_HZ = 862.0e6;
static constexpr uint8_t NCH = 46;
static constexpr uint32_t CH_STEP = 504;  // (256 + CHANSPC_M) * 2^(CHANSPC_E - 2) in FREQ units

static constexpr uint16_t DWELL_US = 300;  // ~90 us PLL settle + AGC/RSSI settle at 325 kHz BW
static constexpr float HIT_DB = 12.0f;     // burst threshold above the per-channel floor
static constexpr uint32_t BURST_GAP_MS = 200;
static constexpr uint32_t BURST_MAX_MS = 3000;

static constexpr uint32_t LEARN_MS = 15000;
static constexpr uint32_t IDLE_MS = 20000;
static constexpr uint32_t PRESS_MS = 20000;

static constexpr uint8_t S_SRES = 0x30, S_SCAL = 0x33, S_SRX = 0x34, S_SIDLE = 0x36;
static constexpr uint8_t R_CHANNR = 0x0A, R_FREQ2 = 0x0D, R_MDMCFG4 = 0x10, R_FSCAL3 = 0x23;
static constexpr uint8_t ST_PARTNUM = 0x30, ST_VERSION = 0x31, ST_RSSI = 0x34, ST_MARCSTATE = 0x35;
static constexpr uint8_t MS_IDLE = 0x01, MS_RX = 0x0D;

// 868 MHz OOK RX in asynchronous serial mode: no FIFO, so an RX overflow can never freeze
// RSSI updates.  FS_AUTOCAL is off because every channel is calibrated once at boot.
static const uint8_t CONFIG[][2] = {
    {0x00, 0x2E},  // IOCFG2   GDO2 hi-Z
    {0x01, 0x2E},  // IOCFG1   GDO1 hi-Z
    {0x02, 0x2E},  // IOCFG0   GDO0 hi-Z (reset default is a 135 kHz clock output)
    {0x03, 0x47},  // FIFOTHR
    {0x07, 0x00},  // PKTCTRL1
    {0x08, 0x32},  // PKTCTRL0 async serial, infinite length
    {0x0A, 0x00},  // CHANNR
    {0x0B, 0x08},  // FSCTRL1  IF 203 kHz
    {0x0C, 0x00},  // FSCTRL0
    {0x10, 0x58},  // MDMCFG4  RX BW 325 kHz
    {0x11, 0x93},  // MDMCFG3
    {0x12, 0x30},  // MDMCFG2  ASK/OOK, no sync word
    {0x13, 0x22},  // MDMCFG1  CHANSPC_E=2
    {0x14, 0xF8},  // MDMCFG0  CHANSPC_M=248 -> 199.95 kHz
    {0x15, 0x15},  // DEVIATN
    {0x16, 0x07},  // MCSM2
    {0x17, 0x30},  // MCSM1
    {0x18, 0x08},  // MCSM0    FS_AUTOCAL never
    {0x19, 0x16},  // FOCCFG
    {0x1A, 0x6C},  // BSCFG
    {0x1B, 0x03},  // AGCCTRL2
    {0x1C, 0x00},  // AGCCTRL1
    {0x1D, 0x91},  // AGCCTRL0
    {0x21, 0x56},  // FREND1
    {0x22, 0x11},  // FREND0
    {0x23, 0xE9},  // FSCAL3
    {0x24, 0x2A},  // FSCAL2
    {0x25, 0x00},  // FSCAL1
    {0x26, 0x1F},  // FSCAL0
    {0x2C, 0x81},  // TEST2
    {0x2D, 0x35},  // TEST1
    {0x2E, 0x09},  // TEST0
};

enum Phase : uint8_t { PH_LEARN, PH_IDLE, PH_PRESS };

struct Burst {
  uint32_t start_ms{0}, end_ms{0};
  uint16_t sweeps{0};
  uint8_t lo{0}, hi{0}, peak{0}, phase{0};
  float peak_dbm{0}, peak_excess{0};
};

struct State {
  int sck{-1}, miso{-1}, mosi{-1}, csn{-1}, led{-1};
  bool ready{false};
  const char *fault{"not started"};
  uint32_t freq0{0};
  uint8_t fscal[NCH][3]{};
  float floor_dbm[NCH]{};
  float hold_dbm[NCH]{};
  float rssi_min{1000.0f}, rssi_max{-1000.0f};
  QueueHandle_t queue{nullptr};

  // shared with the scan task
  volatile uint8_t phase{PH_LEARN};
  volatile bool reset_hold{false};
  volatile uint32_t sweeps{0}, sweep_us{0}, dropped{0};

  // owned by the ESPHome loop
  uint32_t phase_end_ms{0}, last_status_ms{0}, last_status_sweeps{0};
  uint16_t win_bursts{0};
  uint16_t press_windows{0}, idle_windows{0}, press_windows_hit{0}, idle_windows_hit{0};
  uint16_t press_by_ch[NCH]{}, idle_by_ch[NCH]{};
  bool countdown_logged{false};
};

static State s;  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// --- bit-banged SPI mode 0, MSB first --------------------------------------

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
inline int miso_() { return gpio_get_level(static_cast<gpio_num_t>(s.miso)); }

inline uint8_t xfer_(uint8_t out) {
  uint8_t in = 0;
  for (int i = 7; i >= 0; i--) {
    lvl_(s.mosi, (out >> i) & 1);
    lvl_(s.sck, 1);
    in = static_cast<uint8_t>((in << 1) | miso_());
    lvl_(s.sck, 0);
  }
  return in;
}

// SO doubles as CHIP_RDYn: it goes low once the crystal is running and the chip can talk.
inline bool wait_miso_low_(uint32_t timeout_us) {
  const uint32_t t0 = esphome::micros();
  while (miso_()) {
    if (esphome::micros() - t0 > timeout_us)
      return false;
  }
  return true;
}

inline void select_() {
  lvl_(s.csn, 0);
  wait_miso_low_(1000);
}

inline void deselect_() { lvl_(s.csn, 1); }

inline void strobe_(uint8_t cmd) {
  select_();
  xfer_(cmd);
  deselect_();
}

inline void write_reg_(uint8_t addr, uint8_t value) {
  select_();
  xfer_(addr);
  xfer_(value);
  deselect_();
}

inline void write_burst_(uint8_t addr, const uint8_t *buf, uint8_t len) {
  select_();
  xfer_(0x40 | addr);
  for (uint8_t i = 0; i < len; i++)
    xfer_(buf[i]);
  deselect_();
}

inline uint8_t read_raw_(uint8_t header) {
  select_();
  xfer_(header);
  const uint8_t v = xfer_(0x00);
  deselect_();
  return v;
}

inline uint8_t read_reg_(uint8_t addr) { return read_raw_(0x80 | addr); }

// Status registers need the burst bit, and (errata) can be torn while they change: read until stable.
inline uint8_t read_status_(uint8_t addr) {
  uint8_t prev = read_raw_(0xC0 | addr);
  for (int i = 0; i < 4; i++) {
    const uint8_t cur = read_raw_(0xC0 | addr);
    if (cur == prev)
      return cur;
    prev = cur;
  }
  return prev;
}

inline bool wait_state_(uint8_t want, uint32_t timeout_us) {
  const uint32_t t0 = esphome::micros();
  while ((read_status_(ST_MARCSTATE) & 0x1F) != want) {
    if (esphome::micros() - t0 > timeout_us)
      return false;
  }
  return true;
}

inline float rssi_dbm_(uint8_t raw) { return static_cast<int8_t>(raw) / 2.0f - 74.0f; }

inline double freq_mhz_(uint8_t ch) { return (s.freq0 + ch * CH_STEP) * XOSC_HZ / 65536.0 / 1e6; }

inline void led_(bool on) {
  if (s.led >= 0)
    lvl_(s.led, on ? 0 : 1);  // Super Mini LED is active-low
}

// Datasheet 19.1.2 manual power-on reset sequence.
inline void reset_() {
  lvl_(s.sck, 1);
  lvl_(s.mosi, 0);
  lvl_(s.csn, 0);
  esphome::delayMicroseconds(5);
  lvl_(s.csn, 1);
  esphome::delayMicroseconds(50);
  lvl_(s.sck, 0);
  lvl_(s.csn, 0);
  wait_miso_low_(10000);
  xfer_(S_SRES);
  esphome::delayMicroseconds(100);
  wait_miso_low_(10000);
  lvl_(s.csn, 1);
}

// --- scan task ---------------------------------------------------------------

inline float measure_(uint8_t ch) {
  strobe_(S_SIDLE);
  wait_state_(MS_IDLE, 1000);
  write_burst_(R_FSCAL3, s.fscal[ch], 3);
  write_reg_(R_CHANNR, ch);
  strobe_(S_SRX);
  esphome::delayMicroseconds(DWELL_US);
  return rssi_dbm_(read_status_(ST_RSSI));
}

inline void process_sweep_(const float *rssi, uint32_t now) {
  static bool floor_init = false;
  static bool open = false;
  static Burst cur;
  static uint32_t last_hit_ms = 0;

  const uint8_t phase = s.phase;
  if (s.reset_hold) {
    for (auto &h : s.hold_dbm)
      h = -200.0f;
    s.reset_hold = false;
  }

  bool hit = false;
  uint8_t lo = 0, hi = 0, peak = 0;
  float peak_ex = -1000.0f;
  for (uint8_t ch = 0; ch < NCH; ch++) {
    const float r = rssi[ch];
    if (!floor_init)
      s.floor_dbm[ch] = r;
    if (r > s.hold_dbm[ch])
      s.hold_dbm[ch] = r;
    if (r < s.rssi_min)
      s.rssi_min = r;
    if (r > s.rssi_max)
      s.rssi_max = r;
    const float ex = r - s.floor_dbm[ch];
    if (phase == PH_LEARN) {
      s.floor_dbm[ch] += 0.1f * ex;
      continue;
    }
    // A hit barely moves the floor, so holding a remote button is not absorbed into it.
    s.floor_dbm[ch] += (ex < HIT_DB ? 0.01f : 0.002f) * ex;
    if (ex < HIT_DB)
      continue;
    if (!hit)
      lo = ch;
    hi = ch;
    hit = true;
    if (ex > peak_ex) {
      peak_ex = ex;
      peak = ch;
    }
  }
  floor_init = true;

  if (hit) {
    if (!open) {
      cur = Burst{};
      cur.start_ms = now;
      cur.phase = phase;
      cur.lo = lo;
      cur.hi = hi;
      cur.peak_excess = -1000.0f;
      open = true;
    }
    cur.sweeps++;
    if (lo < cur.lo)
      cur.lo = lo;
    if (hi > cur.hi)
      cur.hi = hi;
    if (peak_ex > cur.peak_excess) {
      cur.peak_excess = peak_ex;
      cur.peak = peak;
      cur.peak_dbm = rssi[peak];
    }
    last_hit_ms = now;
  }
  if (open && (now - last_hit_ms > BURST_GAP_MS || now - cur.start_ms > BURST_MAX_MS)) {
    cur.end_ms = last_hit_ms;
    if (xQueueSend(s.queue, &cur, 0) != pdTRUE)
      s.dropped = s.dropped + 1;
    open = false;
  }
}

inline void scan_task_(void *) {
  float rssi[NCH];
  for (;;) {
    const uint32_t t0 = esphome::micros();
    for (uint8_t ch = 0; ch < NCH; ch++)
      rssi[ch] = measure_(ch);
    s.sweep_us = esphome::micros() - t0;
    process_sweep_(rssi, esphome::millis());
    s.sweeps = s.sweeps + 1;
    vTaskDelay(1);  // let the ESPHome loop and the idle task (watchdog) run
  }
}

// --- ESPHome loop side -------------------------------------------------------

inline void fail_(const char *why) {
  s.ready = false;
  s.fault = why;
  ESP_LOGE(TAG, "%s", why);
}

inline void begin(int sck, int miso, int mosi, int csn, int led) {
  s.sck = sck;
  s.miso = miso;
  s.mosi = mosi;
  s.csn = csn;
  s.led = led;
  cfg_pin_(sck, true);
  cfg_pin_(mosi, true);
  cfg_pin_(csn, true);
  cfg_pin_(miso, false);
  cfg_pin_(led, true);
  lvl_(csn, 1);
  lvl_(sck, 0);
  led_(false);

  reset_();
  const uint8_t part = read_status_(ST_PARTNUM);
  const uint8_t ver = read_status_(ST_VERSION);
  ESP_LOGI(TAG, "CC1101 PARTNUM=0x%02X VERSION=0x%02X (expect 0x00 and 0x14/0x04/0x17)", part, ver);
  if (part != 0x00 || ver == 0x00 || ver == 0xFF) {
    fail_("CC1101 not answering on SPI - check 3V3/GND, CSN=GPIO7, SCK=GPIO4, MOSI=GPIO6, MISO=GPIO5");
    return;
  }

  for (const auto &r : CONFIG)
    write_reg_(r[0], r[1]);
  s.freq0 = static_cast<uint32_t>(std::llround(BASE_HZ * 65536.0 / XOSC_HZ));
  write_reg_(R_FREQ2, (s.freq0 >> 16) & 0xFF);
  write_reg_(R_FREQ2 + 1, (s.freq0 >> 8) & 0xFF);
  write_reg_(R_FREQ2 + 2, s.freq0 & 0xFF);
  if (read_reg_(R_MDMCFG4) != 0x58 || read_reg_(R_FREQ2) != ((s.freq0 >> 16) & 0xFF)) {
    fail_("CC1101 register write/readback mismatch - SPI is unreliable (MOSI wiring or long wires)");
    return;
  }

  uint8_t cal_min = 0xFF, cal_max = 0;
  for (uint8_t ch = 0; ch < NCH; ch++) {
    write_reg_(R_CHANNR, ch);
    strobe_(S_SCAL);
    esphome::delayMicroseconds(20);
    if (!wait_state_(MS_IDLE, 5000)) {
      fail_("CC1101 frequency synthesizer calibration timed out");
      return;
    }
    for (uint8_t i = 0; i < 3; i++)
      s.fscal[ch][i] = read_reg_(R_FSCAL3 + i);
    cal_min = std::min(cal_min, s.fscal[ch][2]);
    cal_max = std::max(cal_max, s.fscal[ch][2]);
  }
  ESP_LOGI(TAG, "Calibrated %u channels %.2f-%.2f MHz, FSCAL1 0x%02X..0x%02X", (unsigned) NCH, freq_mhz_(0),
           freq_mhz_(NCH - 1), cal_min, cal_max);

  measure_(0);
  const uint8_t st = read_status_(ST_MARCSTATE) & 0x1F;
  if (st != MS_RX) {
    ESP_LOGE(TAG, "MARCSTATE=0x%02X after SRX", st);
    fail_("CC1101 did not enter RX");
    return;
  }

  s.queue = xQueueCreate(16, sizeof(Burst));
  s.phase = PH_LEARN;
  s.phase_end_ms = esphome::millis() + LEARN_MS;
  s.last_status_ms = esphome::millis();
  s.ready = true;
  xTaskCreate(scan_task_, "rf868", 4096, nullptr, 1, nullptr);

  ESP_LOGI(TAG, "==================================================================");
  ESP_LOGI(TAG, " CC1101 862-871 MHz RSSI scanner running");
  ESP_LOGI(TAG, " %u s noise-floor learning: DO NOT press the remote", (unsigned) (LEARN_MS / 1000));
  ESP_LOGI(TAG, " then repeating: %u s HANDS OFF (LED blips) / %u s PRESS NOW (LED solid on)",
           (unsigned) (IDLE_MS / 1000), (unsigned) (PRESS_MS / 1000));
  ESP_LOGI(TAG, " first PRESS window starts %u s after this line",
           (unsigned) ((LEARN_MS + IDLE_MS) / 1000));
  ESP_LOGI(TAG, "==================================================================");
}

inline void print_spectrum_(const char *title) {
  static const char RAMP[] = " .:-=+*#";
  char line[NCH + 1];
  for (uint8_t ch = 0; ch < NCH; ch++) {
    const float ex = s.hold_dbm[ch] - s.floor_dbm[ch];
    const int idx = ex < 6 ? 0 : ex < 10 ? 1 : ex < 15 ? 2 : ex < 20 ? 3 : ex < 25 ? 4 : ex < 30 ? 5 : ex < 40 ? 6 : 7;
    line[ch] = RAMP[idx];
  }
  line[NCH] = '\0';
  ESP_LOGI(TAG, "%s peak above floor ( .:-=+*# = <6/10/15/20/25/30/40/40+ dB):", title);
  ESP_LOGI(TAG, "  |%s|", line);
  ESP_LOGI(TAG, "   862  863  864  865  866  867  868  869  870  871 MHz");
}

inline void print_floor_() {
  float mn = 1000.0f, mx = -1000.0f, sum = 0.0f;
  uint8_t mx_ch = 0;
  for (uint8_t ch = 0; ch < NCH; ch++) {
    const float f = s.floor_dbm[ch];
    sum += f;
    mn = std::min(mn, f);
    if (f > mx) {
      mx = f;
      mx_ch = ch;
    }
  }
  const float avg = sum / NCH;
  ESP_LOGI(TAG, "Noise floor min %.1f / avg %.1f / max %.1f dBm (max at %.2f MHz); RSSI seen %.1f..%.1f dBm", mn,
           avg, mx, freq_mhz_(mx_ch), s.rssi_min, s.rssi_max);
  if (s.rssi_max - s.rssi_min < 1.0f)
    ESP_LOGE(TAG, "RSSI never changed - the CC1101 is not really receiving; results below are meaningless");
  else if (avg > -85.0f)
    ESP_LOGW(TAG, "Noise floor is unusually high (> -85 dBm) - strong local interference");
}

inline void verdict_() {
  if (s.press_windows == 0)
    return;
  int best_ch = -1;
  uint32_t best = 0;
  for (int ch = 0; ch < NCH; ch++) {
    uint32_t sum = 0;
    for (int c = std::max(0, ch - 1); c <= std::min(NCH - 1, ch + 1); c++)
      sum += s.press_by_ch[c];
    if (sum > best) {
      best = sum;
      best_ch = ch;
    }
  }
  uint32_t idle_near = 0;
  if (best_ch >= 0) {
    for (int c = std::max(0, best_ch - 1); c <= std::min(NCH - 1, best_ch + 1); c++)
      idle_near += s.idle_by_ch[c];
  }
  const float press_rate = static_cast<float>(best) / s.press_windows;
  const float idle_rate = s.idle_windows ? static_cast<float>(idle_near) / s.idle_windows : 0.0f;
  const double f = best_ch >= 0 ? freq_mhz_(best_ch) : 0.0;

  ESP_LOGI(TAG, "Totals: %u PRESS windows (%u with bursts), %u IDLE windows (%u with bursts)", s.press_windows,
           s.press_windows_hit, s.idle_windows, s.idle_windows_hit);
  if (best >= 3 && s.press_windows_hit >= 2 && press_rate >= 3.0f * idle_rate + 1.0f) {
    ESP_LOGW(TAG, "VERDICT: YES - remote-correlated activity at %.2f MHz (%u bursts while pressing vs %u hands-off)",
             f, (unsigned) best, (unsigned) idle_near);
    if (std::fabs(f - 867.84) < 0.25)
      ESP_LOGW(TAG, "  867.84 MHz = 2 x 433.92 MHz: rule out a 433 MHz harmonic by repeating from 2-3 m away");
  } else if (s.press_windows >= 3 && best == 0) {
    ESP_LOGW(TAG, "VERDICT: NO - nothing rose %.0f dB above the floor in 862-871 MHz during %u PRESS windows",
             HIT_DB, s.press_windows);
  } else if (s.press_windows >= 3) {
    ESP_LOGW(TAG, "VERDICT: NO clear correlation - best candidate %.2f MHz: %u bursts pressing vs %u hands-off", f,
             (unsigned) best, (unsigned) idle_near);
  } else {
    ESP_LOGI(TAG, "VERDICT: not enough data yet (best candidate %.2f MHz: %u pressing / %u hands-off) - keep going",
             f, (unsigned) best, (unsigned) idle_near);
  }
}

inline void drain_() {
  Burst b;
  while (xQueueReceive(s.queue, &b, 0) == pdTRUE) {
    if (b.phase == s.phase)
      s.win_bursts++;
    if (b.phase == PH_PRESS)
      s.press_by_ch[b.peak]++;
    else
      s.idle_by_ch[b.peak]++;
    const char *fmt = "[%s] burst %.2f MHz %.1f dBm (+%.0f dB), span %.2f-%.2f MHz, %u ms, %u sweeps";
    const char *ph = b.phase == PH_PRESS ? "PRESS" : "IDLE ";
    const unsigned dur = b.end_ms - b.start_ms;
    if (b.phase == PH_PRESS)
      ESP_LOGW(TAG, fmt, ph, freq_mhz_(b.peak), b.peak_dbm, b.peak_excess, freq_mhz_(b.lo), freq_mhz_(b.hi), dur,
               b.sweeps);
    else
      ESP_LOGI(TAG, fmt, ph, freq_mhz_(b.peak), b.peak_dbm, b.peak_excess, freq_mhz_(b.lo), freq_mhz_(b.hi), dur,
               b.sweeps);
  }
}

inline void next_phase_(uint32_t now) {
  if (s.phase == PH_LEARN) {
    print_floor_();
  } else {
    char title[48];
    snprintf(title, sizeof(title), "%s window #%u done, %u burst(s);", s.phase == PH_PRESS ? "PRESS" : "IDLE",
             s.phase == PH_PRESS ? s.press_windows + 1 : s.idle_windows + 1, s.win_bursts);
    print_spectrum_(title);
    if (s.phase == PH_PRESS) {
      s.press_windows++;
      if (s.win_bursts)
        s.press_windows_hit++;
    } else {
      s.idle_windows++;
      if (s.win_bursts)
        s.idle_windows_hit++;
    }
    verdict_();
  }

  const uint8_t next = s.phase == PH_IDLE ? PH_PRESS : PH_IDLE;
  s.win_bursts = 0;
  s.countdown_logged = false;
  s.reset_hold = true;
  s.phase = next;
  if (next == PH_PRESS) {
    s.phase_end_ms = now + PRESS_MS;
    ESP_LOGW(TAG, "######## PRESS NOW - window #%u, %u s, LED solid on ########", s.press_windows + 1,
             (unsigned) (PRESS_MS / 1000));
    ESP_LOGW(TAG, "  hold a button ~1 s, release ~1 s, repeat through every button; remote 0.3-1 m from antenna");
  } else {
    s.phase_end_ms = now + IDLE_MS;
    ESP_LOGI(TAG, "-------- HANDS OFF - idle window #%u, %u s --------", s.idle_windows + 1,
             (unsigned) (IDLE_MS / 1000));
  }
}

inline void tick() {
  const uint32_t now = esphome::millis();
  if (!s.ready) {
    led_((now / 100) % 2 == 0);  // fast blink = hardware fault
    if (now - s.last_status_ms >= 5000) {
      s.last_status_ms = now;
      ESP_LOGE(TAG, "SCANNER STOPPED: %s", s.fault);
    }
    return;
  }

  drain_();
  if (static_cast<int32_t>(now - s.phase_end_ms) >= 0)
    next_phase_(now);

  led_(s.phase == PH_PRESS || now % 1000 < 100);

  const uint32_t left_s = (s.phase_end_ms - now + 999) / 1000;
  if (s.phase == PH_IDLE && left_s <= 5 && !s.countdown_logged) {
    s.countdown_logged = true;
    ESP_LOGW(TAG, "PRESS window starts in 5 s - pick up the remote");
  }

  if (now - s.last_status_ms >= 5000) {
    const uint32_t sweeps = s.sweeps;
    const float rate = (sweeps - s.last_status_sweeps) * 1000.0f / (now - s.last_status_ms);
    s.last_status_ms = now;
    s.last_status_sweeps = sweeps;
    static const char *const NAMES[] = {"LEARNING, hands off", "HANDS OFF", "PRESSING"};
    ESP_LOGI(TAG, "[%s] %u s left | %.0f sweeps/s (%.1f ms each) | bursts this window: %u | dropped: %u",
             NAMES[s.phase], (unsigned) left_s, rate, s.sweep_us / 1000.0f, s.win_bursts, (unsigned) s.dropped);
  }
}

}  // namespace rf868
