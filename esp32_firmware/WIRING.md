# ESP32 Wiring (DevKit V1)

## Components
- ESP32 DevKit V1 (WROOM-32)
- 2x flex sensors (with voltage divider)
- 0.96" OLED SSD1306 (I2C, 128x64)

MPU6050 is optional. The latest firmware runs in flex-only mode if MPU is not connected.

## Pin Mapping
- Flex Sensor 1 analog output -> GPIO34 (ADC1_CH6)
- Flex Sensor 2 analog output -> GPIO35 (ADC1_CH7)
- OLED SDA -> GPIO21
- OLED SCL -> GPIO22
- OLED VCC -> 3V3
- OLED GND -> GND

## Minimum Connections (Without MPU6050)
- ESP32 3V3 -> Flex1 one side
- ESP32 GND -> 10k resistor lower side for Flex1 divider
- ESP32 GPIO34 -> junction between Flex1 and 10k resistor

- ESP32 3V3 -> Flex2 one side
- ESP32 GND -> 10k resistor lower side for Flex2 divider
- ESP32 GPIO35 -> junction between Flex2 and 10k resistor

- ESP32 3V3 -> OLED VCC
- ESP32 GND -> OLED GND
- ESP32 GPIO21 -> OLED SDA
- ESP32 GPIO22 -> OLED SCL

## Flex Sensor Divider (for each flex)
Use a voltage divider to convert resistance changes into analog voltage:
- One side of flex sensor -> 3V3
- Other side of flex sensor -> analog pin (GPIO34 or GPIO35)
- 10k resistor from analog pin -> GND

This gives an ADC voltage that changes with bend amount.

## I2C Notes
- Typical SSD1306 address: `0x3C`
- OLED uses I2C bus (GPIO21/22). If MPU is present, it can share this bus.

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
