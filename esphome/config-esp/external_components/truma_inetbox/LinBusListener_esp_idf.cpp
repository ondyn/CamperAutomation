#ifdef USE_ESP32_FRAMEWORK_ESP_IDF
#include "LinBusListener.h"
#include "esphome/core/log.h"
#include "soc/uart_reg.h"
#include "esphome/components/uart/uart_component_esp_idf.h"
// ESPHome 2026+ removed get_uart_event_queue() from IDFUARTComponent.
// We own the event queue ourselves — see setup_framework().
#define ESPHOME_UART uart::IDFUARTComponent

namespace esphome {
namespace truma_inetbox {

static const char *const TAG = "truma_inetbox.LinBusListener";

#define QUEUE_WAIT_BLOCKING (TickType_t) portMAX_DELAY

void LinBusListener::setup_framework() {
  auto uartComp = static_cast<ESPHOME_UART *>(this->parent_);
  uart_port_t uart_num = static_cast<uart_port_t>(uartComp->get_hw_serial_number());

  // ESPHome 2026+ installs the UART driver without an event queue (queue_size=0, null handle).
  // We need UART_BREAK events from ESP-IDF to detect LIN break signals, which requires an event
  // queue. Reinstall the driver with our own queue; hardware config (baud rate, stop bits, pin
  // routing) survives uart_driver_delete/install cycles and does not need to be reapplied.
  if (uart_is_driver_installed(uart_num)) {
    uart_driver_delete(uart_num);
  }
  esp_err_t err = uart_driver_install(uart_num, 512, 0, 20, &this->uart_event_queue_, 0);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, " -- UART%d driver reinstall failed: %s", uart_num, esp_err_to_name(err));
    return;
  }

  // Tweak FIFO interrupts so data is available as soon as the first byte is received.
  // Must be called after uart_driver_install.
  uart_intr_config_t uart_intr;
  uart_intr.intr_enable_mask =
      UART_RXFIFO_FULL_INT_ENA_M | UART_RXFIFO_TOUT_INT_ENA_M;  // only these IRQs
  uart_intr.rxfifo_full_thresh = 1;
  uart_intr.rx_timeout_thresh = 10;
  uart_intr.txfifo_empty_intr_thresh = 10;
  uart_intr_config(uart_num, &uart_intr);

  // Creating UART event Task
  xTaskCreatePinnedToCore(LinBusListener::uartEventTask_,
                          "uart_event_task",                      // name
                          ARDUINO_SERIAL_EVENT_TASK_STACK_SIZE,   // stack size (in words)
                          this,                                   // input params
                          24,                                     // priority
                          &this->uartEventTaskHandle_,            // handle
                          ARDUINO_SERIAL_EVENT_TASK_RUNNING_CORE  // core
  );
  if (this->uartEventTaskHandle_ == NULL) {
    ESP_LOGE(TAG, " -- UART%d Event Task not created!", uart_num);
  }

  // Creating LIN msg event Task
  xTaskCreatePinnedToCore(LinBusListener::eventTask_,
                          "lin_event_task",                       // name
                          ARDUINO_SERIAL_EVENT_TASK_STACK_SIZE,   // stack size (in words)
                          this,                                   // input params
                          2,                                      // priority
                          &this->eventTaskHandle_,                // handle
                          ARDUINO_SERIAL_EVENT_TASK_RUNNING_CORE  // core
  );
  if (this->eventTaskHandle_ == NULL) {
    ESP_LOGE(TAG, " -- LIN message Task not created!");
  }
}

void LinBusListener::uartEventTask_(void *args) {
  LinBusListener *instance = (LinBusListener *) args;
  uart_event_t event;
  for (;;) {
    // Waiting for UART event (queue owned by LinBusListener, see setup_framework).
    if (xQueueReceive(instance->uart_event_queue_, (void *) &event, QUEUE_WAIT_BLOCKING)) {
      if (event.type == UART_DATA && instance->available() > 0) {
        instance->onReceive_();
      } else if (event.type == UART_BREAK) {
        // If the break is valid the `onReceive` is called first and the break is handeld. Therfore the expectation is
        // that the state should be in waiting for `SYNC`.
        if (instance->current_state_ != READ_STATE_SYNC) {
          instance->current_state_ = READ_STATE_BREAK;
        }
      }
    }
  }
  vTaskDelete(NULL);
}

void LinBusListener::eventTask_(void *args) {
  LinBusListener *instance = (LinBusListener *) args;
  for (;;) {
    instance->process_lin_msg_queue(QUEUE_WAIT_BLOCKING);
  }
}

}  // namespace truma_inetbox
}  // namespace esphome

#undef QUEUE_WAIT_BLOCKING
#undef ESPHOME_UART

#endif  // USE_ESP32_FRAMEWORK_ESP_IDF