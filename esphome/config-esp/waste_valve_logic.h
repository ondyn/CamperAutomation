#pragma once

#include <cstdint>

namespace waste_valve {

struct Options {
  bool commissioned;
  int32_t travel_steps;
  int32_t release_steps;
  int32_t min_home_steps;
  uint8_t min_travel_percent;
  uint8_t max_travel_percent;
  uint32_t phase_timeout_ms;
};

enum class DriverMode { ANY, SPREAD_CYCLE, STEALTH_CHOP };

class Hardware {
 public:
  virtual ~Hardware() = default;
  virtual uint32_t now_ms() const = 0;
  virtual int32_t position() const = 0;
  virtual void reset_position() = 0;
  virtual void set_target(int32_t target) = 0;
  virtual void enable(bool enabled) = 0;
  virtual bool enable_feedback() const = 0;
  virtual bool diag() const = 0;
  virtual void diag_monitor_updated() = 0;
  virtual bool diag_monitor_ready() const = 0;
  virtual bool configure_driver() = 0;
  virtual bool set_driver_mode(DriverMode mode) = 0;
  virtual bool check_driver(bool check_open_load, DriverMode expected = DriverMode::ANY) = 0;
  virtual bool sample_stallguard() = 0;
  virtual void publish(const char *position, const char *fault, bool ready) = 0;
  virtual void log_rejected(const char *reason) = 0;
};

enum class Mode {
  IDLE,
  FAULT,
  PREPARE_RELEASE,
  PREPARE_OPEN,
  PREPARE_CLOSE,
  ARM_COIL_TEST,
  COIL_TEST,
  WAIT_STEALTH,
  ARM_RELEASE,
  RELEASE,
  WAIT_HOME,
  ARM_HOME,
  HOMING,
  ARM_OPEN,
  OPENING,
  ARM_CLOSE,
  CLOSING,
};

enum class Position { UNKNOWN, CLOSED, OPEN };

class Controller {
 public:
  Controller(Hardware &hardware, Options options) : hw_(hardware), options_(options) {}

  void begin() {
    hw_.set_target(hw_.position());
    hw_.enable(false);
    position_ = Position::UNKNOWN;
    if (!valid_options_()) {
      fail_("Invalid valve configuration");
    } else if (!options_.commissioned) {
      fail_("Not commissioned");
    } else {
      home();
    }
  }

  void home() {
    if (busy_()) {
      hw_.log_rejected("Stop the current movement before homing");
      return;
    }
    position_ = Position::UNKNOWN;
    prepare_(Mode::PREPARE_RELEASE, "Homing");
  }

  void open() {
    if (busy_()) {
      hw_.log_rejected("Movement already in progress");
      return;
    }
    if (mode_ == Mode::FAULT || position_ == Position::UNKNOWN) {
      hw_.log_rejected("Home the valve before opening");
      return;
    }
    if (position_ == Position::OPEN)
      return;
    prepare_(Mode::PREPARE_OPEN, "Opening");
  }

  void close() {
    if (busy_()) {
      hw_.log_rejected("Movement already in progress");
      return;
    }
    if (mode_ == Mode::FAULT) {
      hw_.log_rejected("Inspect the fault and press Home to retry");
      return;
    }
    if (position_ == Position::UNKNOWN) {
      home();
      return;
    }
    if (position_ == Position::CLOSED)
      return;
    prepare_(Mode::PREPARE_CLOSE, "Closing");
  }

  void stop() {
    if (!busy_()) {
      hw_.enable(false);
      return;
    }
    fail_("Stopped; home required");
  }

  void diag_sample(bool edge) {
    hw_.diag_monitor_updated();
    if (!edge)
      return;
    if (mode_ == Mode::WAIT_STEALTH) {
      fail_("DIAG during coil test");
    } else if (mode_ == Mode::IDLE && position_ != Position::UNKNOWN &&
        hw_.now_ms() - idle_started_ >= DIAG_CLEAR_TIMEOUT_MS) {
      fail_("DIAG pulse while idle");
    } else if (mode_ == Mode::ARM_COIL_TEST || mode_ == Mode::COIL_TEST || arming_() ||
               mode_ == Mode::RELEASE || mode_ == Mode::HOMING || mode_ == Mode::OPENING ||
               mode_ == Mode::CLOSING) {
      diag_latched_ = true;
      tick();
    }
  }

