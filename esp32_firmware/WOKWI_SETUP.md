# Wokwi Potentiometer Setup

Use this when app input mode is Wokwi.

## App side
- Open Live tab
- Select mode: Wokwi
- App listens on broker: broker.hivemq.com
- Topic: gesture_voice_app/wokwi/gesture

## Wokwi side
1. Create new project: ESP32 Arduino template (NOT ESP-IDF C template)
2. Add 2 potentiometers
3. Connections:
   - Pot1 left pin -> 3V3
   - Pot1 right pin -> GND
   - Pot1 wiper -> GPIO34
   - Pot2 left pin -> 3V3
   - Pot2 right pin -> GND
   - Pot2 wiper -> GPIO35
4. Install libraries in Wokwi:
   - PubSubClient
5. Paste sketch from esp32_firmware/wokwi_pot_mqtt.ino
6. Run simulation

## If you are using ESP-IDF template in Wokwi
If build output shows main/src/main.c and error WiFi.h not found, your project is ESP-IDF mode.

Use this file instead:
- esp32_firmware/wokwi_pot_mqtt_idf.c

And replace your main/src/main.c with that content.

## Gesture mapping used by the app and sketch
- Pot1 low + Pot2 low -> 1 (Fist)
- Pot1 mid + Pot2 low -> 2 (Open Palm)
- Pot1 high + Pot2 low -> 3 (Point)
- Pot1 low + Pot2 high -> 4 (OK)
- Pot1 mid + Pot2 high -> 5 (Wave Left)
- Pot1 high + Pot2 high -> 6 (Wave Right)

## Troubleshooting
- Keep app in Wokwi mode, not BLE/Camera.
- Ensure Wokwi serial monitor shows published gesture IDs.
- If app does not update, verify topic exactly: gesture_voice_app/wokwi/gesture.
