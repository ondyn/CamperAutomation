#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>

#include "../config-esp/waste_valve_logic.h"
#include "../config-esp/waste_valve_tmc2209.h"

using waste_valve::Controller;
using waste_valve::DriverMode;
using waste_valve::Mode;
using waste_valve::Options;
using waste_valve::Position;

struct FakeHardware final : waste_valve::Hardware {
  uint32_t now{0};
  int32_t steps{0};
  int32_t target{0};
  bool enabled{false};
  bool interlock_closed{true};
  bool stuck_enabled{false};
  bool diag_high{false};
  bool diag_monitor_ok{true};
  bool configure_ok{true};
  bool mode_change_ok{true};
  bool coil_ok{true};
  bool health_ok{true};
  bool sample_ok{true};
  bool ready{false};
  unsigned configure_count{0};
  unsigned mode_changes{0};
  unsigned diag_updates{0};
  unsigned samples{0};
  DriverMode driver_mode{DriverMode::STEALTH_CHOP};
  std::string state;
  std::string fault;
  std::string rejected;

  uint32_t now_ms() const override { return now; }
  int32_t position() const override { return steps; }
  void reset_position() override { steps = 0; }
  void set_target(int32_t value) override { target = value; }
  void enable(bool value) override { enabled = value; }
  bool enable_feedback() const override { return stuck_enabled || (enabled && interlock_closed); }
  bool diag() const override { return diag_high; }
  void diag_monitor_updated() override { ++diag_updates; }
  bool diag_monitor_ready() const override { return diag_monitor_ok; }
  bool configure_driver() override {
    ++configure_count;
    return configure_ok;
  }
  bool set_driver_mode(DriverMode mode) override {
    if (!mode_change_ok)
      return false;
    ++mode_changes;
    driver_mode = mode;
    return true;
  }
  bool check_driver(bool check_open_load, DriverMode expected) override {
    return health_ok && (expected == DriverMode::ANY || expected == driver_mode) &&
           !(check_open_load && expected == DriverMode::SPREAD_CYCLE && !coil_ok);
  }
  bool sample_stallguard() override {
    ++samples;
    return sample_ok;
  }
  void publish(const char *new_state, const char *new_fault, bool new_ready) override {
    state = new_state;
    fault = new_fault;
    ready = new_ready;
  }
  void log_rejected(const char *reason) override { rejected = reason; }
  void advance(uint32_t ms) { now += ms; }
};

Options defaults(bool commissioned = true) { return {commissioned, 800, 80, 16, 80, 120, 15000}; }

void arm_coil_test(FakeHardware &hw, Controller &controller, Mode preparing) {
  assert(controller.mode() == preparing && !hw.enabled);
  hw.advance(30);
  controller.tick();
  assert(controller.mode() == preparing && !hw.enabled);
  hw.advance(30);
  controller.tick();
  assert(controller.mode() == Mode::ARM_COIL_TEST && hw.enabled);
  assert(hw.driver_mode == DriverMode::SPREAD_CYCLE);
}

void start_coil_test(FakeHardware &hw, Controller &controller, Mode preparing) {
  arm_coil_test(hw, controller, preparing);
  hw.advance(30);
  controller.tick();
  assert(controller.mode() == Mode::COIL_TEST && hw.enabled);
}

void finish_preparation(FakeHardware &hw, Controller &controller, Mode preparing, Mode arming) {
  start_coil_test(hw, controller, preparing);
  assert(hw.target == (arming == Mode::ARM_CLOSE ? -80 : 80));
  hw.steps = arming == Mode::ARM_CLOSE ? -64 : 64;
  controller.tick();
  assert(controller.mode() == Mode::WAIT_STEALTH && !hw.enabled);
  assert(hw.driver_mode == DriverMode::STEALTH_CHOP);
  hw.advance(30);
  controller.tick();
  assert(controller.mode() == arming && hw.enabled);
}

