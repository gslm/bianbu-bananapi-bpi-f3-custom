#!/usr/bin/env python3
"""Render board status text to the kernel-bound SSD1306 framebuffer."""

from __future__ import annotations

import argparse
import os
import subprocess
import time
from collections.abc import Sequence
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


DEFAULT_INTERFACES = ("end0", "wlan0")


def env_list(name: str, default: Sequence[str]) -> list[str]:
    value = os.environ.get(name, "").strip()
    if not value:
        return list(default)
    return value.split()


def env_float(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    return float(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Display selected interface IPv4 addresses on /dev/fbX."
    )
    parser.add_argument(
        "--fb",
        default=os.environ.get("EAIE_OLED_FB", ""),
        help="Framebuffer device. Defaults to the fb named ssd130xdrmfb.",
    )
    parser.add_argument(
        "--interfaces",
        nargs="+",
        default=env_list("EAIE_OLED_INTERFACES", DEFAULT_INTERFACES),
        help="Network interfaces to display.",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=env_float("EAIE_OLED_REFRESH_SECONDS", 3.0),
        help="Refresh interval in seconds.",
    )
    parser.add_argument(
        "--wait-seconds",
        type=float,
        default=env_float("EAIE_OLED_WAIT_SECONDS", 30.0),
        help="How long to wait for the SSD1306 framebuffer at startup.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Render once and exit instead of refreshing forever.",
    )
    return parser.parse_args()


def read_sysfs(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def find_ssd130x_framebuffer() -> Path | None:
    for fb_sysfs in sorted(Path("/sys/class/graphics").glob("fb[0-9]*")):
        name_path = fb_sysfs / "name"
        if name_path.exists() and read_sysfs(name_path) == "ssd130xdrmfb":
            return Path("/dev") / fb_sysfs.name
    return None


def wait_for_framebuffer(explicit_fb: str, wait_seconds: float) -> Path:
    if explicit_fb:
        fb_device = Path(explicit_fb)
        deadline = time.monotonic() + wait_seconds
        while time.monotonic() <= deadline:
            if fb_device.exists():
                return fb_device
            time.sleep(0.5)
        raise RuntimeError(f"Framebuffer device did not appear: {fb_device}")

    deadline = time.monotonic() + wait_seconds
    while time.monotonic() <= deadline:
        fb_device = find_ssd130x_framebuffer()
        if fb_device:
            return fb_device
        time.sleep(0.5)

    raise RuntimeError("Could not find an ssd130xdrmfb framebuffer")


def framebuffer_info(fb_device: Path) -> tuple[int, int, int, int]:
    fb_name = fb_device.name
    fb_sysfs = Path("/sys/class/graphics") / fb_name

    width_text, height_text = read_sysfs(fb_sysfs / "virtual_size").split(",", 1)
    bits_per_pixel = int(read_sysfs(fb_sysfs / "bits_per_pixel"))
    stride = int(read_sysfs(fb_sysfs / "stride"))

    return int(width_text), int(height_text), bits_per_pixel, stride


def ipv4_for_interface(interface: str) -> str:
    result = subprocess.run(
        ["ip", "-4", "-o", "addr", "show", "dev", interface],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return "none"

    for line in result.stdout.splitlines():
        parts = line.split()
        if "inet" not in parts:
            continue
        address = parts[parts.index("inet") + 1].split("/", maxsplit=1)[0]
        if address:
            return address

    return "none"


def render_image(width: int, height: int, interfaces: Sequence[str]) -> Image.Image:
    image = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()

    y = 0
    for interface in interfaces:
        draw.text((0, y), f"{interface}: {ipv4_for_interface(interface)}"[:24], font=font, fill=255)
        y += 14
        if y >= height:
            break

    return image


def image_to_xrgb8888_rows(image: Image.Image, stride: int) -> bytes:
    width, height = image.size
    pixels = image.tobytes()
    row_size = width * 4
    if stride < row_size:
        raise RuntimeError(f"Framebuffer stride {stride} is smaller than {row_size}")

    rows = []
    for y in range(height):
        offset = y * width
        row = bytearray()
        for value in pixels[offset : offset + width]:
            row.extend((value, value, value, 0x00))
        row.extend(b"\x00" * (stride - row_size))
        rows.append(bytes(row))

    return b"".join(rows)


def write_frame(fb_device: Path, frame: bytes) -> None:
    with fb_device.open("r+b", buffering=0) as fb:
        fb.write(frame)


def main() -> None:
    args = parse_args()
    fb_device = wait_for_framebuffer(args.fb, args.wait_seconds)
    width, height, bits_per_pixel, stride = framebuffer_info(fb_device)

    if bits_per_pixel != 32:
        raise RuntimeError(f"Unsupported framebuffer depth: {bits_per_pixel} bpp")

    while True:
        image = render_image(width, height, args.interfaces)
        write_frame(fb_device, image_to_xrgb8888_rows(image, stride))
        if args.once:
            print(
                f"Rendered {', '.join(args.interfaces)} to {fb_device} "
                f"({width}x{height}, {bits_per_pixel}bpp, stride {stride})"
            )
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
