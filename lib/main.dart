import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:gesture_voice_app/services/camera_gesture_service.dart';
import 'package:gesture_voice_app/services/wokwi_mqtt_service.dart';
import 'package:gesture_voice_app/widgets/hand_landmark_painter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GestureVoiceApp());
}

enum ConnectionStateLabel { idle, scanning, connecting, connected, demo }

enum InputSourceMode { ble, camera, wokwi }

class GestureRecord {
  GestureRecord({
    required this.gestureId,
    required this.phrase,
    required this.timestamp,
    required this.profile,
  });

  final int gestureId;
  final String phrase;
  final DateTime timestamp;
  final String profile;
}

class GestureController extends ChangeNotifier {
  static const int _maxHistory = 20;
  static const String _defaultFallback = 'No gesture detected';
  static const String _espServiceUuid =
      '7f9e1167-95e5-4afb-8f4e-91b0d5134d44';
  static const String _espGestureCharUuid =
      'c9f1e18f-78f0-4d5b-a0cb-bc8fc4e6719c';
  static const List<int> _demoGestureIds = <int>[1, 2, 3, 4, 5, 6];

  static const Map<int, String> _gestureNames = <int, String>{
    1: 'Fist',
    2: 'Open Palm',
    3: 'Point',
    4: 'OK',
    5: 'Wave Left',
    6: 'Wave Right',
  };

  final FlutterTts _tts = FlutterTts();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final CameraGestureService _cameraService = CameraGestureService();
  final WokwiMqttService _wokwiService = WokwiMqttService();

  List<ScanResult> scannedDevices = <ScanResult>[];
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? notifyCharacteristic;
  ConnectionStateLabel connectionState = ConnectionStateLabel.idle;

  final List<GestureRecord> history = <GestureRecord>[];
  int? lastGestureId;
  String lastPhrase = _defaultFallback;
  String statusMessage = 'Idle';

  bool audioEnabled = true;
  bool vibrationEnabled = true;
  bool textOnlyMode = false;
  bool notificationMode = false;
  bool autoReconnect = true;
  bool demoMode = false;
  InputSourceMode inputMode = InputSourceMode.ble;

  double speechRate = 0.5;
  double speechVolume = 1.0;
  String selectedLanguage = 'en-US';

  final Map<String, String> languages = <String, String>{
    'en-US': 'English',
    'hi-IN': 'Hindi',
    'ta-IN': 'Tamil',
  };

  String activeProfile = 'Default Mode';
  Map<String, Map<int, Map<String, String>>> profiles =
      <String, Map<int, Map<String, String>>>{};

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _deviceConnectionSubscription;
  StreamSubscription<CameraGestureEvent>? _cameraSubscription;
  StreamSubscription<WokwiGestureEvent>? _wokwiSubscription;
  Timer? _demoTimer;
  final Random _random = Random();
  String _bleTextBuffer = '';

  CameraController? get cameraController => _cameraService.cameraController;
  String get cameraStatusMessage => _cameraService.statusMessage;
  double get cameraConfidence => _cameraService.lastConfidence;
  bool get cameraModelLoaded => _cameraService.hasLoadedModel;
  String? get cameraModelError => _cameraService.modelLoadError;
  List<Offset> get handLandmarkPoints => _cameraService.handLandmarkPoints;
  List<LandmarkConnection> get handLandmarkConnections =>
      _cameraService.handLandmarkConnections;
  ValueNotifier<int> get cameraOverlayVersion => _cameraService.overlayVersion;
  bool get wokwiConnected => _wokwiService.isConnected;
  String get wokwiStatusMessage => _wokwiService.statusMessage;
  String get wokwiTopic => _wokwiService.topic;
  String get wokwiBroker => _wokwiService.broker;

  String gestureName(int gestureId) {
    return _gestureNames[gestureId] ?? 'Gesture $gestureId';
  }

  Future<void> initialize() async {
    _loadDefaultProfiles();
    await _loadPreferences();
    _ensureProfileLanguageDefaults();
    _normalizeDemoProfile();
    await _configureTts();
    lastPhrase = _fallbackPhraseForLanguage(selectedLanguage);
    await _initializeNotifications();

    if (inputMode == InputSourceMode.camera) {
      await _startCameraMode();
    } else if (inputMode == InputSourceMode.wokwi) {
      await _startWokwiMode();
    }
  }

  Map<String, String> _phraseEntry(String en, String hi, String ta) {
    return <String, String>{
      'en-US': en,
      'hi-IN': hi,
      'ta-IN': ta,
    };
  }

  void _loadDefaultProfiles() {
    profiles = <String, Map<int, Map<String, String>>>{
      'Demo Mode': <int, Map<String, String>>{
        1: _phraseEntry('Hello', 'नमस्ते', 'வணக்கம்'),
        2: _phraseEntry('Thank you', 'धन्यवाद', 'நன்றி'),
        3: _phraseEntry(
          'Please help me',
          'कृपया मेरी मदद करें',
          'தயவு செய்து உதவுங்கள்',
        ),
        4: _phraseEntry('I am fine', 'मैं ठीक हूँ', 'நான் நலமாக இருக்கிறேன்'),
        5: _phraseEntry('Need assistance', 'सहायता चाहिए', 'உதவி வேண்டும்'),
        6: _phraseEntry('Emergency', 'आपातकाल', 'அவசரம்'),
      },
    };
  }

