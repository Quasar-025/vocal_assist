#include <Wire.h>
#include <math.h>

#include <Adafruit_GFX.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_SSD1306.h>
#include <Adafruit_Sensor.h>

#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

// =========================
// Hardware Pins (ESP32 DevKit V1)
// =========================
static const int FLEX1_PIN = 34;  // ADC1_CH6
static const int FLEX2_PIN = 35;  // ADC1_CH7
static const int I2C_SDA = 21;
static const int I2C_SCL = 22;

// =========================
// OLED Config
// =========================
static const int SCREEN_WIDTH = 128;
static const int SCREEN_HEIGHT = 64;
static const uint8_t OLED_ADDR = 0x3C;
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

// =========================
// MPU6050
// =========================
Adafruit_MPU6050 mpu;
bool mpuAvailable = false;

// =========================
// BLE Config
// =========================
static const char* BLE_DEVICE_NAME = "VocalAssist-ESP32";
static const char* SERVICE_UUID = "7f9e1167-95e5-4afb-8f4e-91b0d5134d44";
static const char* GESTURE_CHAR_UUID = "c9f1e18f-78f0-4d5b-a0cb-bc8fc4e6719c";

BLEServer* bleServer = nullptr;
BLECharacteristic* gestureChar = nullptr;
bool bleConnected = false;

class GestureServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    bleConnected = true;
  }

  void onDisconnect(BLEServer* pServer) override {
    bleConnected = false;
    BLEDevice::startAdvertising();
  }
};

// =========================
// Gesture IDs (must match Flutter app)
// =========================
enum GestureId {
  G_NONE = 0,
  G_FIST = 1,
  G_OPEN_PALM = 2,
  G_POINT = 3,
  G_OK = 4,
  G_WAVE_LEFT = 5,
  G_WAVE_RIGHT = 6,
};

const char* gestureName(uint8_t gesture) {
  switch (gesture) {
    case G_FIST: return "Fist";
    case G_OPEN_PALM: return "Open Palm";
    case G_POINT: return "Point";
    case G_OK: return "OK";
    case G_WAVE_LEFT: return "Wave Left";
    case G_WAVE_RIGHT: return "Wave Right";
    default: return "None";
  }
}

// =========================
// Runtime state
// =========================
float flex1Baseline = 0.0f;
float flex2Baseline = 0.0f;
float flex1Filtered = 0.0f;
float flex2Filtered = 0.0f;

uint8_t lastCandidate = G_NONE;
uint8_t stableGesture = G_NONE;
int stableCount = 0;
unsigned long lastGestureSentAt = 0;
unsigned long lastDisplayAt = 0;
unsigned long lastAnyPublishAt = 0;
bool flex2InvalidNow = false;

// Thresholds for your glove setup. Tune from Serial output.
// Tuned for observed max around ~300 on OLED.
float FLEX_LOW = 30.0f;
float FLEX_MID = 110.0f;
float FLEX_HIGH = 200.0f;
float WAVE_GYRO_THRESHOLD = 130.0f;

// MPU orientation thresholds tuned for user-reported ranges:
// pitch ~ [-25, 50], roll ~ [-30, 25]
float PITCH_UP_HIGH = 24.0f;
float PITCH_DOWN_LOW = -8.0f;
float ROLL_RIGHT_HIGH = 12.0f;
float ROLL_LEFT_LOW = -12.0f;

static const int STABLE_FRAMES_REQUIRED = 2;
static const unsigned long MIN_SEND_GAP_MS = 400;
static const unsigned long FORCE_RESEND_MS = 2000;
static const float LPF_ALPHA = 0.20f;

void setupBle() {
  BLEDevice::init(BLE_DEVICE_NAME);
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new GestureServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);
  gestureChar = service->createCharacteristic(
    GESTURE_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  gestureChar->addDescriptor(new BLE2902());
  gestureChar->setValue("0\n");

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
}

void setupMpu() {
  mpuAvailable = mpu.begin();
  if (!mpuAvailable) {
    Serial.println("[WARN] MPU6050 not detected, running in flex-only mode");
    return;
  }

  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
}

