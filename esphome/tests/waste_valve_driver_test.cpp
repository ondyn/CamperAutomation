#include <cassert>
#include <cmath>
#include <cstdint>
#include <deque>
#include <iostream>

#include "../config-esp/waste_valve_esphome.h"

class FakeUART final : public esphome::uart::UARTComponent {
 public:
  uint32_t registers[128]{};
  std::deque<uint8_t> received;
  int ignored_write{-1};
  int invalid_reply{-1};
  int wrong_readback{-1};
  bool missing_echo{false};
  bool missing_reply{false};

  FakeUART() {
    registers[0x06] = 0x21000000;
    registers[0x01] = 1;
    registers[0x6F] = 1u << 30;
  }

  void write_array(const uint8_t *data, size_t length) override {
    assert(length == 4 || length == 8);
    assert(data[length - 1] == waste_valve::tmc2209::crc(data, length - 1));
    if (!missing_echo)
      for (size_t i = 0; i < length; ++i)
        received.push_back(data[i]);

    const uint8_t reg = data[2] & 0x7F;
    if (length == 8) {
      if (reg == ignored_write)
        return;
      const uint32_t value = (static_cast<uint32_t>(data[3]) << 24) | (static_cast<uint32_t>(data[4]) << 16) |
                             (static_cast<uint32_t>(data[5]) << 8) | data[6];
      if (reg == 0x01)
        registers[reg] &= ~value;
      else
        registers[reg] = value;
      if (reg == 0x00) {
        if ((value & (1u << 2)) != 0)
          registers[0x6F] &= ~(1u << 30);
        else
          registers[0x6F] |= 1u << 30;
      }
      registers[0x02] = (registers[0x02] + 1) & 0xFF;
      return;
    }

    if (missing_reply)
      return;
    uint32_t value = registers[reg];
    if (reg == wrong_readback)
      value ^= 1;
    uint8_t reply[8] = {0x05, 0xFF, reg, static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16),
                        static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value), 0};
    reply[7] = waste_valve::tmc2209::crc(reply, 7);
    if (reg == invalid_reply)
      reply[7] ^= 1;
    for (uint8_t byte : reply)
      received.push_back(byte);
  }

  esphome::uart::UARTFlushResult flush() override {
    return esphome::uart::UARTFlushResult::UART_FLUSH_RESULT_SUCCESS;
  }
  bool read_array(uint8_t *out, size_t length) override {
    if (received.size() < length)
      return false;
    for (size_t i = 0; i < length; ++i) {
      out[i] = received.front();
      received.pop_front();
    }
    return true;
  }
  size_t available() override { return received.size(); }
};

struct TestRig {
  FakeUART uart;
  esphome::stepper::Stepper motor;
  esphome::switch_::Switch enable;
  esphome::binary_sensor::BinarySensor feedback;
  esphome::binary_sensor::BinarySensor diag;
  esphome::pulse_counter::PulseCounterSensor diag_edges;
  esphome::text_sensor::TextSensor position;
  esphome::text_sensor::TextSensor fault;
  esphome::binary_sensor::BinarySensor ready;
  esphome::sensor::Sensor stallguard;

  waste_valve::ESPHomeHardware make(float rsense = 0.11f, float current = 0.35f, uint32_t address = 0,
                                   uint32_t threshold = 50) {
    return {&uart, &motor, &enable, &feedback, &diag, &diag_edges, &position, &fault, &ready, &stallguard, address,
            threshold, rsense, current};
  }
};

void test_configuration() {
  TestRig rig;
  auto driver = rig.make();
  assert(driver.configure_driver());
  assert(rig.uart.registers[0x00] == 0xC0);
  assert(rig.uart.registers[0x6C] == 0x14030053);
  assert(rig.uart.registers[0x10] == 0x00080A0A);
  assert(rig.uart.registers[0x13] == 0);
  assert(rig.uart.registers[0x14] == 0xFFFFF);
  assert(rig.uart.registers[0x40] == 50);
  assert(rig.uart.registers[0x42] == 0);
  assert(rig.uart.registers[0x22] == 0);
  assert(rig.uart.registers[0x70] == 0xC80D0E24);
  assert(rig.uart.registers[0x02] == 11);
  assert(rig.uart.registers[0x01] == 0);

  rig.uart.registers[0x41] = 314;
  assert(driver.sample_stallguard() && rig.stallguard.state == 314);
  driver.publish("Closed", "None", true);
  assert(rig.position.state == "Closed" && rig.fault.state == "None" && rig.ready.state);
  assert(std::isnan(rig.stallguard.state));
}