void start_release(FakeHardware &hw, Controller &controller) {
  controller.begin();
  assert(hw.state == "Homing");
  finish_preparation(hw, controller, Mode::PREPARE_RELEASE, Mode::ARM_RELEASE);
  hw.advance(200);
  controller.tick();
  assert(controller.mode() == Mode::RELEASE && hw.target == 16);
}

void start_home_seek(FakeHardware &hw, Controller &controller) {
  start_release(hw, controller);
  hw.steps = 16;
  controller.tick();
  assert(controller.mode() == Mode::WAIT_HOME && !hw.enabled);
  hw.advance(299);
  controller.tick();
  assert(controller.mode() == Mode::WAIT_HOME);
  hw.advance(1);
  controller.tick();
  assert(controller.mode() == Mode::ARM_HOME && hw.enabled);
  hw.advance(200);
  controller.tick();
  assert(controller.mode() == Mode::HOMING && hw.target == -960);
}

void home_closed(FakeHardware &hw, Controller &controller) {
  start_home_seek(hw, controller);
  hw.steps = -500;
  hw.diag_high = true;
  controller.tick();
  assert(controller.mode() == Mode::IDLE && controller.position() == Position::CLOSED);
  assert(hw.state == "Closed" && hw.fault == "None" && hw.ready && !hw.enabled);
  hw.diag_high = false;
}

void start_open(FakeHardware &hw, Controller &controller) {
  controller.open();
  finish_preparation(hw, controller, Mode::PREPARE_OPEN, Mode::ARM_OPEN);
  hw.advance(200);
  controller.tick();
  assert(controller.mode() == Mode::OPENING && hw.target == 896 && hw.state == "Opening");
}

void test_boot_and_normal_cycle() {
  FakeHardware hw;
  Controller controller(hw, defaults());
  home_closed(hw, controller);
  start_open(hw, controller);
  hw.steps = 736;
  hw.diag_high = true;
  controller.tick();
  assert(controller.position() == Position::OPEN && hw.state == "Open" && hw.ready && !hw.enabled);
  hw.diag_high = false;
  controller.close();
  finish_preparation(hw, controller, Mode::PREPARE_CLOSE, Mode::ARM_CLOSE);
  hw.advance(200);
  controller.tick();
  assert(controller.mode() == Mode::CLOSING && hw.target == -896 && hw.state == "Closing");
  hw.steps = -736;
  hw.diag_high = true;
  controller.tick();
  assert(controller.position() == Position::CLOSED && hw.state == "Closed" && !hw.enabled);
  assert(hw.configure_count == 1);
}

void test_commissioning_and_options() {
  FakeHardware hw;
  Controller uncommissioned(hw, defaults(false));
  uncommissioned.begin();
  assert(uncommissioned.mode() == Mode::FAULT && hw.fault == "Not commissioned");
  assert(!hw.enabled && hw.configure_count == 0 && !hw.ready);
  uncommissioned.home();
  assert(!hw.enabled && hw.configure_count == 0);

  FakeHardware invalid_hw;
  Options invalid = defaults();
  invalid.release_steps = invalid.min_home_steps;
  Controller invalid_controller(invalid_hw, invalid);
  invalid_controller.begin();
  assert(invalid_controller.mode() == Mode::FAULT && invalid_hw.fault == "Invalid valve configuration");
  assert(!invalid_hw.enabled);

  FakeHardware short_hw;
  Options short_release = defaults();
  short_release.release_steps = 64;
  Controller short_controller(short_hw, short_release);
  short_controller.begin();
  assert(short_controller.mode() == Mode::FAULT && short_hw.fault == "Invalid valve configuration");
}

