#pragma once

#include <cinttypes>
#include <cmath>
#include <cstring>

#include "esphome.h"
#include "waste_valve_logic.h"
#include "waste_valve_tmc2209.h"

namespace waste_valve {

class ESPHomeHardware final : public Hardware {
 public:
  ESPHomeHardware(esphome::uart::UARTComponent *uart, esphome::stepper::Stepper *stepper,
                  esphome::switch_::Switch *enable, esphome::binary_sensor::BinarySensor *enable_feedback,
                  esphome::binary_sensor::BinarySensor *diag, esphome::pulse_counter::PulseCounterSensor *diag_edges,
                  esphome::text_sensor::TextSensor *position,
                  esphome::text_sensor::TextSensor *fault, esphome::binary_sensor::BinarySensor *ready,
                  esphome::sensor::Sensor *stallguard, uint32_t address, uint32_t threshold, float rsense,
                  float run_current)
      : uart_(uart),
        stepper_(stepper),
        enable_(enable),
        enable_feedback_(enable_feedback),
        diag_(diag),
        diag_edges_(diag_edges),
        position_(position),
        fault_(fault),
        ready_(ready),
        stallguard_(stallguard),
        address_(address),
        threshold_(threshold),
        rsense_(rsense),
        run_current_(run_current),
        last_diag_update_(esphome::millis()) {}

  uint32_t now_ms() const override { return esphome::millis(); }
  int32_t position() const override { return stepper_->current_position; }
  void reset_position() override { stepper_->report_position(0); }
  void set_target(int32_t target) override { stepper_->set_target(target); }
  void enable(bool enabled) override {
    if (enabled)
      enable_->turn_on();
    else
      enable_->turn_off();
  }
  bool enable_feedback() const override { return !enable_feedback_->has_state() || !enable_feedback_->state; }
  bool diag() const override { return !diag_->has_state() || diag_->state; }
  void diag_monitor_updated() override { last_diag_update_ = now_ms(); }
  bool diag_monitor_ready() const override {
    return diag_edges_->has_state() && !diag_edges_->is_failed() && now_ms() - last_diag_update_ <= 500;
  }

  bool configure_driver() override {
    if (address_ > 3 || threshold_ > 255 || !std::isfinite(rsense_) || rsense_ < 0.05f || rsense_ > 0.5f ||
        !std::isfinite(run_current_) || run_current_ <= 0.0f || run_current_ > 1.2f) {
      ESP_LOGE(TAG, "Invalid driver address, stall threshold, sense resistance or run current");
      return false;
    }
    const float scale = std::floor(32.0f * 1.414214f * run_current_ * (rsense_ + 0.02f) / 0.180f);
    if (scale < 1.0f || scale > 32.0f) {
      ESP_LOGE(TAG, "Requested current cannot be represented with VSENSE=1 and this sense resistor");
      return false;
    }
    const uint32_t irun = static_cast<uint32_t>(scale) - 1;
    const float actual_current = (irun + 1) / 32.0f * 0.180f / (rsense_ + 0.02f) / 1.414214f;

    uint32_t value;
    uint32_t before;
    if (!read_(IOIN, value) || (value >> 24) != 0x21 || !read_(IFCNT, before)) {
      ESP_LOGE(TAG, "TMC2209 not detected at UART address %" PRIu32, address_);
      return false;
    }
    if ((value & (1u << 8)) != 0) {
      ESP_LOGE(TAG, "TMC2209 SPREAD input must be low");
      return false;
    }

    const RegisterValue configuration[] = {
        {GCONF, GCONF_VALUE},
        {CHOPCONF, CHOPCONF_VALUE},
        {IHOLD_IRUN, (8u << 16) | (irun << 8) | irun},
        {TPOWERDOWN, 0},
        {TPWMTHRS, 0},
        {TCOOLTHRS, 0xFFFFF},
        {SGTHRS, threshold_},
        {COOLCONF, 0},
        {VACTUAL, 0},
        {PWMCONF, 0xC80D0E24},
        {GSTAT, 0x07},
    };
    for (const auto &setting : configuration) {
      if (!write_(setting.reg, setting.value))
        return false;
    }

    uint32_t after;
    uint32_t gconf;
    uint32_t chopconf;
    if (!read_(IFCNT, after) ||
        static_cast<uint8_t>(after - before) != sizeof(configuration) / sizeof(configuration[0]) ||
        !read_(GCONF, gconf) || (gconf & GCONF_MASK) != GCONF_VALUE || !read_(CHOPCONF, chopconf) ||
        (chopconf & CHOPCONF_MASK) != CHOPCONF_VALUE || !check_driver(false)) {
      ESP_LOGE(TAG, "TMC2209 configuration verification failed");
      return false;
    }
    ESP_LOGI(TAG, "TMC2209 configured: %.3f A RMS nominal, SGTHRS=%" PRIu32, actual_current, threshold_);
    return true;
  }