void test_transport_and_configuration_failures() {
  TestRig version;
  version.uart.registers[0x06] = 0x20000000;
  assert(!version.make().configure_driver());

  TestRig spread_pin;
  spread_pin.uart.registers[0x06] |= 1u << 8;
  assert(!spread_pin.make().configure_driver());

  TestRig echo;
  echo.uart.missing_echo = true;
  assert(!echo.make().configure_driver());

  TestRig timeout;
  timeout.uart.missing_reply = true;
  assert(!timeout.make().configure_driver());

  TestRig crc;
  crc.uart.invalid_reply = 0x06;
  assert(!crc.make().configure_driver());

  TestRig write;
  write.uart.ignored_write = 0x40;
  assert(!write.make().configure_driver());

  TestRig readback;
  readback.uart.wrong_readback = 0x6C;
  assert(!readback.make().configure_driver());

  TestRig current;
  assert(!current.make(0.11f, 0.0f).configure_driver());
  assert(!current.make(0.11f, 1.21f).configure_driver());
  assert(!current.make(0.0f, 0.35f).configure_driver());
  assert(!current.make(0.11f, 0.35f, 4).configure_driver());
  assert(!current.make(0.11f, 0.35f, 0, 256).configure_driver());
}

void test_chopper_modes_and_open_load() {
  using waste_valve::DriverMode;
  TestRig rig;
  auto driver = rig.make();
  assert(driver.configure_driver());
  assert(driver.set_driver_mode(DriverMode::SPREAD_CYCLE));
  assert(rig.uart.registers[0x00] == 0xC4);
  assert(driver.check_driver(true, DriverMode::SPREAD_CYCLE));
  assert(!driver.check_driver(false, DriverMode::STEALTH_CHOP));
  rig.uart.registers[0x6F] |= 1u << 31;
  assert(!driver.check_driver(true, DriverMode::SPREAD_CYCLE));
  rig.uart.registers[0x6F] &= ~(1u << 31);
  rig.uart.registers[0x6F] |= 1u << 6;
  assert(!driver.check_driver(true, DriverMode::SPREAD_CYCLE));
  rig.uart.registers[0x6F] &= ~(1u << 6);
  assert(driver.set_driver_mode(DriverMode::STEALTH_CHOP));
  assert(driver.check_driver(false, DriverMode::STEALTH_CHOP));
  assert(!driver.set_driver_mode(DriverMode::ANY));

  rig.uart.ignored_write = 0x00;
  assert(!driver.set_driver_mode(DriverMode::SPREAD_CYCLE));
  rig.uart.ignored_write = -1;
  rig.uart.registers[0x06] |= 1u << 8;
  assert(!driver.set_driver_mode(DriverMode::SPREAD_CYCLE));
}

void test_runtime_faults() {
  TestRig rig;
  auto driver = rig.make();
  assert(driver.configure_driver());

  rig.uart.registers[0x01] = 1;
  assert(!driver.check_driver(false));
  rig.uart.registers[0x01] = 0;
  rig.uart.registers[0x6F] |= 1u << 1;
  assert(!driver.check_driver(false));
  rig.uart.registers[0x6F] = (1u << 30) | (1u << 6);
  assert(driver.check_driver(false));
  assert(!driver.check_driver(true));
  rig.uart.invalid_reply = 0x41;
  assert(!driver.sample_stallguard());

  rig.feedback.has_value = false;
  rig.diag.has_value = false;
  assert(driver.enable_feedback());
  assert(driver.diag());
  rig.diag_edges.has_value = false;
  assert(!driver.diag_monitor_ready());
  rig.diag_edges.has_value = true;
  rig.diag_edges.failed = true;
  assert(!driver.diag_monitor_ready());
  rig.diag_edges.failed = false;
  esphome::test_time = 501;
  assert(!driver.diag_monitor_ready());
  driver.diag_monitor_updated();
  assert(driver.diag_monitor_ready());
  esphome::test_time = 0;
}

int main() {
  test_configuration();
  test_transport_and_configuration_failures();
  test_chopper_modes_and_open_load();
  test_runtime_faults();
  std::cout << "Waste valve driver and UART failure tests passed\n";
}