  String _fallbackPhraseForLanguage(String languageCode) {
    switch (languageCode) {
      case 'hi-IN':
        return 'कोई संकेत नहीं मिला';
      case 'ta-IN':
        return 'சைகை கண்டறியப்படவில்லை';
      default:
        return _defaultFallback;
    }
  }

  Future<void> _loadPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    audioEnabled = prefs.getBool('audioEnabled') ?? true;
    vibrationEnabled = prefs.getBool('vibrationEnabled') ?? true;
    textOnlyMode = prefs.getBool('textOnlyMode') ?? false;
    notificationMode = prefs.getBool('notificationMode') ?? false;
    autoReconnect = prefs.getBool('autoReconnect') ?? true;
    speechRate = prefs.getDouble('speechRate') ?? 0.5;
    speechVolume = prefs.getDouble('speechVolume') ?? 1.0;
    selectedLanguage = prefs.getString('selectedLanguage') ?? 'en-US';
    activeProfile = prefs.getString('activeProfile') ?? 'Demo Mode';
    final String mode = prefs.getString('inputMode') ?? 'ble';
    if (mode == 'camera') {
      inputMode = InputSourceMode.camera;
    } else if (mode == 'wokwi') {
      inputMode = InputSourceMode.wokwi;
    } else {
      inputMode = InputSourceMode.ble;
    }

    final String? encodedProfiles = prefs.getString('profiles');
    if (encodedProfiles != null && encodedProfiles.isNotEmpty) {
      final Map<String, dynamic> decoded =
          jsonDecode(encodedProfiles) as Map<String, dynamic>;
      profiles = decoded.map(
        (String key, dynamic value) {
          final Map<String, dynamic> mapping = value as Map<String, dynamic>;
          return MapEntry<String, Map<int, Map<String, String>>>(
            key,
            mapping.map(
              (String mKey, dynamic mValue) {
                if (mValue is Map<String, dynamic>) {
                  final Map<String, String> localized = mValue.map(
                    (String langCode, dynamic phrase) =>
                        MapEntry<String, String>(langCode, phrase.toString()),
                  );
                  return MapEntry<int, Map<String, String>>(
                    int.parse(mKey),
                    localized,
                  );
                }

                if (mValue is Map) {
                  final Map<String, String> localized =
                      <String, String>{};
                  for (final MapEntry<dynamic, dynamic> entry
                      in mValue.entries) {
                    localized[entry.key.toString()] = entry.value.toString();
                  }
                  return MapEntry<int, Map<String, String>>(
                    int.parse(mKey),
                    localized,
                  );
                }

                return MapEntry<int, Map<String, String>>(
                  int.parse(mKey),
                  <String, String>{'en-US': mValue.toString()},
                );
              },
            ),
          );
        },
      );
    }

