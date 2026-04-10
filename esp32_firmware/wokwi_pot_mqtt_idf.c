#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_event.h"
#include "nvs_flash.h"

#include "esp_wifi.h"
#include "esp_netif.h"
#include "mqtt_client.h"
#include "driver/adc.h"

static const char *TAG = "wokwi_mqtt";

static const char *MQTT_BROKER = "mqtt://broker.hivemq.com";
static const char *MQTT_TOPIC = "gesture_voice_app/wokwi/gesture";

static esp_mqtt_client_handle_t mqtt_client = NULL;

static int map_pots_to_gesture(int pot1, int pot2) {
  int p1 = pot1 < 0 ? 0 : (pot1 > 4095 ? 4095 : pot1);
  int p2 = pot2 < 0 ? 0 : (pot2 > 4095 ? 4095 : pot2);

  int col;
  if (p1 < 1365) {
    col = 0;
  } else if (p1 < 2730) {
    col = 1;
  } else {
    col = 2;
  }

  int row = p2 < 2048 ? 0 : 1;
  return (row * 3) + col + 1;
}

static void wifi_init(void) {
  esp_netif_init();
  esp_event_loop_create_default();
  esp_netif_create_default_wifi_sta();

  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  esp_wifi_init(&cfg);

  wifi_config_t wifi_config = {
      .sta = {
          .ssid = "Wokwi-GUEST",
          .password = "",
          .threshold.authmode = WIFI_AUTH_OPEN,
      },
  };

  esp_wifi_set_mode(WIFI_MODE_STA);
  esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
  esp_wifi_start();
  esp_wifi_connect();
}

void app_main(void) {
  nvs_flash_init();

  wifi_init();

  adc1_config_width(ADC_WIDTH_BIT_12);
  adc1_config_channel_atten(ADC1_CHANNEL_6, ADC_ATTEN_DB_11); // GPIO34
  adc1_config_channel_atten(ADC1_CHANNEL_7, ADC_ATTEN_DB_11); // GPIO35

  esp_mqtt_client_config_t mqtt_cfg = {
      .broker.address.uri = MQTT_BROKER,
  };

  mqtt_client = esp_mqtt_client_init(&mqtt_cfg);
  esp_mqtt_client_start(mqtt_client);

  int last_gesture = -1;
  TickType_t last_publish_tick = 0;

  while (1) {
    int pot1 = adc1_get_raw(ADC1_CHANNEL_6);
    int pot2 = adc1_get_raw(ADC1_CHANNEL_7);
    int gesture = map_pots_to_gesture(pot1, pot2);

    TickType_t now = xTaskGetTickCount();
    int elapsed_ms = (int)((now - last_publish_tick) * portTICK_PERIOD_MS);

    if (gesture != last_gesture || elapsed_ms > 1500) {
      char payload[8];
      snprintf(payload, sizeof(payload), "%d", gesture);
      esp_mqtt_client_publish(mqtt_client, MQTT_TOPIC, payload, 0, 0, 1);

      last_gesture = gesture;
      last_publish_tick = now;

      ESP_LOGI(TAG, "pot1=%d pot2=%d gesture=%d", pot1, pot2, gesture);
    }

    vTaskDelay(pdMS_TO_TICKS(120));
  }
}
