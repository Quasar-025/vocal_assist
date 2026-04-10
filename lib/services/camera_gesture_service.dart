import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class LandmarkConnection {
  LandmarkConnection(this.start, this.end);

  final Offset start;
  final Offset end;
}

class CameraGestureEvent {
  CameraGestureEvent({
    required this.gestureId,
    required this.confidence,
    required this.timestamp,
  });

  final int gestureId;
  final double confidence;
  final DateTime timestamp;
}

class CameraGestureService {
  CameraGestureService({
    this.modelAssetPath = 'assets/models/gesture_classifier.tflite',
    this.gestureClasses = 6,
    this.minConfidence = 0.65,
    this.minStableFrames = 3,
    this.minEmitGap = const Duration(milliseconds: 700),
    this.inferenceInterval = const Duration(milliseconds: 140),
  });

  final String modelAssetPath;
  final int gestureClasses;
  final double minConfidence;
  final int minStableFrames;
  final Duration minEmitGap;
  final Duration inferenceInterval;

  final StreamController<CameraGestureEvent> _events =
      StreamController<CameraGestureEvent>.broadcast();

  CameraController? _cameraController;
  Interpreter? _interpreter;
  CameraImage? _latestFrame;
  Timer? _inferenceTicker;
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
  );
  CameraDescription? _activeCamera;

  int? _lastCandidate;
  int _stableFrameCount = 0;
  int? _lastEmittedGesture;
  DateTime _lastEmitTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool _isRunning = false;
  bool _isInferencing = false;
  bool _isPoseRunning = false;
  bool _modelLoaded = false;

  String statusMessage = 'Camera idle';
  double lastConfidence = 0.0;
  String? modelLoadError;
  List<Offset> handLandmarkPoints = <Offset>[];
  List<LandmarkConnection> handLandmarkConnections = <LandmarkConnection>[];
  final ValueNotifier<int> overlayVersion = ValueNotifier<int>(0);

  Stream<CameraGestureEvent> get events => _events.stream;
  CameraController? get cameraController => _cameraController;
  bool get isRunning => _isRunning;
  bool get hasLoadedModel => _modelLoaded;

  Future<void> start() async {
    if (_isRunning) {
      return;
    }

    statusMessage = 'Initializing camera...';
    final List<CameraDescription> cameras = await availableCameras();
    if (cameras.isEmpty) {
      statusMessage = 'No camera available';
      return;
    }

    final CameraDescription selected = cameras.firstWhere(
      (CameraDescription c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _activeCamera = selected;

    _cameraController = CameraController(
      selected,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
        ? ImageFormatGroup.bgra8888
        : ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();

    try {
      _interpreter = await Interpreter.fromAsset(modelAssetPath);
      _modelLoaded = true;
      modelLoadError = null;
      statusMessage = 'Camera running';
    } catch (e) {
      _interpreter = null;
      _modelLoaded = false;
      modelLoadError = e.toString();
      statusMessage = 'Model load failed. Add a valid TFLite model in assets/models/gesture_classifier.tflite';
    }

    await _cameraController!.startImageStream((CameraImage image) {
      _latestFrame = image;
    });

    _inferenceTicker = Timer.periodic(inferenceInterval, (_) {
      unawaited(_runInferenceTick());
      unawaited(_runPoseTick());
    });

    _isRunning = true;
  }

  Future<void> stop() async {
    _inferenceTicker?.cancel();
    _inferenceTicker = null;

    final CameraController? controller = _cameraController;
    _cameraController = null;
    _latestFrame = null;

    if (controller != null) {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    }

    _isRunning = false;
    statusMessage = 'Camera stopped';
    _modelLoaded = false;
    handLandmarkPoints = <Offset>[];
    handLandmarkConnections = <LandmarkConnection>[];
    _notifyOverlayChanged();
  }

  Future<void> dispose() async {
    await stop();
    await _poseDetector.close();
    overlayVersion.dispose();
    await _events.close();
  }

  void _notifyOverlayChanged() {
    overlayVersion.value = overlayVersion.value + 1;
  }

  Future<void> _runPoseTick() async {
    if (!_isRunning || _isPoseRunning) {
      return;
    }

    final CameraImage? frame = _latestFrame;
    final CameraDescription? camera = _activeCamera;
    if (frame == null || camera == null) {
      return;
    }

    final InputImage? inputImage = _toInputImage(frame, camera);
    if (inputImage == null) {
      return;
    }

    _isPoseRunning = true;
    try {
      final List<Pose> poses = await _poseDetector.processImage(inputImage);
      if (poses.isEmpty) {
        handLandmarkPoints = <Offset>[];
        handLandmarkConnections = <LandmarkConnection>[];
        _notifyOverlayChanged();
        return;
      }

      final Pose pose = poses.first;
      final _HandSideLandmarks left = _extractHandSide(
        pose,
        frame.width.toDouble(),
        frame.height.toDouble(),
        isLeft: true,
      );
      final _HandSideLandmarks right = _extractHandSide(
        pose,
        frame.width.toDouble(),
        frame.height.toDouble(),
        isLeft: false,
      );

      handLandmarkPoints = <Offset>[...left.points, ...right.points];
      handLandmarkConnections = <LandmarkConnection>[
        ...left.connections,
        ...right.connections,
      ];
      _notifyOverlayChanged();
    } catch (_) {
      handLandmarkPoints = <Offset>[];
      handLandmarkConnections = <LandmarkConnection>[];
      _notifyOverlayChanged();
    } finally {
      _isPoseRunning = false;
    }
  }

  Future<void> _runInferenceTick() async {
    if (!_isRunning || _isInferencing) {
      return;
    }

    final Interpreter? interpreter = _interpreter;
    final CameraImage? frame = _latestFrame;
    if (interpreter == null || frame == null) {
      return;
    }

    _isInferencing = true;
    try {
      final List<List<List<List<double>>>> input = _toModelInput(frame);
      final List<List<double>> output = <List<double>>[
        List<double>.filled(gestureClasses, 0.0),
      ];

      interpreter.run(input, output);

      final List<double> scores = output.first;
      int bestIndex = 0;
      double bestScore = -double.infinity;
      for (int i = 0; i < scores.length; i++) {
        if (scores[i] > bestScore) {
          bestScore = scores[i];
          bestIndex = i;
        }
      }

      final int predictedGesture = bestIndex + 1;
      final double confidence = bestScore;
      lastConfidence = confidence;

      if (confidence < minConfidence) {
        _stableFrameCount = 0;
        _lastCandidate = null;
        return;
      }

      if (_lastCandidate == predictedGesture) {
        _stableFrameCount += 1;
      } else {
        _lastCandidate = predictedGesture;
        _stableFrameCount = 1;
      }

      if (_stableFrameCount < minStableFrames) {
        return;
      }

      final DateTime now = DateTime.now();
      if (_lastEmittedGesture == predictedGesture &&
          now.difference(_lastEmitTime) < minEmitGap) {
        return;
      }

      _lastEmittedGesture = predictedGesture;
      _lastEmitTime = now;
      _events.add(
        CameraGestureEvent(
          gestureId: predictedGesture,
          confidence: confidence,
          timestamp: now,
        ),
      );
    } finally {
      _isInferencing = false;
    }
  }

  List<List<List<List<double>>>> _toModelInput(CameraImage image) {
    const int targetSize = 224;

    final Plane yPlane = image.planes.first;
    final int sourceWidth = image.width;
    final int sourceHeight = image.height;
    final Uint8List bytes = yPlane.bytes;

    final List<List<List<List<double>>>> input =
        List<List<List<List<double>>>>.generate(
      1,
      (_) => List<List<List<double>>>.generate(
        targetSize,
        (_) => List<List<double>>.generate(
          targetSize,
          (_) => List<double>.filled(3, 0.0),
        ),
      ),
    );

    for (int y = 0; y < targetSize; y++) {
      final int srcY = (y * sourceHeight / targetSize).floor();
      final int rowOffset = srcY * yPlane.bytesPerRow;
      for (int x = 0; x < targetSize; x++) {
        final int srcX = (x * sourceWidth / targetSize).floor();
        final int pixelIndex = min(rowOffset + srcX, bytes.length - 1);
        final double normalized = (bytes[pixelIndex] / 255.0);

        input[0][y][x][0] = normalized;
        input[0][y][x][1] = normalized;
        input[0][y][x][2] = normalized;
      }
    }

    return input;
  }

  InputImage? _toInputImage(CameraImage image, CameraDescription camera) {
    final InputImageRotation? rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) {
      return null;
    }

    final InputImageFormat? format =
        InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      return null;
    }

    final BytesBuilder allBytes = BytesBuilder(copy: false);
    for (final Plane plane in image.planes) {
      allBytes.add(plane.bytes);
    }
    final Uint8List bytes = allBytes.takeBytes();

    final InputImageMetadata metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  _HandSideLandmarks _extractHandSide(
    Pose pose,
    double width,
    double height, {
    required bool isLeft,
  }) {
    final PoseLandmark? wrist = pose.landmarks[
        isLeft ? PoseLandmarkType.leftWrist : PoseLandmarkType.rightWrist];
    final PoseLandmark? thumb = pose.landmarks[
        isLeft ? PoseLandmarkType.leftThumb : PoseLandmarkType.rightThumb];
    final PoseLandmark? index = pose.landmarks[
        isLeft ? PoseLandmarkType.leftIndex : PoseLandmarkType.rightIndex];
    final PoseLandmark? pinky = pose.landmarks[
        isLeft ? PoseLandmarkType.leftPinky : PoseLandmarkType.rightPinky];

    final List<PoseLandmark> available = <PoseLandmark>[];
    for (final PoseLandmark? item in <PoseLandmark?>[wrist, thumb, index, pinky]) {
      if (item != null) {
        available.add(item);
      }
    }

    final List<Offset> points = available
        .map((PoseLandmark lm) => Offset(lm.x / width, lm.y / height))
        .toList();

    final List<LandmarkConnection> lines = <LandmarkConnection>[];
    if (wrist != null && thumb != null) {
      lines.add(LandmarkConnection(
        Offset(wrist.x / width, wrist.y / height),
        Offset(thumb.x / width, thumb.y / height),
      ));
    }
    if (wrist != null && index != null) {
      lines.add(LandmarkConnection(
        Offset(wrist.x / width, wrist.y / height),
        Offset(index.x / width, index.y / height),
      ));
    }
    if (wrist != null && pinky != null) {
      lines.add(LandmarkConnection(
        Offset(wrist.x / width, wrist.y / height),
        Offset(pinky.x / width, pinky.y / height),
      ));
    }
    if (thumb != null && index != null) {
      lines.add(LandmarkConnection(
        Offset(thumb.x / width, thumb.y / height),
        Offset(index.x / width, index.y / height),
      ));
    }

    return _HandSideLandmarks(points: points, connections: lines);
  }
}

class _HandSideLandmarks {
  _HandSideLandmarks({required this.points, required this.connections});

  final List<Offset> points;
  final List<LandmarkConnection> connections;
}