uint8_t classifyGestureFlexOnly(float bend1, float bend2) {
  // Both relaxed: treat as open palm so app always has a meaningful state.
  if (bend1 < FLEX_LOW && bend2 < FLEX_LOW) {
    return G_OPEN_PALM;
  }

  // Strong bends on both sensors.
  if (bend1 > FLEX_HIGH && bend2 > FLEX_HIGH) {
    return G_FIST;
  }

  // Directional two-sensor patterns.
  if (bend1 > FLEX_HIGH && bend2 < FLEX_LOW) {
    return G_POINT;
  }

  if (bend2 > FLEX_HIGH && bend1 < FLEX_LOW) {
    return G_WAVE_LEFT;
  }

  if (bend1 > FLEX_MID && bend1 < FLEX_HIGH &&
      bend2 > FLEX_MID && bend2 < FLEX_HIGH) {
    return G_OK;
  }

  // Single-sensor fallback: if only one sensor responds, still emit gestures.
  if (bend1 > FLEX_HIGH || bend2 > FLEX_HIGH) {
    return (bend1 >= bend2) ? G_POINT : G_WAVE_LEFT;
  }

  if (bend1 > FLEX_MID || bend2 > FLEX_MID) {
    return (bend1 >= bend2) ? G_OK : G_WAVE_RIGHT;
  }

  return G_NONE;
}

void setupDisplay() {
  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    Serial.println("[ERR] OLED not detected");
    while (true) {
      delay(1000);
    }
  }

  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println("Vocal Assist Boot");
  display.display();
}

void calibrateFlexSensors() {
  const int samples = 250;
  uint32_t sum1 = 0;
  uint32_t sum2 = 0;

  for (int i = 0; i < samples; i++) {
    sum1 += analogRead(FLEX1_PIN);
    sum2 += analogRead(FLEX2_PIN);
    delay(6);
  }

  flex1Baseline = static_cast<float>(sum1) / samples;
  flex2Baseline = static_cast<float>(sum2) / samples;

  flex1Filtered = flex1Baseline;
  flex2Filtered = flex2Baseline;

  Serial.printf("[CAL] Flex baseline: F1=%.1f F2=%.1f\n", flex1Baseline, flex2Baseline);
}

void pushGesture(uint8_t gestureId) {
  if (!bleConnected || gestureChar == nullptr) {
    return;
  }

  String payload = String(static_cast<int>(gestureId));
  payload += "\n";
  gestureChar->setValue(payload);
  gestureChar->notify();

  Serial.printf("[BLE] Sent gesture=%u (%s)\n", gestureId, gestureName(gestureId));
}

uint8_t classifyGesture(
  float bend1,
  float bend2,
  float pitchDeg,
  float rollDeg,
  float gyroZ,
  bool flex2Invalid
) {
  const float bend2Effective = flex2Invalid ? 0.0f : bend2;

  if (!mpuAvailable) {
    return classifyGestureFlexOnly(bend1, bend2Effective);
  }

  // Orientation gestures from MPU (work even with one flex sensor).
  if (pitchDeg >= PITCH_UP_HIGH) {
    return G_WAVE_RIGHT;
  }
  if (pitchDeg <= PITCH_DOWN_LOW) {
    return G_WAVE_LEFT;
  }
  if (rollDeg >= ROLL_RIGHT_HIGH) {
    return G_OK;
  }
  if (rollDeg <= ROLL_LEFT_LOW) {
    return G_FIST;
  }

  // Dynamic wave gestures from MPU should work even if one flex channel is noisy.
  if (fabs(gyroZ) > (WAVE_GYRO_THRESHOLD * 0.7f) && bend1 < FLEX_MID) {
    if (gyroZ > 0) {
      return G_WAVE_RIGHT;
    }
    return G_WAVE_LEFT;
  }

  if (bend1 > FLEX_HIGH && bend2Effective > (FLEX_MID * 0.6f)) {
    return G_FIST;
  }

  if (bend1 < FLEX_LOW && bend2Effective < FLEX_LOW) {
    return G_OPEN_PALM;
  }

  if (bend1 > FLEX_HIGH && bend2Effective < FLEX_MID) {
    return G_POINT;
  }

  if (bend1 > FLEX_MID && bend1 < FLEX_HIGH &&
      bend2Effective > FLEX_LOW && bend2Effective < FLEX_HIGH &&
      fabs(pitchDeg) < 30.0f && fabs(rollDeg) < 45.0f) {
    return G_OK;
  }

  // Single-sensor + MPU fallback if flex2 is floating/saturated.
  if (flex2Invalid) {
    if (bend1 > FLEX_HIGH) {
      return G_POINT;
    }
    if (bend1 > FLEX_MID) {
      return G_OK;
    }
    return G_OPEN_PALM;
  }

  return G_NONE;
}

