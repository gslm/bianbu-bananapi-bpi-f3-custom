"""
YOLOv8 camera demo adapted for BPI-F3 / Xiongmai USB camera.

Changes vs. the upstream test_yolov8.py:
  - Replaces hardcoded cv2.VideoCapture(1) with --camera-device arg.
  - Default is the stable udev symlink for the Xiongmai camera; falls back
    through /dev/video20, /dev/video21, and index 0 if that fails.
  - Prints active ONNX Runtime execution providers so NPU use is confirmed.
  - utils.py reads '../data/label.txt' at import time relative to cwd; this
    script chdir's to its own directory before importing utils so the relative
    path resolves correctly regardless of where the script is invoked from.
"""

import cv2
import numpy as np
import argparse
import os
import sys
import time
import onnxruntime
import spacemit_ort  # registers SpaceMITExecutionProvider

# Disable GStreamer backend — it intercepts /dev/ paths but can't handle them
# on this board, which prevents OpenCV's V4L2 backend from being tried.
os.environ["OPENCV_VIDEOIO_PRIORITY_GSTREAMER"] = "0"

STABLE_CAMERA_SYMLINK = (
    "/dev/v4l/by-id/usb-Xiongmai_web_camera_12345678-video-index0"
)
# /dev/video0 is the Linlon encoder, not a capture device — excluded
FALLBACK_DEVICES = ["/dev/video20", "/dev/video21"]


def open_camera(device):
    """Try to open device, then fall back to known alternatives.

    Only checks isOpened() — frame validity is handled in the main loop.
    Note: CAP_V4L2 cannot open devices by string path on this OpenCV build;
    we let OpenCV fall through GStreamer (which fails) to its V4L2 fallback.
    """
    cap = cv2.VideoCapture(device)
    if cap.isOpened():
        print(f"[camera] opened: {device}")
        return cap
    cap.release()

    for fallback in FALLBACK_DEVICES:
        if fallback == device:
            continue
        cap = cv2.VideoCapture(fallback)
        if cap.isOpened():
            print(f"[camera] primary failed, using fallback: {fallback}")
            return cap
        cap.release()

    raise RuntimeError(
        f"Could not open any camera (tried {device!r} and {FALLBACK_DEVICES})"
    )


def main():
    parser = argparse.ArgumentParser(description="YOLOv8 camera demo — BPI-F3")
    parser.add_argument(
        "--model",
        type=str,
        default="../model/yolov8n_192x320.q.onnx",
        help="Path to the YOLOv8 ONNX model",
    )
    parser.add_argument(
        "--camera-device",
        type=str,
        default=STABLE_CAMERA_SYMLINK,
        help="Camera device path or integer index (default: stable udev symlink)",
    )
    parser.add_argument(
        "--conf-threshold",
        type=float,
        default=0.6,
        help="Confidence threshold",
    )
    parser.add_argument(
        "--iou-threshold",
        type=float,
        default=0.5,
        help="IOU threshold for NMS",
    )
    args = parser.parse_args()

    # Coerce to int if the camera arg looks like a bare index
    try:
        camera_arg = int(args.camera_device)
    except ValueError:
        camera_arg = args.camera_device

    # utils.py reads '../data/label.txt' relative to cwd at import time.
    # Chdir to this script's directory so the path resolves correctly.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    original_cwd = os.getcwd()
    os.chdir(script_dir)

    from utils import Yolov8Detection

    # Print active providers — confirms NPU usage before any work starts
    sess_opts = onnxruntime.SessionOptions()
    sess_opts.intra_op_num_threads = 4
    probe = onnxruntime.InferenceSession(
        args.model, sess_opts=sess_opts, providers=["SpaceMITExecutionProvider"]
    )
    active = probe.get_providers()
    print(f"[NPU] Active execution providers: {active}")
    if "SpaceMITExecutionProvider" in active:
        print("[NPU] SpaceMITExecutionProvider is active — NPU is in use.")
    else:
        print("[NPU] WARNING: SpaceMITExecutionProvider NOT active. Running on CPU.")
    del probe

    detector = Yolov8Detection(args.model, args.conf_threshold, args.iou_threshold)

    cap = open_camera(camera_arg)
    print("[demo] Starting camera loop. Press 'q' to quit.")

    win = "YOLOv8 - BPI-F3 NPU"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.setWindowProperty(win, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)

    prev_time = time.time()
    consecutive_failures = 0

    try:
        while True:
            ret, frame = cap.read()
            if not ret or frame is None:
                consecutive_failures += 1
                if consecutive_failures > 30:
                    print("[demo] Camera stopped delivering frames. Exiting.")
                    break
                continue
            consecutive_failures = 0

            result_image = detector.infer(frame)

            # FPS overlay
            now = time.time()
            fps = 1.0 / (now - prev_time) if (now - prev_time) > 0 else 0
            prev_time = now
            cv2.putText(result_image, f"FPS: {fps:.1f}", (10, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 0), 2)

            cv2.imshow(win, result_image)

            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

    finally:
        cap.release()
        cv2.destroyAllWindows()
        os.chdir(original_cwd)


if __name__ == "__main__":
    main()