void test_release_stall_and_home_threshold() {
  FakeHardware hw;
  Controller controller(hw, defaults());
  start_release(hw, controller);
  hw.steps = 8;
  hw.diag_high = true;
  controller.tick();
  assert(controller.mode() == Mode::WAIT_HOME && !hw.enabled);
  hw.diag_high = false;
  hw.advance(300);
  controller.tick();
  hw.advance(200);
  controller.tick();
  hw.steps = -16;
  hw.diag_high = true;
  controller.tick();
  assert(controller.position() == Position::CLOSED);

  FakeHardware early_hw;
  Controller early(early_hw, defaults());
  start_home_seek(early_hw, early);
  early_hw.steps = -15;
  early_hw.diag_high = true;
  early.tick();
  assert(early.mode() == Mode::FAULT && early_hw.fault == "Homing stall too early" && !early_hw.enabled);
}

void test_known_travel_limits() {
  FakeHardware early_hw;
  Controller early(early_hw, defaults());
  home_closed(early_hw, early);
  start_open(early_hw, early);
  early_hw.steps = 575;
  early_hw.diag_high = true;
  early.tick();
  assert(early.mode() == Mode::FAULT && early.position() == Position::UNKNOWN);
  assert(early_hw.state == "Unknown" && early_hw.fault == "Unexpected stall before end position");

  FakeHardware boundary_hw;
  Controller boundary(boundary_hw, defaults());
  home_closed(boundary_hw, boundary);
  start_open(boundary_hw, boundary);
  boundary_hw.steps = 576;
  boundary_hw.diag_high = true;
  boundary.tick();
  assert(boundary.position() == Position::OPEN);

  FakeHardware missing_hw;
  Controller missing(missing_hw, defaults());
  home_closed(missing_hw, missing);
  start_open(missing_hw, missing);
  missing_hw.steps = 896;
  missing.tick();
  assert(missing.mode() == Mode::FAULT && missing_hw.fault == "End stop not detected within travel limit");
  assert(!missing_hw.enabled && !missing_hw.ready);
}

void test_interlock_and_driver_faults() {
  FakeHardware interlock_hw;
  interlock_hw.interlock_closed = false;
  Controller interlock(interlock_hw, defaults());
  interlock.begin();
  arm_coil_test(interlock_hw, interlock, Mode::PREPARE_RELEASE);
  interlock_hw.advance(30);
  interlock.tick();
  assert(interlock.mode() == Mode::FAULT && interlock_hw.fault == "Enable interlock open");
  assert(!interlock_hw.enabled && interlock_hw.target == interlock_hw.steps);

  FakeHardware open_hw;
  Controller opened(open_hw, defaults());
  start_release(open_hw, opened);
  open_hw.steps = 10;
  open_hw.interlock_closed = false;
  opened.tick();
  assert(opened.mode() == Mode::FAULT && open_hw.fault == "Enable interlock opened" && !open_hw.enabled);

  FakeHardware stuck_hw;
  stuck_hw.stuck_enabled = true;
  Controller stuck(stuck_hw, defaults());
  stuck.begin();
  stuck_hw.advance(30);
  stuck.tick();
  assert(stuck.mode() == Mode::FAULT && stuck_hw.fault == "Driver still enabled");
  assert(stuck_hw.configure_count == 0);

  FakeHardware comm_hw;
  comm_hw.configure_ok = false;
  Controller comm(comm_hw, defaults());
  comm.begin();
  comm_hw.advance(30);
  comm.tick();
  assert(comm.mode() == Mode::FAULT && comm_hw.fault == "Driver configuration or UART failure");
  assert(!comm_hw.enabled);

  FakeHardware runtime_hw;
  Controller runtime(runtime_hw, defaults());
  start_release(runtime_hw, runtime);
  runtime_hw.steps = 10;
  runtime_hw.health_ok = false;
  runtime_hw.advance(250);
  runtime.tick();
  assert(runtime.mode() == Mode::FAULT && runtime_hw.fault == "Driver fault or UART failure");
  assert(!runtime_hw.enabled);

  FakeHardware sample_hw;
  Controller sample(sample_hw, defaults());
  start_release(sample_hw, sample);
  sample_hw.steps = 10;
  sample_hw.sample_ok = false;
  sample_hw.advance(250);
  sample.tick();
  assert(sample.mode() == Mode::FAULT && sample_hw.fault == "StallGuard UART failure");
}