  void tick() {
    if (mode_ == Mode::IDLE) {
      if (position_ != Position::UNKNOWN && !hw_.diag_monitor_ready()) {
        fail_("DIAG monitoring unavailable");
        return;
      }
      if (position_ != Position::UNKNOWN && hw_.now_ms() - last_health_check_ >= IDLE_HEALTH_INTERVAL_MS) {
        last_health_check_ = hw_.now_ms();
        if (hw_.enable_feedback())
          fail_("Driver still enabled");
        else if (!hw_.check_driver(false))
          fail_("Driver fault or UART failure");
        else if (hw_.diag())
          fail_("DIAG active while idle");
      }
      return;
    }
    if (mode_ == Mode::FAULT)
      return;

    if (!hw_.diag_monitor_ready()) {
      fail_("DIAG monitoring unavailable");
      return;
    }

    const uint32_t elapsed = hw_.now_ms() - phase_started_;
    if (elapsed > options_.phase_timeout_ms) {
      fail_("Movement timed out");
      return;
    }

    if (preparing_()) {
      if (elapsed < FEEDBACK_SETTLE_MS)
        return;
      if (hw_.enable_feedback()) {
        fail_("Driver still enabled");
        return;
      }
      if (configure_pending_) {
        const bool ok = mode_ == Mode::PREPARE_RELEASE ? hw_.configure_driver() : hw_.check_driver(false);
        if (!ok) {
          fail_(mode_ == Mode::PREPARE_RELEASE ? "Driver configuration or UART failure"
                                               : "Driver fault or UART failure");
          return;
        }
        if (!hw_.set_driver_mode(DriverMode::SPREAD_CYCLE)) {
          fail_("Driver chopper configuration failed");
          return;
        }
        configure_pending_ = false;
        phase_started_ = hw_.now_ms();
        return;
      }
      if (hw_.diag()) {
        if (elapsed >= DIAG_CLEAR_TIMEOUT_MS)
          fail_("DIAG active before movement");
        return;
      }
      if (!hw_.check_driver(false)) {
        fail_("Driver fault or UART failure");
      } else {
        next_motion_ = mode_ == Mode::PREPARE_RELEASE ? Mode::ARM_RELEASE
                       : mode_ == Mode::PREPARE_OPEN  ? Mode::ARM_OPEN
                                                      : Mode::ARM_CLOSE;
        steps_offset_ = 0;
        hw_.reset_position();
        hw_.set_target(0);
        mode_ = Mode::ARM_COIL_TEST;
        phase_started_ = hw_.now_ms();
        hw_.enable(true);
      }
      return;
    }

    if (mode_ == Mode::ARM_COIL_TEST) {
      if (elapsed < FEEDBACK_SETTLE_MS)
        return;
      if (!hw_.enable_feedback()) {
        fail_("Enable interlock open");
      } else if (hw_.diag() || diag_latched_) {
        fail_("DIAG active before coil test");
      } else if (!hw_.check_driver(false, DriverMode::SPREAD_CYCLE)) {
        fail_("Driver fault or SpreadCycle unavailable");
      } else {
        target_ = options_.release_steps;
        if (next_motion_ == Mode::ARM_CLOSE)
          target_ = -target_;
        mode_ = Mode::COIL_TEST;
        phase_started_ = hw_.now_ms();
        last_health_check_ = phase_started_;
        hw_.set_target(target_);
      }
      return;
    }

    if (mode_ == Mode::COIL_TEST) {
      if (!hw_.enable_feedback()) {
        fail_("Enable interlock opened");
      } else if (hw_.diag() || diag_latched_) {
        fail_("DIAG active during coil test");
      } else if (abs_steps_(hw_.position()) >= options_.release_steps) {
        fail_("Coil test ended before sampling");
      } else if (abs_steps_(hw_.position()) >= COIL_TEST_STEPS) {
        if (!hw_.check_driver(true, DriverMode::SPREAD_CYCLE)) {
          fail_("Open coil or driver fault");
        } else {
          steps_offset_ = abs_steps_(hw_.position());
          halt_();
          if (!hw_.set_driver_mode(DriverMode::STEALTH_CHOP)) {
            fail_("Driver chopper configuration failed");
          } else {
            mode_ = Mode::WAIT_STEALTH;
            phase_started_ = hw_.now_ms();
          }
        }
      } else if (hw_.now_ms() - last_health_check_ >= HEALTH_INTERVAL_MS) {
        last_health_check_ = hw_.now_ms();
        if (!hw_.check_driver(false, DriverMode::SPREAD_CYCLE))
          fail_("Driver fault or UART failure");
      }
      return;
    }

    if (mode_ == Mode::WAIT_STEALTH) {
      if (elapsed < FEEDBACK_SETTLE_MS)
        return;
      if (hw_.enable_feedback()) {
        fail_("Driver still enabled");
      } else if (hw_.diag() || diag_latched_) {
        if (elapsed >= DIAG_CLEAR_TIMEOUT_MS)
          fail_("DIAG did not clear");
      } else if (!hw_.check_driver(false)) {
        fail_("Driver fault or UART failure");
      } else {
        const char *state = next_motion_ == Mode::ARM_RELEASE ? "Homing"
                            : next_motion_ == Mode::ARM_OPEN  ? "Opening"
                                                              : "Closing";
        arm_(next_motion_, state);
      }
      return;
    }

    if (mode_ == Mode::WAIT_HOME) {
      if (elapsed >= SETTLE_MS) {
        if (hw_.enable_feedback()) {
          fail_("Driver still enabled");
        } else if (hw_.diag()) {
          fail_("DIAG did not clear");
        } else if (!hw_.check_driver(false)) {
          fail_("Driver fault or UART failure");
        } else {
          steps_offset_ = 0;
          arm_(Mode::ARM_HOME, "Homing");
        }
      }
      return;
    }

    if (arming_()) {
      if (elapsed < FEEDBACK_SETTLE_MS)
        return;
      if (!hw_.enable_feedback()) {
        fail_("Enable interlock open");
      } else if (hw_.diag() || diag_latched_) {
        fail_("DIAG active before movement");
      } else if (elapsed < ENABLE_SETTLE_MS) {
        return;
      } else if (!hw_.check_driver(false, DriverMode::STEALTH_CHOP)) {
        fail_("Driver fault or UART failure");
      } else {
        start_motion_();
      }
      return;
    }

    if (!hw_.enable_feedback()) {
      fail_("Enable interlock opened");
      return;
    }
    if (hw_.diag() || diag_latched_) {
      const Mode stopped_mode = mode_;
      const int32_t steps = steps_offset_ + abs_steps_(hw_.position());
      halt_();
      if (!hw_.check_driver(false)) {
        fail_("Driver fault or UART failure");
      } else if (stopped_mode == Mode::RELEASE) {
        mode_ = Mode::WAIT_HOME;
        phase_started_ = hw_.now_ms();
      } else if (stopped_mode == Mode::HOMING) {
        if (steps < options_.min_home_steps)
          fail_("Homing stall too early");
        else
          reached_(Position::CLOSED);
      } else if (steps < min_known_steps_()) {
        fail_("Unexpected stall before end position");
      } else {
        reached_(stopped_mode == Mode::OPENING ? Position::OPEN : Position::CLOSED);
      }
      return;
    }

    if (hw_.position() == target_) {
      if (mode_ == Mode::RELEASE) {
        halt_();
        mode_ = Mode::WAIT_HOME;
        phase_started_ = hw_.now_ms();
      } else {
        fail_("End stop not detected within travel limit");
      }
      return;
    }

    if (hw_.now_ms() - last_health_check_ >= HEALTH_INTERVAL_MS) {
      last_health_check_ = hw_.now_ms();
      if (!hw_.check_driver(steps_offset_ + abs_steps_(hw_.position()) >= options_.release_steps,
                            DriverMode::STEALTH_CHOP)) {
        fail_("Driver fault or UART failure");
        return;
      }
      if (!hw_.sample_stallguard())
        fail_("StallGuard UART failure");
    }
  }