void updateDisplay(
  uint8_t gesture,
  bool connected,
  float bend1,
  float bend2,
  float pitchDeg,
  float rollDeg,
  bool f2Bad
) {
  display.clearDisplay();
  display.setCursor(0, 0);
  display.print("BLE: ");
  display.println(connected ? "Connected" : "Waiting");

  display.setCursor(0, 14);
  display.print("Gesture: ");
  display.println(gestureName(gesture));

  display.setCursor(0, 28);
  display.printf("F1: %.0f", bend1);
  display.setCursor(68, 28);
  display.printf("F2: %.0f", bend2);

  display.setCursor(0, 42);
  display.printf("P:%.1f R:%.1f", pitchDeg, rollDeg);

  display.setCursor(0, 54);
  display.print("F2:");
  display.print(f2Bad ? "BAD" : "OK");
  display.print(" S:");
  display.print(stableCount);
  display.print("/");
  display.println(STABLE_FRAMES_REQUIRED);

  display.display();
}

void setup() {
  Serial.begin(115200);
  delay(300);

  analogReadResolution(12);

  Wire.begin(I2C_SDA, I2C_SCL);

  setupDisplay();
  setupMpu();
  setupBle();
  calibrateFlexSensors();

  Serial.println("[INFO] System ready");
}

void loop() {
  const int raw1 = analogRead(FLEX1_PIN);
  const int raw2 = analogRead(FLEX2_PIN);

  // Rail readings often indicate floating/disconnected analog input.
  flex2InvalidNow = (raw2 <= 20 || raw2 >= 4075);

  flex1Filtered = (LPF_ALPHA * raw1) + ((1.0f - LPF_ALPHA) * flex1Filtered);
  flex2Filtered = (LPF_ALPHA * raw2) + ((1.0f - LPF_ALPHA) * flex2Filtered);

  // Use absolute delta so wiring direction (increase/decrease on bend) both work.
  const float bend1 = fabs(flex1Filtered - flex1Baseline);
  const float bend2 = fabs(flex2Filtered - flex2Baseline);

  float pitchDeg = 0.0f;
  float rollDeg = 0.0f;
  float gyroZDeg = 0.0f;

  if (mpuAvailable) {
    sensors_event_t accel;
    sensors_event_t gyro;
    sensors_event_t temp;
    mpu.getEvent(&accel, &gyro, &temp);

    const float ax = accel.acceleration.x;
    const float ay = accel.acceleration.y;
    const float az = accel.acceleration.z;
    gyroZDeg = gyro.gyro.z * 57.2958f;

    pitchDeg = atan2(ax, sqrt((ay * ay) + (az * az))) * 57.2958f;
    rollDeg = atan2(ay, az) * 57.2958f;
  }

  uint8_t candidate = classifyGesture(
    bend1,
    bend2,
    pitchDeg,
    rollDeg,
    gyroZDeg,
    flex2InvalidNow
  );

  if (candidate == lastCandidate && candidate != G_NONE) {
    stableCount++;
  } else {
    stableCount = 1;
    lastCandidate = candidate;
  }

  const unsigned long now = millis();
  if (candidate != G_NONE && stableCount >= STABLE_FRAMES_REQUIRED) {
    const bool changedGesture = candidate != stableGesture;
    const bool minGapPassed = (now - lastGestureSentAt) >= MIN_SEND_GAP_MS;
    const bool forceResend = (now - lastAnyPublishAt) >= FORCE_RESEND_MS;

    if ((changedGesture && minGapPassed) || forceResend) {
      stableGesture = candidate;
      lastGestureSentAt = now;
      lastAnyPublishAt = now;
      pushGesture(candidate);
    }
  }

  if ((now - lastDisplayAt) > 180) {
    updateDisplay(
      stableGesture,
      bleConnected,
      bend1,
      bend2,
      pitchDeg,
      rollDeg,
      flex2InvalidNow
    );
    lastDisplayAt = now;
  }

  Serial.printf(
    "MPU=%d F2Bad=%d F1=%d F2=%d B1=%.1f B2=%.1f pitch=%.1f roll=%.1f gz=%.1f cand=%u stable=%u\n",
    mpuAvailable ? 1 : 0,
    flex2InvalidNow ? 1 : 0,
    raw1,
    raw2,
    bend1,
    bend2,
    pitchDeg,
    rollDeg,
    gyroZDeg,
    candidate,
    stableGesture
  );

  delay(40);
}