void test_stop_retry_and_timeout() {
  FakeHardware hw;
  Controller controller(hw, defaults());
  start_release(hw, controller);
  controller.open();
  assert(hw.rejected == "Movement already in progress" && controller.mode() == Mode::RELEASE);
  controller.stop();
  assert(controller.mode() == Mode::FAULT && controller.position() == Position::UNKNOWN);
  assert(hw.fault == "Stopped; home required" && !hw.enabled);
  controller.close();
  assert(hw.rejected == "Inspect the fault and press Home to retry");
  controller.home();
  finish_preparation(hw, controller, Mode::PREPARE_RELEASE, Mode::ARM_RELEASE);

  FakeHardware timeout_hw;
  Controller timeout(timeout_hw, defaults());
  start_release(timeout_hw, timeout);
  timeout_hw.advance(15001);
  timeout.tick();
  assert(timeout.mode() == Mode::FAULT && timeout_hw.fault == "Movement timed out" && !timeout_hw.enabled);

  FakeHardware diag_hw;
  diag_hw.diag_high = true;
  Controller diag(diag_hw, defaults());
  diag.begin();
  diag_hw.advance(30);
  diag.tick();
  diag_hw.advance(300);
  diag.tick();
  assert(diag.mode() == Mode::FAULT && diag_hw.fault == "DIAG active before movement");
  assert(!diag_hw.enabled);
}

void test_startup_diag_and_idle_reset() {
  FakeHardware boot_hw;
  boot_hw.diag_high = true;
  Controller boot(boot_hw, defaults());
  boot.begin();
  assert(boot.mode() == Mode::PREPARE_RELEASE && !boot_hw.enabled);
  boot_hw.advance(30);
  boot.tick();
  assert(boot_hw.configure_count == 1 && boot_hw.diag_high && !boot_hw.enabled);
  boot_hw.advance(30);
  boot.tick();
  assert(boot.mode() == Mode::PREPARE_RELEASE && !boot_hw.enabled);
  boot_hw.diag_high = false;
  boot.tick();
  assert(boot.mode() == Mode::ARM_COIL_TEST && boot_hw.enabled);

  FakeHardware idle_hw;
  Controller idle(idle_hw, defaults());
  home_closed(idle_hw, idle);
  idle_hw.health_ok = false;
  idle_hw.advance(1000);
  idle.tick();
  assert(idle.mode() == Mode::FAULT && idle.position() == Position::UNKNOWN);
  assert(idle_hw.fault == "Driver fault or UART failure" && !idle_hw.enabled);
  assert(idle_hw.configure_count == 1);

  FakeHardware command_hw;
  Controller command(command_hw, defaults());
  home_closed(command_hw, command);
  command_hw.health_ok = false;
  command.open();
  command_hw.advance(30);
  command.tick();
  assert(command.mode() == Mode::FAULT && command.position() == Position::UNKNOWN);
  assert(command_hw.configure_count == 1 && !command_hw.enabled);

  FakeHardware feedback_hw;
  feedback_hw.stuck_enabled = true;
  Controller feedback(feedback_hw, defaults());
  feedback.begin();
  feedback_hw.advance(20);
  feedback.tick();
  assert(feedback.mode() == Mode::PREPARE_RELEASE);
  feedback_hw.stuck_enabled = false;
  feedback_hw.advance(10);
  feedback.tick();
  assert(feedback.mode() == Mode::PREPARE_RELEASE && feedback_hw.configure_count == 1);
}