  Mode mode() const { return mode_; }
  Position position() const { return position_; }

 private:
  static constexpr uint32_t FEEDBACK_SETTLE_MS = 30;
  static constexpr uint32_t DIAG_CLEAR_TIMEOUT_MS = 300;
  static constexpr uint32_t ENABLE_SETTLE_MS = 200;
  static constexpr uint32_t SETTLE_MS = 300;
  static constexpr uint32_t HEALTH_INTERVAL_MS = 250;
  static constexpr uint32_t IDLE_HEALTH_INTERVAL_MS = 1000;
  static constexpr int32_t COIL_TEST_STEPS = 4 * 16;

  bool valid_options_() const {
    return options_.travel_steps >= 64 && options_.travel_steps <= 100000 &&
           options_.release_steps > COIL_TEST_STEPS &&
           options_.release_steps > options_.min_home_steps && options_.release_steps < options_.travel_steps / 2 &&
           options_.min_home_steps > 0 && options_.min_travel_percent >= 50 && options_.min_travel_percent <= 100 &&
           options_.max_travel_percent >= 105 && options_.max_travel_percent <= 150 &&
           options_.phase_timeout_ms >= 1000 && options_.phase_timeout_ms <= 60000;
  }

  bool busy_() const { return mode_ != Mode::IDLE && mode_ != Mode::FAULT; }

