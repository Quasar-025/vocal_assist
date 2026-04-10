# Camera Gesture Model

Place your trained TFLite model at:
- `assets/models/gesture_classifier.tflite`

The app expects model output classes in this exact order:
1. Fist
2. Open Palm
3. Point
4. OK
5. Wave Left
6. Wave Right

Notes:
- The current camera pipeline converts camera frames to grayscale and resizes to 224x224.
- If your model has a different input shape or color format, update `lib/services/camera_gesture_service.dart`.