void test_coil_preflight() {
  FakeHardware hw;
  Controller controller(hw, defaults());
  controller.begin();
  start_coil_test(hw, controller, Mode::PREPARE_RELEASE);
  assert(hw.target == 80);
  hw.coil_ok = false;
  hw.steps = 63;
  controller.tick();
  assert(controller.mode() == Mode::COIL_TEST && hw.enabled);
  hw.steps = 64;
  controller.tick();
  assert(controller.mode() == Mode::FAULT && hw.fault == "Open coil or driver fault");
  assert(!hw.enabled && hw.driver_mode == DriverMode::SPREAD_CYCLE && hw.mode_changes == 1);

  FakeHardware diag_hw;
  Controller diag(diag_hw, defaults());
  diag.begin();
  start_coil_test(diag_hw, diag, Mode::PREPARE_RELEASE);
  diag_hw.diag_high = true;
  diag.tick();
  assert(diag.mode() == Mode::FAULT && diag_hw.fault == "DIAG active during coil test" && !diag_hw.enabled);

  FakeHardware switch_hw;
  Controller switching(switch_hw, defaults());
  switching.begin();
  start_coil_test(switch_hw, switching, Mode::PREPARE_RELEASE);
  switch_hw.steps = 64;
  switch_hw.mode_change_ok = false;
  switching.tick();
  assert(switching.mode() == Mode::FAULT && switch_hw.fault == "Driver chopper configuration failed");
  assert(!switch_hw.enabled);

  FakeHardware late_hw;
  Controller late(late_hw, defaults());
  late.begin();
  start_coil_test(late_hw, late, Mode::PREPARE_RELEASE);
  late_hw.steps = 64;
  late.tick();
  assert(late.mode() == Mode::WAIT_STEALTH && !late_hw.enabled);
  late.diag_sample(true);
  assert(late.mode() == Mode::FAULT && late_hw.fault == "DIAG during coil test");

  FakeHardware bound_hw;
  Controller bound(bound_hw, defaults());
  bound.begin();
  start_coil_test(bound_hw, bound, Mode::PREPARE_RELEASE);
  bound_hw.steps = 80;
  bound.tick();
  assert(bound.mode() == Mode::FAULT && !bound_hw.enabled);
  assert(bound_hw.fault == "Coil test ended before sampling");

  FakeHardware known_hw;
  Controller known(known_hw, defaults());
  home_closed(known_hw, known);
  known.open();
  start_coil_test(known_hw, known, Mode::PREPARE_OPEN);
  assert(known_hw.target == 80);
  known_hw.steps = 79;
  known.tick();
  known_hw.advance(30);
  known.tick();
  known_hw.advance(200);
  known.tick();
  assert(known.mode() == Mode::OPENING && known_hw.target == 881);
  known_hw.steps = 561;
  known_hw.diag_high = true;
  known.tick();
  assert(known.position() == Position::OPEN);

  FakeHardware wrong_mode_hw;
  Controller wrong_mode(wrong_mode_hw, defaults());
  wrong_mode.begin();
  arm_coil_test(wrong_mode_hw, wrong_mode, Mode::PREPARE_RELEASE);
  wrong_mode_hw.driver_mode = DriverMode::STEALTH_CHOP;
  wrong_mode_hw.advance(30);
  wrong_mode.tick();
  assert(wrong_mode.mode() == Mode::FAULT && !wrong_mode_hw.enabled);

  FakeHardware stop_hw;
  Controller stop(stop_hw, defaults());
  stop.begin();
  start_coil_test(stop_hw, stop, Mode::PREPARE_RELEASE);
  stop_hw.steps = 10;
  stop.stop();
  assert(stop.mode() == Mode::FAULT && stop_hw.target == 10 && !stop_hw.enabled);
}

