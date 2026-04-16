# AI Demo Selection Handoff

## Purpose

This document is for a second Codex instance that should work in parallel on
AI demo selection and deployment while the main instance continues rebuilding
the Bianbu image and source-built BSP flow.

The main objective for the second instance is:

- inspect the official SpacemiT demo bundle that was downloaded locally
- choose a camera-oriented CV demo that is practical for this board
- adapt it if needed for the current hardware and display session
- run it on the live board
- document the final run path

For now, skip Felipe's custom YOLO dashboard as the primary candidate. It is
already imported and working, but the next decision should come from the newer
official demo bundle.

## 1. What We Are Doing Here

This repository is the bring-up workspace for:

- Bianbu OS 3.0.x
- Banana Pi BPI-F3 as the current baseline target
- a future custom BF-3-derived board

The current project goals are split across two tracks:

### Track A: BSP / image-build work

This is already underway in the main instance:

- automated Bianbu image build
- SD and Titan flash packaging
- eMMC flash flow
- source-built kernel and source-built U-Boot integration
- DTB and board-customization preparation

At the moment, that rebuild is in progress after a fix to the source-kernel DTB
staging path.

Important context:

- the build now defaults to source-built kernel and source-built U-Boot
- OpenSBI is still from the packaged flow
- the current build issue being worked on was that source-built kernel DTBs
  were present under `usr/lib/linux-image-<version>/spacemit`, but were not
  being staged into `/boot/spacemit/<version>`
- that fix has already been patched in the current worktree

The second instance should avoid interfering with this track unless explicitly
asked.

### Track B: AI demo evaluation on the live board

This is the task for the second instance:

- evaluate the newly downloaded official SpacemiT demo repo
- shortlist the most useful camera demos
- adapt one of them for the current board and USB camera
- run it on the board display

## Workspace Caution

This worktree is currently dirty and contains active build-state artifacts.

Current areas that are part of the active build work and should be treated
carefully:

- [scripts/build-bianbu.sh](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/scripts/build-bianbu.sh:1)
- [scripts/build-rootfs-in-container.sh](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/scripts/build-rootfs-in-container.sh:1)
- [scripts/build-source-artifacts.sh](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/scripts/build-source-artifacts.sh:1)
- [docs/bianbu-build-automation.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/bianbu-build-automation.md:1)
- [docs/development-handoff.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/development-handoff.md:1)
- [docs/repo-handoff.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/repo-handoff.md:1)
- `sources/`
- `.bianbu-build/`
- `rootfs/`
- `pack_dir/`

If the second instance needs to copy or adapt the official demo repo into this
workspace, it should do so under a new subtree and avoid touching the active
BSP build files unless necessary.

## 2. Documentation We Currently Have

### Local repo documentation

- [docs/bianbu-build-automation.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/bianbu-build-automation.md:1)
  Main automation flow for build, image generation, flash artifacts, and
  source/default BSP modes.
- [docs/bianbu-image-update-instructions.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/bianbu-image-update-instructions.md:1)
  Older but still useful image update notes.
- [docs/development-handoff.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/development-handoff.md:1)
  The long-form continuity note for ongoing development.
- [docs/repo-handoff.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/repo-handoff.md:1)
  Repo scope and validated outcomes.
- [docs/emmc-flashing.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/emmc-flashing.md:1)
  eMMC flash flow and recovery notes.
- [docs/board-faq.md](/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/docs/board-faq.md:1)
  Board/peripheral observations such as touchscreen USB wiring.

### Board/platform references

- Banana Pi BPI-F3 overview:
  https://docs.banana-pi.org/en/BPI-F3/BananaPi_BPI-F3
- Banana Pi BPI-F3 getting started:
  https://docs.banana-pi.org/en/BPI-F3/GettingStarted_BPI-F3
- SpacemiT K1 documentation root:
  https://www.spacemit.com/community/document/info?lang=zh&nodepath=hardware/key_stone/k1/k1_docs/root_overview.md

