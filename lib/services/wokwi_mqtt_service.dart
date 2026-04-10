import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class WokwiGestureEvent {
  WokwiGestureEvent({
    required this.gestureId,
    required this.sourcePayload,
    required this.timestamp,
  });

  final int gestureId;
  final String sourcePayload;
  final DateTime timestamp;
}

class WokwiMqttService {
  WokwiMqttService({
    this.broker = 'broker.hivemq.com',
    this.port = 1883,
    this.topic = 'gesture_voice_app/wokwi/gesture',
  });

  final String broker;
  final int port;
  final String topic;

  final StreamController<WokwiGestureEvent> _events =
      StreamController<WokwiGestureEvent>.broadcast();

  MqttServerClient? _client;

  bool isConnected = false;
  String statusMessage = 'Wokwi MQTT idle';

  Stream<WokwiGestureEvent> get events => _events.stream;

  Future<void> connect() async {
    if (isConnected) {
      return;
    }

    final String clientId =
        'gesture_voice_app_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';

    final MqttServerClient client = MqttServerClient(broker, clientId)
      ..port = port
      ..logging(on: false)
      ..secure = false
      ..keepAlivePeriod = 20
      ..autoReconnect = true
      ..onConnected = _handleConnected
      ..onDisconnected = _handleDisconnected;

    final MqttConnectMessage connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);

    client.connectionMessage = connMess;

    statusMessage = 'Connecting to MQTT...';
    try {
      await client.connect();
    } catch (e) {
      statusMessage = 'Wokwi MQTT connect failed: $e';
      isConnected = false;
      client.disconnect();
      rethrow;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      statusMessage =
          'Wokwi MQTT not connected (${client.connectionStatus?.state})';
      isConnected = false;
      client.disconnect();
      throw Exception(statusMessage);
    }

    _client = client;
    client.subscribe(topic, MqttQos.atMostOnce);
    client.updates?.listen(_handleUpdate);

    isConnected = true;
    statusMessage = 'Wokwi MQTT connected';
  }

  Future<void> disconnect() async {
    _client?.disconnect();
    _client = null;
    isConnected = false;
    statusMessage = 'Wokwi MQTT disconnected';
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }

  void _handleConnected() {
    isConnected = true;
    statusMessage = 'Wokwi MQTT connected';
  }

  void _handleDisconnected() {
    isConnected = false;
    statusMessage = 'Wokwi MQTT disconnected';
  }

  void _handleUpdate(List<MqttReceivedMessage<MqttMessage>> messages) {
    if (messages.isEmpty) {
      return;
    }

    final MqttPublishMessage payload =
        messages.first.payload as MqttPublishMessage;
    final String raw =
        MqttPublishPayload.bytesToStringAsString(payload.payload.message);

    final int? gestureId = _parseGestureId(raw);
    if (gestureId == null || gestureId < 1 || gestureId > 6) {
      statusMessage = 'Wokwi payload ignored: $raw';
      return;
    }

    _events.add(
      WokwiGestureEvent(
        gestureId: gestureId,
        sourcePayload: raw,
        timestamp: DateTime.now(),
      ),
    );
  }

  int? _parseGestureId(String rawPayload) {
    final String raw = rawPayload.trim();
    if (raw.isEmpty) {
      return null;
    }

    final int? direct = int.tryParse(raw);
    if (direct != null) {
      return direct;
    }

    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final dynamic gesture = decoded['gesture'];
        if (gesture is int) {
          return gesture;
        }
        if (gesture is String) {
          final int? parsed = int.tryParse(gesture);
          if (parsed != null) {
            return parsed;
          }
        }

        final dynamic p1 = decoded['pot1'];
        final dynamic p2 = decoded['pot2'];
        final int? pot1 = _dynamicToInt(p1);
        final int? pot2 = _dynamicToInt(p2);
        if (pot1 != null && pot2 != null) {
          return _gestureFromPots(pot1, pot2);
        }
      }
    } catch (_) {
      // Try CSV fallback below.
    }

    if (raw.contains(',')) {
      final List<String> parts = raw.split(',');
      if (parts.length >= 2) {
        final int? pot1 = int.tryParse(parts[0].trim());
        final int? pot2 = int.tryParse(parts[1].trim());
        if (pot1 != null && pot2 != null) {
          return _gestureFromPots(pot1, pot2);
        }
      }
    }

    return null;
  }

  int? _dynamicToInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is double) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  int _gestureFromPots(int pot1, int pot2) {
    final int p1 = pot1.clamp(0, 4095);
    final int p2 = pot2.clamp(0, 4095);

    final int col;
    if (p1 < 1365) {
      col = 0;
    } else if (p1 < 2730) {
      col = 1;
    } else {
      col = 2;
    }

    final int row = p2 < 2048 ? 0 : 1;
    return (row * 3) + col + 1;
  }
}
