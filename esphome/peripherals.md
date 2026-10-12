general:
- use power saving modes, low wifi tx/rx power (esp board and phone is close to each other)
- disable other not used peripherals (bluetooth,...)

sensors and actuators:

- onboard RGB LED module as a status notification. Eg. blinking violet for connecting to wifi, red when error, slow green if everything is OK
- 1-wire temperature (3 dallas temperature sensors)
- bme280 temperature, humidity, pressure sensor
- truma_inetbox
- phone charger driver (io pin to turn on/off phone charger). Phone is used as Homeassistant server.
- PIR motion detection sensor
- fresh and waste water sensors - each has 5 pins, one common and 4 used for level detection
- accelerometer MPU6050 will NOT be used (we will use phone`s sensor to detect pitch and roll)
- INA219 I2C bi-directional battery power monitoring, using schunt
- esphymer2 is the existing ESP32-C3 Super Mini + nRF24 roof-vent controller, extended with BME280, INA219, INA226, VL6180X, D+ and T2/T3; no separate vent-remote board
- roof-vent power, fan speed/direction, lid, rain enable and resend via `peripherals/vent_remote.yaml`
- starter battery voltage (8-15 V) on esphymer2 via INA226 at I2C 0x41, with TVS-protected sense input; see [wiring and calibration](../docs/hardware/esp32s3-wiring-guide.md#starter-battery-voltage-8-15-v)
- rain detector - using ADC with selectable threshold for rain (set from homeassistant)
- VL6180X range sensor
- Schaudt LT453 panel replacement - three connectors

not implemented:
- VL53L0X Time-of-Flight range sensor