### Bianbu system-integration references

- Rootfs creation:
  https://bianbu.spacemit.com/en/system_integration/bianbu_3.0_rootfs_create/
- Image generation:
  https://bianbu.spacemit.com/system_integration/image/

### Official AI demo references

- Bit-Brick SpacemiT AI Demo Repository page:
  https://docs.bit-brick.com/docs/k1/ml/spacemit-demo

Important takeaways from that page:

- it covers CV, NLP, speech, and multimodal examples
- the local repo layout is expected under `examples/CV` and `examples/NLP`
- official object-detection examples include `yolov5`, `yolov6`, `yolov8`,
  `yolov8-pose`, `yolov11`, and `yolo-world`

## 3. The Hardware We Have

### Main target board

- Board: Banana Pi BPI-F3
- SoC family: SpacemiT K1 / K1-X
- Current role: stock baseline before custom BF-3-derived board work

### Storage / image flow

- SD card image generation works
- Titan flash zip generation works
- eMMC flashing works
- the board has already booted successfully from eMMC in this project

### Display hardware

- 7-inch HDMI touchscreen display
- video path: HDMI from board to display
- touch path: USB from display to board

Important known requirement:

- if the display USB is connected to the dev machine instead of the board,
  touch input goes to the dev machine, not to the board

### USB camera

- Current webcam type: Xiongmai USB camera
- Stable symlink when present:
  - `/dev/v4l/by-id/usb-Xiongmai_web_camera_12345678-video-index0`
- Raw `/dev/videoN` numbering can change between runs

Observed on the live board during this work:

- image stream has appeared as `/dev/video20` or `/dev/video21`
- the symlink is the stable reference

### Other live hardware in use

- USB serial console adapter
- demo/target PCB board placed in front of camera for visual tests

### Future hardware direction

- eventual custom BF-3-derived board
- custom DTS / custom board identity work is planned after the source-kernel
  path is stable

## 4. How To SSH And Access The Board

### Board network access

- IP address: `192.168.28.85`
- user: `eaie`
- password: `eaie`

Direct SSH:

```bash
ssh eaie@192.168.28.85
```

Password-assisted SSH helper that exists on the dev machine:

```bash
sshp eaie@192.168.28.85 eaie
```

### Useful board-side paths

- user home: `/home/eaie`

### Live desktop session environment

The current GUI session runs under LXQt + labwc, with:

- `DISPLAY=:0`
- `WAYLAND_DISPLAY=wayland-0`
- `XDG_RUNTIME_DIR=/run/user/1000`

That matters for any GUI demo started from SSH.

### Serial access

If needed on the dev machine:

```bash
sudo picocom -b 115200 /dev/ttyUSB1
```

### Current board Python runtime state

These modules were confirmed to import successfully on the live board:

- `cv2`
- `numpy`
- `PIL`
- `tkinter`
- `spacemit_ort`

Important caveat:

- do not install `python3-onnxruntime` alongside `python3-spacemit-ort`
- that causes Python to import the generic `onnxruntime` package first and
  breaks `SpaceMITExecutionProvider` with:
  - `onnxruntime library maybe mismatch`

Working state on the board is:

- `python3-spacemit-ort` installed
- `onnxruntime` installed
- `python3-onnxruntime` removed

## 5. The AI Models We Intend To Use

### Current decision

Skip Felipe's custom model for now as the primary path.

The other instance should focus on the newer official SpacemiT demo bundle at:

- local path:
  [/media/guilhermes/ssd/EAIE/ai_demos/spacemit-demo](/media/guilhermes/ssd/EAIE/ai_demos/spacemit-demo)
- official docs:
  https://docs.bit-brick.com/docs/k1/ml/spacemit-demo

The user explicitly wants the other instance to evaluate those demos, choose a
camera-capable demo, and run it on the board.

### Local demo bundle structure

The local bundle already exists and includes at least:

