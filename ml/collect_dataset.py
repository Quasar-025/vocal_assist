import argparse
import shutil
import time
from pathlib import Path

import cv2

CLASS_NAMES = [
    "fist",
    "open_palm",
    "point",
    "ok",
    "wave_left",
    "wave_right",
]


def clear_dataset(root: Path) -> None:
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)


def ensure_class_dirs(root: Path) -> None:
    for class_name in CLASS_NAMES:
        (root / class_name).mkdir(parents=True, exist_ok=True)


def center_crop(frame):
    h, w = frame.shape[:2]
    side = min(h, w)
    y1 = (h - side) // 2
    x1 = (w - side) // 2
    return frame[y1:y1 + side, x1:x1 + side]


def preprocess_frame(frame, image_size: int):
    cropped = center_crop(frame)
    gray = cv2.cvtColor(cropped, cv2.COLOR_BGR2GRAY)
    resized = cv2.resize(gray, (image_size, image_size), interpolation=cv2.INTER_AREA)
    return resized


def run_capture(dataset_dir: Path, samples_per_class: int, image_size: int, countdown: int) -> None:
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        raise RuntimeError("Could not open default camera")

    print("\nCapture started.")
    print("Instructions:")
    print("1) Keep your hand in the center square.")
    print("2) Press SPACE to capture each sample.")
    print("3) Press Q to quit early.\n")

    try:
        for class_name in CLASS_NAMES:
            print(f"\n=== Class: {class_name} ===")
            print(f"Get ready... capture starts in {countdown} seconds")
            for i in range(countdown, 0, -1):
                print(f"{i}...")
                time.sleep(1)

            class_dir = dataset_dir / class_name
            sample_idx = 0

            while sample_idx < samples_per_class:
                ok, frame = cap.read()
                if not ok:
                    continue

                display = frame.copy()
                h, w = display.shape[:2]
                side = int(min(h, w) * 0.6)
                x1 = (w - side) // 2
                y1 = (h - side) // 2
                x2 = x1 + side
                y2 = y1 + side

                cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(
                    display,
                    f"Class: {class_name}  [{sample_idx}/{samples_per_class}]",
                    (20, 40),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.8,
                    (0, 255, 0),
                    2,
                )
                cv2.putText(
                    display,
                    "SPACE: capture | Q: quit",
                    (20, 75),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    (255, 255, 255),
                    2,
                )

                cv2.imshow("Gesture Dataset Capture", display)
                key = cv2.waitKey(1) & 0xFF

                if key == ord("q"):
                    print("Stopped by user")
                    return

                if key == ord(" "):
                    image = preprocess_frame(frame, image_size)
                    out_path = class_dir / f"{class_name}_{sample_idx:04d}.png"
                    cv2.imwrite(str(out_path), image)
                    sample_idx += 1
                    print(f"Saved {out_path.name}")

            print(f"Completed class {class_name}.")

        print("\nDataset capture complete.")
    finally:
        cap.release()
        cv2.destroyAllWindows()


def main():
    parser = argparse.ArgumentParser(description="Collect gesture images for model training")
    parser.add_argument("--dataset-dir", default="ml/dataset", help="Output dataset directory")
    parser.add_argument("--samples-per-class", type=int, default=250, help="Images per class")
    parser.add_argument("--image-size", type=int, default=224, help="Square image size")
    parser.add_argument("--countdown", type=int, default=3, help="Seconds before each class")
    parser.add_argument("--reset", action="store_true", help="Delete existing dataset first")
    args = parser.parse_args()

    dataset_dir = Path(args.dataset_dir)
    if args.reset:
        clear_dataset(dataset_dir)
    dataset_dir.mkdir(parents=True, exist_ok=True)
    ensure_class_dirs(dataset_dir)

    run_capture(
        dataset_dir=dataset_dir,
        samples_per_class=args.samples_per_class,
        image_size=args.image_size,
        countdown=args.countdown,
    )


if __name__ == "__main__":
    main()
