#pragma once

#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <string>

template<typename... T> inline void test_log(T &&...) {}
#define ESP_LOGE(...) test_log(__VA_ARGS__)
#define ESP_LOGI(...) test_log(__VA_ARGS__)
#define ESP_LOGW(...) test_log(__VA_ARGS__)

namespace esphome {

inline uint32_t test_time{0};
inline uint32_t millis() { return test_time; }

namespace uart {
enum class UARTFlushResult {
  UART_FLUSH_RESULT_SUCCESS,
  UART_FLUSH_RESULT_TIMEOUT,
  UART_FLUSH_RESULT_FAILED,
  UART_FLUSH_RESULT_ASSUMED_SUCCESS,
};
class UARTComponent {
 public:
  virtual ~UARTComponent() = default;
  virtual void write_array(const uint8_t *, size_t) = 0;
  virtual UARTFlushResult flush() = 0;
  virtual bool read_array(uint8_t *, size_t) = 0;
  virtual size_t available() = 0;
  bool read_byte(uint8_t *byte) { return read_array(byte, 1); }
};
}  // namespace uart

namespace stepper {
class Stepper {
 public:
  int32_t current_position{0};
  int32_t target_position{0};
  void report_position(int32_t value) { current_position = value; }
  void set_target(int32_t value) { target_position = value; }
};
}  // namespace stepper

namespace switch_ {
class Switch {
 public:
  bool state{false};
  void turn_on() { state = true; }
  void turn_off() { state = false; }
};
}  // namespace switch_

namespace binary_sensor {
class BinarySensor {
 public:
  bool state{false};
  bool has_value{true};
  bool has_state() const { return has_value; }
  void publish_state(bool value) { state = value; }
};
}  // namespace binary_sensor

namespace text_sensor {
class TextSensor {
 public:
  std::string state;
  void publish_state(const char *value) { state = value; }
};
}  // namespace text_sensor

namespace sensor {
class Sensor {
 public:
  float state{0};
  bool has_value{true};
  bool has_state() const { return has_value; }
  void publish_state(float value) { state = value; }
};
}  // namespace sensor

namespace pulse_counter {
class PulseCounterSensor : public sensor::Sensor {
 public:
  bool failed{false};
  bool is_failed() const { return failed; }
};
}  // namespace pulse_counter

}  // namespace esphome