- `examples/CV/yolov5`
- `examples/CV/yolov6`
- `examples/CV/yolov8`
- `examples/CV/yolov8-obb`
- `examples/CV/yolov8-pose`
- `examples/CV/yolov8-seg`
- `examples/CV/yolov11`
- `examples/CV/yolo-world`
- `examples/CV/yolov5-face`
- `examples/CV/ocr`
- plus classification / segmentation / tracking examples

### Best shortlist for camera-based evaluation

These are the most relevant candidates for the second instance:

1. `examples/CV/yolov8`
   Reason:
   general object detection, common baseline, camera mode supported,
   lightweight model family, likely easiest starting point.

2. `examples/CV/yolov6`
   Reason:
   another efficient detector with camera mode; good fallback if YOLOv8 has
   runtime or packaging issues.

3. `examples/CV/yolov11`
   Reason:
   newer detector, but potentially more moving parts; still worth testing.

4. `examples/CV/yolo-world`
   Reason:
   open-vocabulary detection can be useful for arbitrary object prompts, but
   likely has extra dependencies and prompt handling.

5. `examples/CV/yolov8-pose`
   Reason:
   only useful if the test target is a person / pose demo; otherwise lower
   priority.

6. `examples/CV/yolov8-seg`
   Reason:
   useful if segmentation is desired rather than boxes, but less likely the
   quickest win.

7. `examples/CV/yolov5-face` or `examples/CV/ocr`
   Reason:
   useful as quick sanity demos for camera + NPU, but not aligned with the PCB
   / target-object use case.

### Important local code observation

Many of the Python CV demos already support `--use-camera`, but several use
hardcoded camera indices such as:

- `cv2.VideoCapture(1)`
- sometimes `cv2.VideoCapture(0)`

Examples found in the local tree:

- `examples/CV/yolov8/python/test_yolov8.py`
- `examples/CV/yolov6/python/test_yolov6.py`
- `examples/CV/yolov11/python/test_yolov11.py`
- `examples/CV/yolov8-pose/python/test_yolov8_pose.py`
- `examples/CV/yolov8-seg/python/test_yolov8-seg.py`
- `examples/CV/yolo-world/python/test_yolo-world.py`
- `examples/CV/yolov5/python/test_yolov5.py`
- `examples/CV/yolov5-face/python/test_yolov5-face.py`
- `examples/CV/ocr/python/test_ocr.py`

This likely means the second instance will need to adapt the chosen demo for:

- the board's actual USB camera node
- preferably the stable `/dev/v4l/by-id/...video-index0` symlink
- or at least the current `/dev/video20` / `/dev/video21` device

### Recommended first choice

Start with:

- `examples/CV/yolov8`

Why:

- mainstream object detector
- official docs and local README are both present
- Python demo exists and already supports camera input
- likely best tradeoff between usefulness and adaptation effort

Secondary fallback:

- `examples/CV/yolov6`

If open-vocabulary detection is attractive:

- `examples/CV/yolo-world`

## What The Second Instance Should Do

1. Read this handoff and the local docs listed above.
2. Inspect:
   - `/media/guilhermes/ssd/EAIE/ai_demos/spacemit-demo`
3. If needed, copy the chosen demo subtree into this workspace under a safe new
   path.
4. Avoid interfering with the active BSP rebuild files unless necessary.
5. Pick one camera-capable CV demo, preferably `yolov8` first.
6. Adapt camera selection away from hardcoded `cv2.VideoCapture(1)` if needed.
7. Adapt display execution to the current board session:
   - `DISPLAY=:0`
   - `WAYLAND_DISPLAY=wayland-0`
   - `XDG_RUNTIME_DIR=/run/user/1000`
8. Reuse the working board Python/NPU environment if possible.
9. Run the chosen demo on the board with the attached USB camera.
10. Document exactly what worked, what had to be patched, and how to start and
    stop it.

## Final Note

The main instance is still busy with build-system and source-BSP work. The
second instance should treat AI demo evaluation as the priority and keep its
changes isolated and well documented.
