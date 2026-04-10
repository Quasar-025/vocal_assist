# ESP32 Wiring (DevKit V1)

## Components
- ESP32 DevKit V1 (WROOM-32)
- 2x flex sensors (with voltage divider)
- MPU6050 (I2C)
- 0.96" OLED SSD1306 (I2C, 128x64)

## Pin Mapping
- Flex Sensor 1 analog output -> GPIO34 (ADC1_CH6)
- Flex Sensor 2 analog output -> GPIO35 (ADC1_CH7)
- MPU6050 SDA -> GPIO21
- MPU6050 SCL -> GPIO22
- OLED SDA -> GPIO21
- OLED SCL -> GPIO22
- MPU6050 VCC -> 3V3
- MPU6050 GND -> GND
- OLED VCC -> 3V3
- OLED GND -> GND

## Flex Sensor Divider (for each flex)
Use a voltage divider to convert resistance changes into analog voltage:
- One side of flex sensor -> 3V3
- Other side of flex sensor -> analog pin (GPIO34 or GPIO35)
- 10k resistor from analog pin -> GND

This gives an ADC voltage that changes with bend amount.

## I2C Notes
- Typical MPU6050 address: `0x68`
- Typical SSD1306 address: `0x3C`
- Both share the same I2C bus (GPIO21/22)

## BLE Packet Contract
The sketch sends gesture IDs as ASCII with newline:
- `1\n` = Fist
- `2\n` = Open Palm
- `3\n` = Point
- `4\n` = OK
- `5\n` = Wave Left
- `6\n` = Wave Right

This matches the Flutter app parser.

## Arduino Libraries Required
Install from Library Manager:
- Adafruit MPU6050
- Adafruit Unified Sensor
- Adafruit SSD1306
- Adafruit GFX Library

BLE headers are from ESP32 board package.

## First-Time Calibration
1. Power on with hand in neutral position.
2. Keep fingers still for ~2 seconds.
3. Watch serial log for baseline values.
4. Adjust thresholds in `esp32_vocal_assist.ino` if gestures overlap.