    if (!profiles.containsKey(activeProfile)) {
      activeProfile = 'Demo Mode';
    }
    notifyListeners();
  }

  Future<void> _savePreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('audioEnabled', audioEnabled);
    await prefs.setBool('vibrationEnabled', vibrationEnabled);
    await prefs.setBool('textOnlyMode', textOnlyMode);
    await prefs.setBool('notificationMode', notificationMode);
    await prefs.setBool('autoReconnect', autoReconnect);
    await prefs.setDouble('speechRate', speechRate);
    await prefs.setDouble('speechVolume', speechVolume);
    await prefs.setString('selectedLanguage', selectedLanguage);
    await prefs.setString('activeProfile', activeProfile);
    final String modeValue;
    switch (inputMode) {
      case InputSourceMode.camera:
        modeValue = 'camera';
      case InputSourceMode.wokwi:
        modeValue = 'wokwi';
      case InputSourceMode.ble:
        modeValue = 'ble';
    }
    await prefs.setString('inputMode', modeValue);

    final Map<String, dynamic> serializable = profiles.map(
      (String key, Map<int, Map<String, String>> value) =>
          MapEntry<String, dynamic>(key, value.map(
        (int mapKey, Map<String, String> mapValue) =>
            MapEntry<String, dynamic>(mapKey.toString(), mapValue),
      )),
    );
    await prefs.setString('profiles', jsonEncode(serializable));
  }

  void _ensureProfileLanguageDefaults() {
    final Map<String, Map<int, Map<String, String>>> defaultProfiles =
        <String, Map<int, Map<String, String>>>{};
    final Map<String, Map<int, Map<String, String>>> snapshot = profiles;
    _loadDefaultProfiles();
    defaultProfiles.addAll(profiles);
    profiles = snapshot;

    for (final String profileName in defaultProfiles.keys) {
      profiles.putIfAbsent(
        profileName,
        () => <int, Map<String, String>>{},
      );

      final Map<int, Map<String, String>> target = profiles[profileName]!;
      final Map<int, Map<String, String>> defaults = defaultProfiles[profileName]!;

      for (final int gestureId in defaults.keys) {
        target.putIfAbsent(
          gestureId,
          () => Map<String, String>.from(defaults[gestureId]!),
        );
        for (final String langCode in languages.keys) {
          target[gestureId]!.putIfAbsent(
            langCode,
            () => defaults[gestureId]![langCode] ?? defaults[gestureId]!['en-US']!,
          );
        }
        target[gestureId]!.putIfAbsent(
          'en-US',
          () => target[gestureId]!.values.first,
        );
      }
    }

    for (final String profileName in profiles.keys) {
      final Map<int, Map<String, String>> target = profiles[profileName]!;
      for (final int gestureId in target.keys) {
        target[gestureId]!.putIfAbsent(
          'en-US',
          () => target[gestureId]!.values.isEmpty
              ? 'Gesture $gestureId'
              : target[gestureId]!.values.first,
        );
      }
    }
  }

  void _normalizeDemoProfile() {
    final Map<int, Map<String, String>> demoProfile =
        profiles['Demo Mode'] ?? <int, Map<String, String>>{};

    for (final int gestureId in _demoGestureIds) {
      demoProfile.putIfAbsent(
        gestureId,
        () => <String, String>{
          'en-US': gestureName(gestureId),
          'hi-IN': gestureName(gestureId),
          'ta-IN': gestureName(gestureId),
        },
      );
    }

    demoProfile.removeWhere((int gestureId, _) => !_demoGestureIds.contains(gestureId));
    profiles = <String, Map<int, Map<String, String>>>{'Demo Mode': demoProfile};
    activeProfile = 'Demo Mode';
  }

  Future<void> _configureTts() async {
    await _tts.setSpeechRate(speechRate);
    await _tts.setVolume(speechVolume);
    await _tts.setLanguage(selectedLanguage);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();
    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(initSettings);
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Map<int, String> get activeMapping => activeMappingForLanguage(selectedLanguage);

  Map<int, String> activeMappingForLanguage(String languageCode) {
    final Map<int, Map<String, String>> source =
        profiles[activeProfile] ?? <int, Map<String, String>>{};
    return source.map(
      (int gestureId, Map<String, String> localized) => MapEntry<int, String>(
        gestureId,
        localized[languageCode] ??
            localized['en-US'] ??
            (localized.values.isEmpty ? _defaultFallback : localized.values.first),
      ),
    );
  }

  String phraseForGesture(int gestureId, {String? languageCode}) {
    return activeMappingForLanguage(languageCode ?? selectedLanguage)[gestureId] ??
        _fallbackPhraseForLanguage(languageCode ?? selectedLanguage);
  }

  Future<void> setInputMode(InputSourceMode mode) async {
    if (mode == inputMode) {
      return;
    }

    inputMode = mode;
    if (mode == InputSourceMode.camera) {
      await disconnect();
      await _startCameraMode();
    } else if (mode == InputSourceMode.wokwi) {
      await disconnect();
      await _startWokwiMode();
    } else {
      await _stopCameraMode();
      await _stopWokwiMode();
      statusMessage = 'BLE mode active';
    }

    await _savePreferences();
    notifyListeners();
  }

  Future<void> _startCameraMode() async {
    await _cameraSubscription?.cancel();

    try {
      await _cameraService.start();
      _cameraSubscription = _cameraService.events.listen(
        (CameraGestureEvent event) {
          unawaited(_handleGestureId(event.gestureId, source: 'Camera'));
        },
      );
      connectionState = ConnectionStateLabel.idle;
      statusMessage = _cameraService.statusMessage;
    } catch (e) {
      statusMessage = 'Camera start failed: $e';
    }
    notifyListeners();
  }

  Future<void> triggerManualCameraGesture(int gestureId) async {
    await _handleGestureId(gestureId, source: 'Camera Manual');
  }

  Future<void> _stopCameraMode() async {
    await _cameraSubscription?.cancel();
    _cameraSubscription = null;
    await _cameraService.stop();
    notifyListeners();
  }

  Future<void> _startWokwiMode() async {
    await _wokwiSubscription?.cancel();
    try {
      await _wokwiService.connect();
      _wokwiSubscription = _wokwiService.events.listen((WokwiGestureEvent event) {
        unawaited(_handleGestureId(event.gestureId, source: 'Wokwi MQTT'));
      });
      connectionState = ConnectionStateLabel.idle;
      statusMessage =
          'Wokwi connected (${_wokwiService.broker} / ${_wokwiService.topic})';
    } catch (e) {
      statusMessage = 'Wokwi connect failed: $e';
    }
    notifyListeners();
  }

  Future<void> _stopWokwiMode() async {
    await _wokwiSubscription?.cancel();
    _wokwiSubscription = null;
    await _wokwiService.disconnect();
    notifyListeners();
  }

  Future<void> startScan() async {
    if (inputMode != InputSourceMode.ble) {
      await setInputMode(InputSourceMode.ble);
    }

    if (demoMode) {
      stopDemoMode();
    }

    statusMessage = 'Scanning for ESP32 devices...';
    connectionState = ConnectionStateLabel.scanning;
    scannedDevices = <ScanResult>[];
    notifyListeners();

    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((
      List<ScanResult> results,
    ) {
      final Map<String, ScanResult> deduped = <String, ScanResult>{};
      for (final ScanResult result in results) {
        deduped[result.device.remoteId.str] = result;
      }
      scannedDevices = deduped.values.toList()
        ..sort((ScanResult a, ScanResult b) =>
            a.device.platformName.compareTo(b.device.platformName));
      notifyListeners();
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
      connectionState = ConnectionStateLabel.idle;
      statusMessage = scannedDevices.isEmpty
          ? 'No devices found'
          : 'Scan complete';
    } catch (e) {
      connectionState = ConnectionStateLabel.idle;
      statusMessage = 'Scan failed: $e';
    }
    notifyListeners();
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (inputMode != InputSourceMode.ble) {
      await setInputMode(InputSourceMode.ble);
    }

    connectionState = ConnectionStateLabel.connecting;
    statusMessage = 'Connecting to ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}';
    notifyListeners();

    await _notifySubscription?.cancel();
    await _deviceConnectionSubscription?.cancel();
    _demoTimer?.cancel();
    demoMode = false;

    try {
      await FlutterBluePlus.stopScan();
      await device.connect(timeout: const Duration(seconds: 8));
      connectedDevice = device;

      _deviceConnectionSubscription =
          device.connectionState.listen((BluetoothConnectionState state) {
        if (state == BluetoothConnectionState.disconnected) {
          connectionState = ConnectionStateLabel.idle;
          statusMessage = 'Disconnected';
          connectedDevice = null;
          notifyCharacteristic = null;
          notifyListeners();

          if (autoReconnect && !demoMode) {
            _attemptReconnect(device);
          }
        }
      });

      final List<BluetoothService> services = await device.discoverServices();
      BluetoothCharacteristic? candidate;

      // 1) Prefer exact service+characteristic UUID from ESP firmware.
      for (final BluetoothService service in services) {
        final bool serviceMatch =
            service.uuid.str.toLowerCase() == _espServiceUuid;
        if (!serviceMatch) {
          continue;
        }
        for (final BluetoothCharacteristic characteristic
            in service.characteristics) {
          final bool charMatch =
              characteristic.uuid.str.toLowerCase() == _espGestureCharUuid;
          if (charMatch &&
              (characteristic.properties.notify ||
                  characteristic.properties.indicate)) {
            candidate = characteristic;
            break;
          }
        }
      }

      // 2) Fallback: match characteristic UUID anywhere.
      if (candidate == null) {
        for (final BluetoothService service in services) {
          for (final BluetoothCharacteristic characteristic
              in service.characteristics) {
            final bool charMatch =
                characteristic.uuid.str.toLowerCase() == _espGestureCharUuid;
            if (charMatch &&
                (characteristic.properties.notify ||
                    characteristic.properties.indicate)) {
              candidate = characteristic;
              break;
            }
          }
          if (candidate != null) {
            break;
          }
        }
      }

      // 3) Last fallback: first notifiable characteristic.
      if (candidate == null) {
        for (final BluetoothService service in services) {
          for (final BluetoothCharacteristic characteristic
              in service.characteristics) {
            if (characteristic.properties.notify ||
                characteristic.properties.indicate) {
              candidate = characteristic;
              break;
            }
          }
          if (candidate != null) {
            break;
          }
        }
      }

      if (candidate == null) {
        throw Exception('No notifiable characteristic found');
      }

      notifyCharacteristic = candidate;
      await notifyCharacteristic!.setNotifyValue(true);
      _notifySubscription =
          notifyCharacteristic!.lastValueStream.listen(_parseIncomingData);

      connectionState = ConnectionStateLabel.connected;
        statusMessage =
          'Connected: ${notifyCharacteristic!.uuid.str.substring(0, 8)}...';
    } catch (e) {
      connectionState = ConnectionStateLabel.idle;
      statusMessage = 'Connection failed: $e';
      connectedDevice = null;
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _notifySubscription?.cancel();
    await _deviceConnectionSubscription?.cancel();
    _demoTimer?.cancel();
    await _stopCameraMode();
    await _stopWokwiMode();

    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
    }

    connectedDevice = null;
    notifyCharacteristic = null;
    demoMode = false;
    connectionState = ConnectionStateLabel.idle;
    statusMessage = 'Disconnected';
    notifyListeners();
  }

  Future<void> _attemptReconnect(BluetoothDevice device) async {
    statusMessage = 'Reconnecting...';
    notifyListeners();

    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      await connectToDevice(device);
    } catch (_) {
      connectionState = ConnectionStateLabel.idle;
      statusMessage = 'Reconnect failed';
      notifyListeners();
    }
  }

  void startDemoMode() {
    if (connectedDevice != null) {
      disconnect();
    }
    _demoTimer?.cancel();
    demoMode = true;
    connectionState = ConnectionStateLabel.demo;
    statusMessage = 'Demo mode active';
    notifyListeners();

    _demoTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final List<int> available = activeMapping.keys.toList()..sort();
      if (available.isEmpty) {
        return;
      }
      final int randomId = available[_random.nextInt(available.length)];
      unawaited(_handleGestureId(randomId, source: 'Demo'));
    });
  }

  void stopDemoMode() {
    _demoTimer?.cancel();
    demoMode = false;
    if (connectionState == ConnectionStateLabel.demo) {
      connectionState = ConnectionStateLabel.idle;
      statusMessage = 'Demo stopped';
      notifyListeners();
    }
  }

  void _parseIncomingData(List<int> value) {
    if (value.isEmpty) {
      return;
    }

    final String decoded = utf8.decode(value, allowMalformed: true);
    _bleTextBuffer += decoded;

    // Preferred framing: one gesture id per line from firmware.
    final List<String> parts = _bleTextBuffer.split(RegExp(r'\r?\n'));
    _bleTextBuffer = parts.removeLast();

    bool processed = false;
    for (final String raw in parts) {
      final String token = raw.trim();
      if (token.isEmpty) {
        continue;
      }

      int? gestureId = int.tryParse(token);
      if (gestureId == null) {
        final String numbersOnly = token.replaceAll(RegExp(r'[^0-9-]'), '');
        gestureId = int.tryParse(numbersOnly);
      }

      if (gestureId != null) {
        processed = true;
        unawaited(_handleGestureId(gestureId, source: 'BLE'));
      }
    }

    // Fallback for payloads delivered as a single raw byte (1..6) with no newline.
    if (!processed && value.length == 1 && value.first >= 1 && value.first <= 6) {
      processed = true;
      unawaited(_handleGestureId(value.first, source: 'BLE'));
    }

    if (!processed && _bleTextBuffer.length > 32) {
      _bleTextBuffer = '';
      statusMessage = 'Invalid gesture payload';
      notifyListeners();
    }
  }

  Future<void> _handleGestureId(int gestureId, {required String source}) async {
    if (!activeMappingForLanguage('en-US').containsKey(gestureId)) {
      lastGestureId = gestureId;
      lastPhrase = _fallbackPhraseForLanguage(selectedLanguage);
      statusMessage = 'Unknown gesture ID: $gestureId';
      notifyListeners();
      return;
    }

    final String phrase = phraseForGesture(gestureId);
    lastGestureId = gestureId;
        lastPhrase = phrase;
        statusMessage = 'Recognized "$phrase" from $source';
    _addHistory(gestureId, phrase);
    notifyListeners();

    if (vibrationEnabled && await Vibration.hasVibrator()) {
      await Vibration.vibrate(duration: 80);
    }

    if (notificationMode) {
      await _notifications.show(
        gestureId,
        'Gesture recognized',
        phrase,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'gesture_channel',
            'Gesture Alerts',
            channelDescription: 'Notifications for recognized gestures',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    }

    if (audioEnabled && !textOnlyMode) {
      await _tts.setLanguage(selectedLanguage);
      await _tts.setSpeechRate(speechRate);
      await _tts.setVolume(speechVolume);
      await _tts.speak(phrase);
    }
  }

  void _addHistory(int gestureId, String phrase) {
    history.insert(
      0,
      GestureRecord(
        gestureId: gestureId,
        phrase: phrase,
        timestamp: DateTime.now(),
        profile: activeProfile,
      ),
    );
    if (history.length > _maxHistory) {
      history.removeRange(_maxHistory, history.length);
    }
  }

  Future<void> updatePhrase(
    int gestureId,
    String phrase, {
    String? languageCode,
  }) async {
    final String langCode = languageCode ?? selectedLanguage;
    profiles.putIfAbsent(activeProfile, () => <int, Map<String, String>>{});
    profiles[activeProfile]!.putIfAbsent(gestureId, () => <String, String>{});
    profiles[activeProfile]![gestureId]![langCode] = phrase.trim();
    profiles[activeProfile]![gestureId]!.putIfAbsent('en-US', () => phrase.trim());
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setProfile(String profileName) async {
    activeProfile = profileName;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setAudioEnabled(bool value) async {
    audioEnabled = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setVibrationEnabled(bool value) async {
    vibrationEnabled = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setTextOnlyMode(bool value) async {
    textOnlyMode = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setNotificationMode(bool value) async {
    notificationMode = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setAutoReconnect(bool value) async {
    autoReconnect = value;
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setSpeechRate(double value) async {
    speechRate = value;
    await _tts.setSpeechRate(speechRate);
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setSpeechVolume(double value) async {
    speechVolume = value;
    await _tts.setVolume(speechVolume);
    await _savePreferences();
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    selectedLanguage = code;
    await _tts.setLanguage(selectedLanguage);

    if (lastGestureId == null) {
      lastPhrase = _fallbackPhraseForLanguage(selectedLanguage);
    } else {
      lastPhrase = phraseForGesture(lastGestureId!);
    }

    await _savePreferences();
    notifyListeners();
  }

  Future<void> resetPhrases() async {
    _loadDefaultProfiles();
    _ensureProfileLanguageDefaults();
    await _savePreferences();
    notifyListeners();
  }

  Future<File> exportHistoryAsCsv() async {
    final StringBuffer buffer = StringBuffer();
    buffer.writeln('timestamp,profile,gesture_id,phrase');
    for (final GestureRecord item in history) {
      final String row =
          '${item.timestamp.toIso8601String()},${item.profile},${item.gestureId},"${item.phrase.replaceAll('"', '""')}"';
      buffer.writeln(row);
    }

    final Directory dir = await getTemporaryDirectory();
    final File csv = File(
      '${dir.path}/gesture_history_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    await csv.writeAsString(buffer.toString());
    return csv;
  }

  Future<void> shareHistory() async {
    if (history.isEmpty) {
      return;
    }
    final File csv = await exportHistoryAsCsv();
    await Share.shareXFiles(
      <XFile>[XFile(csv.path)],
      text: 'Gesture history export',
    );
  }

  @override
  void dispose() {
    unawaited(_scanSubscription?.cancel());
    unawaited(_notifySubscription?.cancel());
    unawaited(_deviceConnectionSubscription?.cancel());
    unawaited(_cameraSubscription?.cancel());
    unawaited(_wokwiSubscription?.cancel());
    unawaited(_cameraService.dispose());
    unawaited(_wokwiService.dispose());
    _demoTimer?.cancel();
    unawaited(_tts.stop());
    super.dispose();
  }
}

class GestureVoiceApp extends StatefulWidget {
  const GestureVoiceApp({super.key});

  @override
  State<GestureVoiceApp> createState() => _GestureVoiceAppState();
}

class _GestureVoiceAppState extends State<GestureVoiceApp> {
  final GestureController controller = GestureController();

  @override
  void initState() {
    super.initState();
    unawaited(controller.initialize());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gesture Voice Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00695C),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: AppShell(controller: controller),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final GestureController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      LiveViewPage(controller: widget.controller),
      ConnectionPage(controller: widget.controller),
      HistoryPage(controller: widget.controller),
      SettingsPage(controller: widget.controller),
    ];

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Gesture Voice Assistant'),
            actions: <Widget>[
              if (widget.controller.inputMode == InputSourceMode.ble)
                IconButton(
                  tooltip: widget.controller.demoMode
                      ? 'Stop demo mode'
                      : 'Start demo mode',
                  icon: Icon(
                    widget.controller.demoMode
                        ? Icons.pause_circle
                        : Icons.play_circle,
                  ),
                  onPressed: () {
                    if (widget.controller.demoMode) {
                      widget.controller.stopDemoMode();
                    } else {
                      widget.controller.startDemoMode();
                    }
                  },
                ),
            ],
          ),
          body: pages[currentIndex],
          bottomNavigationBar: NavigationBar(
            selectedIndex: currentIndex,
            destinations: const <NavigationDestination>[
              NavigationDestination(
                icon: Icon(Icons.record_voice_over),
                label: 'Live',
              ),
              NavigationDestination(
                icon: Icon(Icons.bluetooth),
                label: 'Connection',
              ),
              NavigationDestination(
                icon: Icon(Icons.history),
                label: 'History',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
            onDestinationSelected: (int index) {
              setState(() {
                currentIndex = index;
              });
            },
          ),
        );
      },
    );
  }
}

class LiveViewPage extends StatelessWidget {
  const LiveViewPage({super.key, required this.controller});

  final GestureController controller;

  Color _statusColor(ConnectionStateLabel state) {
    switch (state) {
      case ConnectionStateLabel.connected:
        return Colors.green;
      case ConnectionStateLabel.connecting:
      case ConnectionStateLabel.scanning:
        return Colors.orange;
      case ConnectionStateLabel.demo:
        return Colors.blue;
      case ConnectionStateLabel.idle:
        return Colors.grey;
    }
  }

  String _statusLabel(ConnectionStateLabel state) {
    switch (state) {
      case ConnectionStateLabel.connected:
        return 'Connected';
      case ConnectionStateLabel.connecting:
        return 'Connecting';
      case ConnectionStateLabel.scanning:
        return 'Scanning';
      case ConnectionStateLabel.demo:
        return 'Demo';
      case ConnectionStateLabel.idle:
        return 'Idle';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Chip(
                    avatar: Icon(
                      Icons.circle,
                      color: _statusColor(controller.connectionState),
                      size: 12,
                    ),
                    label: Text(_statusLabel(controller.connectionState)),
                  ),
                  Chip(label: Text('Profile: ${controller.activeProfile}')),
                  Chip(
                    label: Text(
                      switch (controller.inputMode) {
                        InputSourceMode.camera => 'Mode: Camera',
                        InputSourceMode.wokwi => 'Mode: Wokwi',
                        InputSourceMode.ble => 'Mode: BLE',
                      },
                    ),
                  ),
                  if (controller.lastGestureId != null)
                    Chip(
                      label: Text(
                            'Phrase: ${controller.lastPhrase}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<InputSourceMode>(
                segments: const <ButtonSegment<InputSourceMode>>[
                  ButtonSegment<InputSourceMode>(
                    value: InputSourceMode.ble,
                    label: Text('BLE'),
                    icon: Icon(Icons.bluetooth),
                  ),
                  ButtonSegment<InputSourceMode>(
                    value: InputSourceMode.camera,
                    label: Text('Camera'),
                    icon: Icon(Icons.camera_alt),
                  ),
                  ButtonSegment<InputSourceMode>(
                    value: InputSourceMode.wokwi,
                    label: Text('Wokwi'),
                    icon: Icon(Icons.memory),
                  ),
                ],
                selected: <InputSourceMode>{controller.inputMode},
                onSelectionChanged: (Set<InputSourceMode> selected) {
                  final InputSourceMode mode = selected.first;
                  unawaited(controller.setInputMode(mode));
                },
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Card(
                  elevation: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: const LinearGradient(
                        colors: <Color>[Color(0xFFE0F2F1), Color(0xFFFFFFFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.all(24),
                    child: controller.inputMode == InputSourceMode.camera
                      ? _buildCameraPanel(context)
                      : controller.inputMode == InputSourceMode.wokwi
                        ? _buildWokwiPanel(context)
                        : Center(
                            child: Text(
                              controller.lastPhrase,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF004D40),
                                  ),
                            ),
                          ),
                  ),
                ),
              ),
              if (controller.inputMode == InputSourceMode.camera)
                const SizedBox(height: 10),
              if (controller.inputMode == InputSourceMode.camera)
                Text(
                  'Camera confidence: ${(controller.cameraConfidence * 100).clamp(0, 100).toStringAsFixed(1)}%',
                  textAlign: TextAlign.center,
                ),
              if (controller.inputMode == InputSourceMode.camera)
                Text(
                  controller.cameraStatusMessage,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (controller.inputMode == InputSourceMode.wokwi)
                Text(
                  controller.wokwiStatusMessage,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (controller.inputMode == InputSourceMode.camera &&
                  !controller.cameraModelLoaded &&
                  controller.cameraModelError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Model error: ${controller.cameraModelError}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.red.shade700,
                        ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                controller.statusMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              if (controller.inputMode == InputSourceMode.ble)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: controller.demoMode
                            ? controller.stopDemoMode
                            : controller.startDemoMode,
                        icon: Icon(
                          controller.demoMode ? Icons.stop : Icons.play_arrow,
                        ),
                        label: Text(
                          controller.demoMode ? 'Stop Demo' : 'Start Demo',
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCameraPanel(BuildContext context) {
    final CameraController? cameraController = controller.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return Center(
        child: Text(
          'Camera is not ready yet',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    final bool mirrorX =
        cameraController.description.lensDirection == CameraLensDirection.front;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CameraPreview(cameraController),
          ValueListenableBuilder<int>(
            valueListenable: controller.cameraOverlayVersion,
            builder: (BuildContext context, int _, Widget? child) {
              return IgnorePointer(
                child: CustomPaint(
                  painter: HandLandmarkPainter(
                    points: controller.handLandmarkPoints,
                    connections: controller.handLandmarkConnections,
                    mirrorX: mirrorX,
                  ),
                ),
              );
            },
          ),
          if (controller.handLandmarkPoints.isEmpty)
            const Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x88000000),
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      'No landmarks yet. Keep your upper body and hands in frame.',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWokwiPanel(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            controller.wokwiConnected ? Icons.cloud_done : Icons.cloud_off,
            size: 52,
            color: controller.wokwiConnected ? Colors.green : Colors.orange,
          ),
          const SizedBox(height: 12),
          Text(
            controller.wokwiConnected
                ? 'Connected to Wokwi MQTT'
                : 'Waiting for Wokwi MQTT',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'Broker: ${controller.wokwiBroker}\nTopic: ${controller.wokwiTopic}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          const Text(
            'Move potentiometers in Wokwi to publish gesture IDs.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class ConnectionPage extends StatelessWidget {
  const ConnectionPage({super.key, required this.controller});

  final GestureController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final bool connected = controller.connectedDevice != null;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        await controller.setInputMode(InputSourceMode.ble);
                        await controller.startScan();
                      },
                      icon: const Icon(Icons.search),
                      label: const Text('Scan Devices'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: connected ? controller.disconnect : null,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Disconnect'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (controller.inputMode == InputSourceMode.camera)
                const Text(
                  'Switching to BLE mode when scan starts.',
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 8),
              if (controller.connectedDevice != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.bluetooth_connected),
                    title: Text(
                      controller.connectedDevice!.platformName.isEmpty
                          ? controller.connectedDevice!.remoteId.str
                          : controller.connectedDevice!.platformName,
                    ),
                    subtitle: const Text('Connected and listening'),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Discovered Devices',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: controller.scannedDevices.isEmpty
                    ? const Center(child: Text('No devices found yet'))
                    : ListView.builder(
                        itemCount: controller.scannedDevices.length,
                        itemBuilder: (BuildContext context, int index) {
                          final ScanResult result =
                              controller.scannedDevices[index];
                          final String name = result.device.platformName.isEmpty
                              ? result.device.remoteId.str
                              : result.device.platformName;
                          return Card(
                            child: ListTile(
                              leading: const Icon(Icons.bluetooth),
                              title: Text(name),
                              subtitle: Text('RSSI: ${result.rssi}'),
                              trailing: FilledButton(
                                onPressed: () =>
                                    controller.connectToDevice(result.device),
                                child: const Text('Connect'),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.controller});

  final GestureController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Last ${controller.history.length} gestures',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: controller.history.isEmpty
                        ? null
                        : () async {
                            await controller.shareHistory();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('History exported as CSV'),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.download),
                    label: const Text('Export'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: controller.history.isEmpty
                    ? const Center(child: Text('No gesture history yet'))
                    : ListView.builder(
                        itemCount: controller.history.length,
                        itemBuilder: (BuildContext context, int index) {
                          final GestureRecord record = controller.history[index];
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Text(record.gestureId.toString()),
                              ),
                              title: Text(record.phrase),
                              subtitle: Text(
                                '${DateFormat('HH:mm:ss').format(record.timestamp)} | ${record.profile}',
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final GestureController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final List<int> gestureIds = controller.activeMapping.keys.toList()
          ..sort();

        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text('Speech and Interaction',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SwitchListTile(
              value: controller.audioEnabled,
              onChanged: controller.setAudioEnabled,
              title: const Text('Enable Audio Confirmation'),
            ),
            SwitchListTile(
              value: controller.textOnlyMode,
              onChanged: controller.setTextOnlyMode,
              title: const Text('Text Display Mode (No Audio)'),
            ),
            SwitchListTile(
              value: controller.vibrationEnabled,
              onChanged: controller.setVibrationEnabled,
              title: const Text('Enable Haptic Feedback'),
            ),
            SwitchListTile(
              value: controller.notificationMode,
              onChanged: controller.setNotificationMode,
              title: const Text('Notification Mode'),
            ),
            SwitchListTile(
              value: controller.autoReconnect,
              onChanged: controller.setAutoReconnect,
              title: const Text('Auto Reconnect'),
            ),
            const Divider(height: 24),
            Text('Language and Voice',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: controller.selectedLanguage,
              decoration: const InputDecoration(
                labelText: 'TTS Language',
                border: OutlineInputBorder(),
              ),
              items: controller.languages.entries
                  .map(
                    (MapEntry<String, String> entry) =>
                        DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (String? value) {
                if (value != null) {
                  controller.setLanguage(value);
                }
              },
            ),
            const SizedBox(height: 12),
            Text('Speech Speed: ${controller.speechRate.toStringAsFixed(2)}'),
            Slider(
              value: controller.speechRate,
              min: 0.1,
              max: 1.0,
              divisions: 18,
              onChanged: controller.setSpeechRate,
            ),
            Text(
              'Speech Volume: ${controller.speechVolume.toStringAsFixed(2)}',
            ),
            Slider(
              value: controller.speechVolume,
              min: 0.1,
              max: 1.0,
              divisions: 9,
              onChanged: controller.setSpeechVolume,
            ),
            const Divider(height: 24),
            Text('Gesture Profiles',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: controller.activeProfile,
              decoration: const InputDecoration(
                labelText: 'Active Profile',
                border: OutlineInputBorder(),
              ),
              items: controller.profiles.keys
                  .map(
                    (String profile) => DropdownMenuItem<String>(
                      value: profile,
                      child: Text(profile),
                    ),
                  )
                  .toList(),
              onChanged: (String? value) {
                if (value != null) {
                  controller.setProfile(value);
                }
              },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _showPhraseEditor(context, controller, gestureIds),
              icon: const Icon(Icons.edit),
              label: const Text('Customize Phrases'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                await controller.resetPhrases();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Phrases reset to defaults')),
                  );
                }
              },
              icon: const Icon(Icons.restore),
              label: const Text('Reset Phrase Mappings'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showPhraseEditor(
    BuildContext context,
    GestureController controller,
    List<int> gestureIds,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Edit ${controller.activeProfile} Phrases'),
          content: SizedBox(
            width: 380,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: gestureIds.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (BuildContext context, int index) {
                final int gestureId = gestureIds[index];
                final TextEditingController editor = TextEditingController(
                  text: controller.activeMapping[gestureId] ?? '',
                );
                return Row(
                  children: <Widget>[
                    SizedBox(
                      width: 70,
                      child: Text('ID $gestureId'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: editor,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (String value) {
                          if (value.trim().isNotEmpty) {
                            controller.updatePhrase(gestureId, value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () {
                        final String value = editor.text.trim();
                        if (value.isNotEmpty) {
                          controller.updatePhrase(gestureId, value);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Saved phrase for ID $gestureId'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.save),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
