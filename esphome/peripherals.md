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
- rain detector - using ADC with selectable threshold for rain (set from homeassistant)
- VL6180X range sensor
- Schaudt LT453 panel replacement - three connectors

not implemented:
- VL53L0X Time-of-Flight range sensor
