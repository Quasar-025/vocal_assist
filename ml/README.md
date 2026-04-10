# Train Camera Gesture Model (From Scratch)

This folder contains everything needed to build your own TensorFlow Lite model for the app camera mode.

## Target Classes (fixed order)
1. `fist`
2. `open_palm`
3. `point`
4. `ok`
5. `wave_left`
6. `wave_right`

The app expects this exact order. Do not rename class folders.

## 1) Install Python packages
From project root (`gesture_voice_app`):

```bash
py -3.11 -m venv .venv311
.venv311\Scripts\python.exe -m pip install --upgrade pip
.venv311\Scripts\python.exe -m pip install -r ml/requirements.txt
```

Why 3.11:
- TensorFlow 2.16.x is stable on Python 3.11 for this workflow.
- If you use Python 3.12/3.13, the requirements file will switch to TensorFlow 2.21 automatically.

## 2) Collect dataset
This opens webcam capture and stores grayscale 224x224 images.

```bash
.venv311\Scripts\python.exe ml/collect_dataset.py --reset --samples-per-class 250 --image-size 224
```

Recommended minimum:
- 250 images/class for quick baseline
- 500+ images/class for better performance

Capture in multiple conditions:
- bright + dim light
- different backgrounds
- slight hand angle variations
- different distances from camera

## 3) Train and export TFLite

```bash
.venv311\Scripts\python.exe ml/train_model.py --dataset-dir ml/dataset --artifacts-dir ml/artifacts --epochs 20 --copy-to-app
```

Outputs:
- `ml/artifacts/gesture_classifier.keras`
- `ml/artifacts/gesture_classifier.tflite`
- `ml/artifacts/training_curves.png`
- `ml/artifacts/metrics.json`

`--copy-to-app` also writes:
- `assets/models/gesture_classifier.tflite`

## 4) Run app

```bash
flutter pub get
flutter run
```

If camera mode still reports model load error:
- verify file exists at `assets/models/gesture_classifier.tflite`
- run `flutter clean` then `flutter run`

## 5) Validate TFLite tensor shapes (recommended)

```bash
.venv311\Scripts\python.exe ml/validate_tflite.py --model assets/models/gesture_classifier.tflite --classes 6
```

This confirms the model can load and that output class count is 6.

## Notes
- Current app pipeline feeds grayscale camera frames resized to 224x224 into the model.
- Model output must be a softmax vector of length 6.
- If validation accuracy is below 0.85, collect more data and retrain.


py -3.11 -m venv .venv311
.venv311\Scripts\python.exe -m pip install --upgrade pip
.venv311\Scripts\python.exe -m pip install -r ml/requirements.txt

Then run your model pipeline
.venv311\Scripts\python.exe ml/collect_dataset.py --reset --samples-per-class 250 --image-size 224
.venv311\Scripts\python.exe ml/train_model.py --dataset-dir ml/dataset --artifacts-dir ml/artifacts --epochs 20 --copy-to-app
.venv311\Scripts\python.exe ml/validate_tflite.py --model assets/models/gesture_classifier.tflite --classes 6