  bool set_driver_mode(DriverMode mode) override {
    if (mode == DriverMode::ANY) {
      ESP_LOGE(TAG, "A specific chopper mode is required");
      return false;
    }
    const uint32_t expected = GCONF_VALUE | (mode == DriverMode::SPREAD_CYCLE ? (1u << 2) : 0);
    uint32_t ioin;
    uint32_t before;
    uint32_t after;
    uint32_t gconf;
    if (!read_(IOIN, ioin) || (ioin >> 24) != 0x21 || (ioin & (1u << 8)) != 0 || !read_(IFCNT, before) ||
        !write_(GCONF, expected) || !read_(IFCNT, after) || static_cast<uint8_t>(after - before) != 1 ||
        !read_(GCONF, gconf) || (gconf & GCONF_MASK) != expected || !check_driver(false)) {
      ESP_LOGE(TAG, "TMC2209 chopper mode verification failed; check the SPREAD pin");
      return false;
    }
    return true;
  }

  bool check_driver(bool check_open_load, DriverMode expected = DriverMode::ANY) override {
    uint32_t gstat;
    uint32_t status;
    if (!read_(GSTAT, gstat) || !read_(DRV_STATUS, status))
      return false;
    const uint32_t status_mask = check_open_load ? 0xFF : 0x3F;
    const bool stealth = (status & (1u << 30)) != 0;
    const bool unreliable_coil_test =
        check_open_load && expected == DriverMode::SPREAD_CYCLE && (status & (1u << 31)) != 0;
    if ((gstat & 0x07) != 0 || (status & status_mask) != 0 ||
        unreliable_coil_test ||
        (expected == DriverMode::STEALTH_CHOP && !stealth) ||
        (expected == DriverMode::SPREAD_CYCLE && stealth)) {
      ESP_LOGE(TAG, "TMC2209 GSTAT=0x%08" PRIX32 ", DRV_STATUS=0x%08" PRIX32, gstat, status);
      return false;
    }
    return true;
  }

  bool sample_stallguard() override {
    uint32_t value;
    if (!read_(SG_RESULT, value))
      return false;
    stallguard_->publish_state(static_cast<float>(value & 0x3FF));
    return true;
  }

  void publish(const char *position, const char *fault, bool ready) override {
    position_->publish_state(position);
    fault_->publish_state(fault);
    ready_->publish_state(ready);
    if (std::strcmp(position, "Homing") != 0 && std::strcmp(position, "Opening") != 0 &&
        std::strcmp(position, "Closing") != 0)
      stallguard_->publish_state(NAN);
    if (std::strcmp(fault, "None") == 0)
      ESP_LOGI(TAG, "Position: %s", position);
    else
      ESP_LOGE(TAG, "Position unknown: %s", fault);
  }

  void log_rejected(const char *reason) override { ESP_LOGW(TAG, "Command rejected: %s", reason); }

 private:
  struct RegisterValue {
    uint8_t reg;
    uint32_t value;
  };