void test_short_diag_pulses() {
  FakeHardware hw;
  Controller controller(hw, defaults());
  home_closed(hw, controller);
  start_open(hw, controller);
  hw.steps = 736;
  assert(!hw.diag_high);
  controller.diag_sample(false);
  assert(controller.mode() == Mode::OPENING && hw.diag_updates == 1);
  controller.diag_sample(true);
  assert(controller.position() == Position::OPEN && hw.state == "Open" && !hw.enabled);

  FakeHardware early_hw;
  Controller early(early_hw, defaults());
  home_closed(early_hw, early);
  start_open(early_hw, early);
  early_hw.steps = 10;
  early.diag_sample(true);
  assert(early.mode() == Mode::FAULT && early_hw.fault == "Unexpected stall before end position");

  FakeHardware arming_hw;
  Controller arming(arming_hw, defaults());
  arming.begin();
  arm_coil_test(arming_hw, arming, Mode::PREPARE_RELEASE);
  arming.diag_sample(true);
  arming_hw.advance(30);
  arming.tick();
  assert(arming.mode() == Mode::FAULT && arming_hw.fault == "DIAG active before coil test");

  FakeHardware stealth_hw;
  Controller stealth(stealth_hw, defaults());
  home_closed(stealth_hw, stealth);
  stealth.open();
  finish_preparation(stealth_hw, stealth, Mode::PREPARE_OPEN, Mode::ARM_OPEN);
  stealth.diag_sample(true);
  stealth_hw.advance(30);
  stealth.tick();
  assert(stealth.mode() == Mode::FAULT && stealth_hw.fault == "DIAG active before movement");

  FakeHardware missing_hw;
  missing_hw.diag_monitor_ok = false;
  Controller missing(missing_hw, defaults());
  missing.begin();
  missing.tick();
  assert(missing.mode() == Mode::FAULT && missing_hw.fault == "DIAG monitoring unavailable");
  assert(!missing_hw.enabled && missing_hw.configure_count == 0);

  FakeHardware idle_hw;
  Controller idle(idle_hw, defaults());
  home_closed(idle_hw, idle);
  idle_hw.advance(300);
  idle.diag_sample(true);
  assert(idle.mode() == Mode::FAULT && idle.position() == Position::UNKNOWN);
}

void test_timer_wrap() {
  FakeHardware hw;
  hw.now = UINT32_MAX - 10;
  Controller controller(hw, defaults());
  start_release(hw, controller);
  assert(controller.mode() == Mode::RELEASE);
}

void test_tmc_protocol() {
  uint8_t request[4];
  waste_valve::tmc2209::read_request(0, 0, request);
  const uint8_t expected[] = {0x05, 0x00, 0x00, 0x48};
  assert(std::memcmp(request, expected, sizeof(expected)) == 0);

  uint8_t write[8];
  waste_valve::tmc2209::write_request(2, 0x40, 0x12345678, write);
  assert(write[0] == 5 && write[1] == 2 && write[2] == 0xC0);
  assert(write[3] == 0x12 && write[4] == 0x34 && write[5] == 0x56 && write[6] == 0x78);
  assert(write[7] == waste_valve::tmc2209::crc(write, 7));

  uint8_t reply[8] = {0x05, 0xFF, 0x06, 0x21, 0x34, 0x56, 0x78, 0};
  reply[7] = waste_valve::tmc2209::crc(reply, 7);
  uint32_t value = 0;
  assert(waste_valve::tmc2209::decode_reply(0x06, reply, value) && value == 0x21345678);
  assert(!waste_valve::tmc2209::decode_reply(0x01, reply, value));
  reply[4] ^= 1;
  assert(!waste_valve::tmc2209::decode_reply(0x06, reply, value));
}

int main() {
  test_boot_and_normal_cycle();
  test_commissioning_and_options();
  test_release_stall_and_home_threshold();
  test_known_travel_limits();
  test_interlock_and_driver_faults();
  test_stop_retry_and_timeout();
  test_startup_diag_and_idle_reset();
  test_coil_preflight();
  test_short_diag_pulses();
  test_timer_wrap();
  test_tmc_protocol();
  std::cout << "Waste valve controller and UART tests passed\n";
}
