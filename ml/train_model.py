import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import tensorflow as tf

CLASS_NAMES = [
    "fist",
    "open_palm",
    "point",
    "ok",
    "wave_left",
    "wave_right",
]


def make_model(image_size: int, class_count: int) -> tf.keras.Model:
    return tf.keras.Sequential(
        [
            tf.keras.layers.Input(shape=(image_size, image_size, 1)),
            tf.keras.layers.Conv2D(16, 3, activation="relu", padding="same"),
            tf.keras.layers.MaxPooling2D(),
            tf.keras.layers.Conv2D(32, 3, activation="relu", padding="same"),
            tf.keras.layers.MaxPooling2D(),
            tf.keras.layers.Conv2D(64, 3, activation="relu", padding="same"),
            tf.keras.layers.MaxPooling2D(),
            tf.keras.layers.Dropout(0.25),
            tf.keras.layers.Flatten(),
            tf.keras.layers.Dense(128, activation="relu"),
            tf.keras.layers.Dropout(0.3),
            tf.keras.layers.Dense(class_count, activation="softmax"),
        ]
    )


def save_training_plot(history, out_png: Path) -> None:
    plt.figure(figsize=(10, 4))

    plt.subplot(1, 2, 1)
    plt.plot(history.history["accuracy"], label="train")
    plt.plot(history.history["val_accuracy"], label="val")
    plt.title("Accuracy")
    plt.xlabel("Epoch")
    plt.legend()

    plt.subplot(1, 2, 2)
    plt.plot(history.history["loss"], label="train")
    plt.plot(history.history["val_loss"], label="val")
    plt.title("Loss")
    plt.xlabel("Epoch")
    plt.legend()

    plt.tight_layout()
    plt.savefig(out_png)


def convert_to_tflite(model: tf.keras.Model, out_path: Path) -> None:
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()
    out_path.write_bytes(tflite_model)


def main():
    parser = argparse.ArgumentParser(description="Train and export gesture TFLite model")
    parser.add_argument("--dataset-dir", default="ml/dataset", help="Dataset root")
    parser.add_argument("--artifacts-dir", default="ml/artifacts", help="Model output directory")
    parser.add_argument("--image-size", type=int, default=224)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--copy-to-app", action="store_true", help="Copy .tflite into app assets")
    args = parser.parse_args()

    dataset_dir = Path(args.dataset_dir)
    artifacts_dir = Path(args.artifacts_dir)
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    if not dataset_dir.exists():
        raise FileNotFoundError(f"Dataset dir not found: {dataset_dir}")

    tf.random.set_seed(args.seed)
    np.random.seed(args.seed)

    train_ds = tf.keras.utils.image_dataset_from_directory(
        dataset_dir,
        labels="inferred",
        class_names=CLASS_NAMES,
        label_mode="int",
        color_mode="grayscale",
        batch_size=args.batch_size,
        image_size=(args.image_size, args.image_size),
        validation_split=0.2,
        subset="training",
        seed=args.seed,
    )

    val_ds = tf.keras.utils.image_dataset_from_directory(
        dataset_dir,
        labels="inferred",
        class_names=CLASS_NAMES,
        label_mode="int",
        color_mode="grayscale",
        batch_size=args.batch_size,
        image_size=(args.image_size, args.image_size),
        validation_split=0.2,
        subset="validation",
        seed=args.seed,
    )

    class_names = train_ds.class_names

    normalization = tf.keras.layers.Rescaling(1.0 / 255.0)
    train_ds = train_ds.map(lambda x, y: (normalization(x), y)).prefetch(tf.data.AUTOTUNE)
    val_ds = val_ds.map(lambda x, y: (normalization(x), y)).prefetch(tf.data.AUTOTUNE)

    model = make_model(args.image_size, len(class_names))
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    callbacks = [
        tf.keras.callbacks.EarlyStopping(
            monitor="val_accuracy", patience=4, restore_best_weights=True
        )
    ]

    history = model.fit(train_ds, validation_data=val_ds, epochs=args.epochs, callbacks=callbacks)

    eval_loss, eval_acc = model.evaluate(val_ds, verbose=0)
    print(f"Validation accuracy: {eval_acc:.4f}")
    print(f"Validation loss: {eval_loss:.4f}")

    keras_path = artifacts_dir / "gesture_classifier.keras"
    tflite_path = artifacts_dir / "gesture_classifier.tflite"
    plot_path = artifacts_dir / "training_curves.png"
    meta_path = artifacts_dir / "metrics.json"

    model.save(keras_path)
    convert_to_tflite(model, tflite_path)
    save_training_plot(history, plot_path)

    meta = {
        "validation_accuracy": float(eval_acc),
        "validation_loss": float(eval_loss),
        "classes": class_names,
        "image_size": args.image_size,
        "batch_size": args.batch_size,
        "epochs_requested": args.epochs,
        "epochs_ran": len(history.history["loss"]),
    }
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")

    print(f"Saved Keras model: {keras_path}")
    print(f"Saved TFLite model: {tflite_path}")
    print(f"Saved curves: {plot_path}")
    print(f"Saved metrics: {meta_path}")

    if args.copy_to_app:
        app_model_path = Path("assets/models/gesture_classifier.tflite")
        app_model_path.write_bytes(tflite_path.read_bytes())
        print(f"Copied model to app asset path: {app_model_path}")


if __name__ == "__main__":
    main()