  static constexpr const char *TAG = "waste_valve";
  static constexpr uint8_t GCONF = 0x00;
  static constexpr uint8_t GSTAT = 0x01;
  static constexpr uint8_t IFCNT = 0x02;
  static constexpr uint8_t IOIN = 0x06;
  static constexpr uint8_t IHOLD_IRUN = 0x10;
  static constexpr uint8_t TPOWERDOWN = 0x11;
  static constexpr uint8_t TPWMTHRS = 0x13;
  static constexpr uint8_t TCOOLTHRS = 0x14;
  static constexpr uint8_t VACTUAL = 0x22;
  static constexpr uint8_t SGTHRS = 0x40;
  static constexpr uint8_t SG_RESULT = 0x41;
  static constexpr uint8_t COOLCONF = 0x42;
  static constexpr uint8_t CHOPCONF = 0x6C;
  static constexpr uint8_t DRV_STATUS = 0x6F;
  static constexpr uint8_t PWMCONF = 0x70;
  static constexpr uint32_t GCONF_VALUE = (1u << 6) | (1u << 7);
  static constexpr uint32_t GCONF_MASK = 0x3FF;
  static constexpr uint32_t CHOPCONF_VALUE = (4u << 24) | (1u << 28) | (1u << 17) | (2u << 15) | (5u << 4) | 3u;
  static constexpr uint32_t CHOPCONF_MASK =
      (0xFu << 24) | (0xFu << 28) | (1u << 17) | (3u << 15) | (0xFu << 7) | (7u << 4) | 0xFu;

  void discard_() {
    uint8_t byte;
    while (uart_->available() && uart_->read_byte(&byte)) {}
  }

  bool transmit_(const uint8_t *request, size_t length) {
    discard_();
    uart_->write_array(request, length);
    const auto result = uart_->flush();
    if (result != esphome::uart::UARTFlushResult::UART_FLUSH_RESULT_SUCCESS &&
        result != esphome::uart::UARTFlushResult::UART_FLUSH_RESULT_ASSUMED_SUCCESS) {
      ESP_LOGE(TAG, "TMC2209 UART transmit failed");
      return false;
    }
    uint8_t echo[8];
    if (!uart_->read_array(echo, length) || std::memcmp(echo, request, length) != 0) {
      ESP_LOGE(TAG, "TMC2209 UART echo missing or invalid");
      return false;
    }
    return true;
  }

  bool read_(uint8_t reg, uint32_t &value) {
    uint8_t request[4];
    uint8_t reply[8];
    tmc2209::read_request(static_cast<uint8_t>(address_), reg, request);
    if (!transmit_(request, sizeof(request)) || !uart_->read_array(reply, sizeof(reply)) ||
        !tmc2209::decode_reply(reg, reply, value)) {
      ESP_LOGE(TAG, "TMC2209 register 0x%02X read failed", reg);
      return false;
    }
    return true;
  }

  bool write_(uint8_t reg, uint32_t value) {
    uint8_t request[8];
    tmc2209::write_request(static_cast<uint8_t>(address_), reg, value, request);
    if (!transmit_(request, sizeof(request))) {
      ESP_LOGE(TAG, "TMC2209 register 0x%02X write failed", reg);
      return false;
    }
    return true;
  }

  esphome::uart::UARTComponent *uart_;
  esphome::stepper::Stepper *stepper_;
  esphome::switch_::Switch *enable_;
  esphome::binary_sensor::BinarySensor *enable_feedback_;
  esphome::binary_sensor::BinarySensor *diag_;
  esphome::pulse_counter::PulseCounterSensor *diag_edges_;
  esphome::text_sensor::TextSensor *position_;
  esphome::text_sensor::TextSensor *fault_;
  esphome::binary_sensor::BinarySensor *ready_;
  esphome::sensor::Sensor *stallguard_;
  uint32_t address_;
  uint32_t threshold_;
  float rsense_;
  float run_current_;
  uint32_t last_diag_update_;
};

inline Controller *controller = nullptr;

}  // namespace waste_valve