  bool preparing_() const {
    return mode_ == Mode::PREPARE_RELEASE || mode_ == Mode::PREPARE_OPEN || mode_ == Mode::PREPARE_CLOSE;
  }

  bool arming_() const {
    return mode_ == Mode::ARM_RELEASE || mode_ == Mode::ARM_HOME || mode_ == Mode::ARM_OPEN ||
           mode_ == Mode::ARM_CLOSE;
  }

  static int32_t abs_steps_(int32_t steps) { return steps < 0 ? -steps : steps; }
  int32_t min_known_steps_() const { return options_.travel_steps * options_.min_travel_percent / 100; }
  int32_t max_steps_() const { return options_.travel_steps * options_.max_travel_percent / 100; }

  void prepare_(Mode mode, const char *state) {
    if (!valid_options_()) {
      fail_("Invalid valve configuration");
      return;
    }
    if (!options_.commissioned) {
      fail_("Not commissioned");
      return;
    }
    hw_.enable(false);
    mode_ = mode;
    configure_pending_ = true;
    phase_started_ = hw_.now_ms();
    hw_.publish(state, "None", false);
  }

  void arm_(Mode mode, const char *state) {
    hw_.reset_position();
    hw_.set_target(0);
    mode_ = mode;
    phase_started_ = hw_.now_ms();
    hw_.publish(state, "None", false);
    hw_.enable(true);
  }

  void start_motion_() {
    switch (mode_) {
      case Mode::ARM_RELEASE:
        mode_ = Mode::RELEASE;
        target_ = options_.release_steps - steps_offset_;
        break;
      case Mode::ARM_HOME:
        mode_ = Mode::HOMING;
        target_ = -max_steps_();
        break;
      case Mode::ARM_OPEN:
        mode_ = Mode::OPENING;
        target_ = max_steps_() - steps_offset_;
        break;
      case Mode::ARM_CLOSE:
        mode_ = Mode::CLOSING;
        target_ = -(max_steps_() - steps_offset_);
        break;
      default:
        fail_("Invalid movement state");
        return;
    }
    phase_started_ = hw_.now_ms();
    last_health_check_ = phase_started_;
    hw_.set_target(target_);
  }

  void halt_() {
    hw_.set_target(hw_.position());
    hw_.enable(false);
    diag_latched_ = false;
  }

  void reached_(Position position) {
    position_ = position;
    mode_ = Mode::IDLE;
    last_health_check_ = hw_.now_ms();
    idle_started_ = last_health_check_;
    hw_.publish(position == Position::OPEN ? "Open" : "Closed", "None", true);
  }

  void fail_(const char *reason) {
    halt_();
    position_ = Position::UNKNOWN;
    mode_ = Mode::FAULT;
    hw_.publish("Unknown", reason, false);
  }

  Hardware &hw_;
  Options options_;
  Mode mode_{Mode::IDLE};
  Mode next_motion_{Mode::ARM_RELEASE};
  Position position_{Position::UNKNOWN};
  int32_t target_{0};
  int32_t steps_offset_{0};
  uint32_t phase_started_{0};
  uint32_t last_health_check_{0};
  uint32_t idle_started_{0};
  bool configure_pending_{false};
  bool diag_latched_{false};
};

}  // namespace waste_valve
