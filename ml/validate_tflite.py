import argparse
from pathlib import Path

import numpy as np
import tensorflow as tf


def main():
    parser = argparse.ArgumentParser(description="Validate gesture TFLite model IO shapes")
    parser.add_argument("--model", default="assets/models/gesture_classifier.tflite")
    parser.add_argument("--classes", type=int, default=6)
    args = parser.parse_args()

    model_path = Path(args.model)
    if not model_path.exists():
        raise FileNotFoundError(f"Model file not found: {model_path}")

    interpreter = tf.lite.Interpreter(model_path=str(model_path))
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()[0]
    output_details = interpreter.get_output_details()[0]

    print("Input tensor:")
    print(input_details)
    print("Output tensor:")
    print(output_details)

    input_shape = input_details["shape"]
    output_shape = output_details["shape"]

    if len(input_shape) != 4:
        raise ValueError(f"Expected 4D input tensor, got {input_shape}")

    if output_shape[-1] != args.classes:
        raise ValueError(
            f"Expected output class count {args.classes}, got {output_shape[-1]}"
        )

    h = int(input_shape[1])
    w = int(input_shape[2])
    c = int(input_shape[3])

    dummy = np.random.rand(1, h, w, c).astype(np.float32)
    interpreter.set_tensor(input_details["index"], dummy)
    interpreter.invoke()
    scores = interpreter.get_tensor(output_details["index"])[0]

    print(f"Inference output length: {len(scores)}")
    print(f"Top class index (0-based): {int(np.argmax(scores))}")
    print("Model validation passed.")


if __name__ == "__main__":
    main()
