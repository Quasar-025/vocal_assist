#include <WiFi.h>
#include <PubSubClient.h>

// Wokwi free WiFi settings
const char* WIFI_SSID = "Wokwi-GUEST";
const char* WIFI_PASS = "";

// Must match the app service defaults
const char* MQTT_BROKER = "broker.hivemq.com";
const int MQTT_PORT = 1883;
const char* MQTT_TOPIC = "gesture_voice_app/wokwi/gesture";

const int POT1_PIN = 34;
const int POT2_PIN = 35;

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);

int lastGesture = -1;
unsigned long lastPublishAt = 0;

int mapPotsToGesture(int pot1, int pot2) {
  int p1 = constrain(pot1, 0, 4095);
  int p2 = constrain(pot2, 0, 4095);

  int col;
  if (p1 < 1365) {
    col = 0;
  } else if (p1 < 2730) {
    col = 1;
  } else {
    col = 2;
  }

  int row = (p2 < 2048) ? 0 : 1;
  return (row * 3) + col + 1;
}

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
  }
}

void connectMqtt() {
  while (!mqttClient.connected()) {
    String clientId = "wokwi-pot-" + String(random(1000, 9999));
    if (mqttClient.connect(clientId.c_str())) {
      break;
    }
    delay(800);
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(POT1_PIN, INPUT);
  pinMode(POT2_PIN, INPUT);

  connectWiFi();

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  connectMqtt();

  Serial.println("Wokwi pot MQTT publisher ready");
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }

  if (!mqttClient.connected()) {
    connectMqtt();
  }

  mqttClient.loop();

  int pot1 = analogRead(POT1_PIN);
  int pot2 = analogRead(POT2_PIN);
  int gestureId = mapPotsToGesture(pot1, pot2);

  unsigned long now = millis();
  bool shouldPublish = (gestureId != lastGesture) || (now - lastPublishAt > 1500);

  if (shouldPublish) {
    char payload[8];
    snprintf(payload, sizeof(payload), "%d", gestureId);

    mqttClient.publish(MQTT_TOPIC, payload, true);

    lastGesture = gestureId;
    lastPublishAt = now;

    Serial.print("pot1=");
    Serial.print(pot1);
    Serial.print(" pot2=");
    Serial.print(pot2);
    Serial.print(" -> gesture=");
    Serial.println(gestureId);
  }

  delay(120);
}
