# Accelerometer Demo — Learning Reference

Reading guide for understanding the accelerometer-axis demo's source in detail.
Aimed at someone with limited Python experience and no prior PyQt or OpenGL
exposure.

## What this set of documents is

A walking-tour of the demo and the technologies it uses. Light enough that you
can read it cover-to-cover in an afternoon, dense enough that afterwards you
should be able to:

- Read any line of [app_accel.py](../app_accel.py) and explain what it does.
- Make targeted modifications without breaking other parts of the app.
- Spot suspicious changes during code review.

It does not try to be a full Python, PyQt6, or OpenGL textbook. Each topic is
covered only to the depth needed to read the actual demo code.

## Documents

| File | Topic |
|---|---|
| [01-PYTHON-CONCEPTS.md](01-PYTHON-CONCEPTS.md) | Python language features used in `app_accel.py` |
| [02-PYSIDE6-CONCEPTS.md](02-PYSIDE6-CONCEPTS.md) | Qt6 / PySide6 fundamentals |
| [03-OPENGL-CONCEPTS.md](03-OPENGL-CONCEPTS.md) | OpenGL ES 3.0 rendering fundamentals |
| [04-APP-WALKTHROUGH.md](04-APP-WALKTHROUGH.md) | Function-by-function tour of `app_accel.py` |
| [05-SCAFFOLDING.md](05-SCAFFOLDING.md) | `smoke.py`, `provision.sh`, `deploy.sh`, `run.sh` |

## Recommended reading order

Pick a path based on what you already know:

- **No Python, no Qt, no OpenGL**: 01 → 02 → 03 → 04 → 05.
- **Comfortable with Python**: 02 → 03 → 04 (skim 01 for refresh).
- **Know Python and Qt**: 03 → 04.
- **Know all three**: 04 directly, with 05 for context.

The walkthrough (04) is the document that ties everything together. The first
three are reference primers it will refer back to.

## High-level architecture in one diagram

```text
                    ┌─────────────────────────────────────────────┐
                    │              demos/accelerometer/app_accel.py     │
                    │                                             │
   /sys/bus/iio →   │  ImuReader ───► QTimer (50 Hz) ──┐          │
   (kernel-side     │                                  │          │
    MPU6050 data)   │                                  ▼          │
                    │                          AxisScene          │
                    │                       (QOpenGLWidget)       │
                    │                                  │          │
                    │   ┌──────────────────────────────┤          │
                    │   ▼                              ▼          │
                    │  paintGL                     _draw_overlay  │
                    │  (raw OpenGL ES via         (QPainter 2D    │
                    │   PyOpenGL):                 text overlay:  │
                    │   - axis lines               HUD + tick     │
                    │   - arrowhead cones           labels +      │
                    │   - gyro arcs                 X/Y/Z border  │
                    │   - faint grid lines)         letters)      │
                    │                                             │
                    └──────────────┬──────────────────────────────┘
                                   │
                            HDMI (Wayland)
                                   │
                                   ▼
                          ┌────────────────┐
                          │ JRP 1024×600   │
                          │ HDMI panel     │
                          └────────────────┘
```

## File map at a glance

| File | Role | When you'd touch it |
|---|---|---|
| [app_accel.py](../app_accel.py) | The actual demo | Adding visuals, changing geometry, tuning behavior |
| [smoke.py](../smoke.py) | Minimal "is the GUI alive?" test | Diagnosing a broken environment |
| [provision.sh](../provision.sh) | Board prerequisite installer | Adding a new package the demo depends on |
| [deploy.sh](../deploy.sh) | Host → board file sync | Almost never (works as-is) |
| [run.sh](../run.sh) | Board-side launcher with env vars | Adding new env vars or flags |
| [PROVISION.md](../PROVISION.md) | Doc that tracks board changes | Whenever `provision.sh` changes |
| [axis-display.png](../axis-display.png) | Reference image for the design | Never (just reference) |

## Glossary of terms (linked from the other docs)

- **App** — the running Python program (`app_accel.py` invoked via Python).
- **Widget** — a Qt UI element (a window, a button, a 3D canvas, …).
- **Event loop** — the loop inside Qt that waits for and dispatches events
  (key presses, timer ticks, repaint requests).
- **Slot** — a function Qt calls when a signal fires (e.g. our `_on_sample`
  is the slot for the timer's `timeout` signal).
- **Shader** — a small program that runs on the GPU. We use two: a *vertex
  shader* (runs once per vertex) and a *fragment shader* (runs once per pixel).
- **VBO** (Vertex Buffer Object) — a chunk of GPU memory holding vertex data.
- **VAO** (Vertex Array Object) — Qt-equivalent of "the recipe for how to
  read a VBO" stored on the GPU.
- **MVP matrix** — the combined Model × View × Projection matrix that maps
  3D world coordinates to 2D screen-space.
- **HUD** — heads-up display: the text overlay drawn on top of the 3D scene.
- **IIO** — Linux's Industrial I/O subsystem; how the kernel exposes the
  MPU6050 to userspace.

## How to run the code (as a recap)

The demo lives on the EAIE board at `~/demos/accelerometer/`. After a reflash:

1. From the dev host, run `bash demos/accelerometer/provision.sh` (or via SSH;
   see [PROVISION.md](../PROVISION.md)) to install board prerequisites and
   drop the desktop shortcut into `~/Desktop/`.
2. From the dev host, run `bash demos/accelerometer/deploy.sh` to copy the
   demo files to the board.
3. Launch the demo: either double-click "EAIE Accelerometer Demo" on the
   LXQt desktop, or SSH/serial in and run `~/demos/accelerometer/app_accel.py`
   directly.
4. To exit: press **ESC**, click the **Exit** button in the top-right
   corner, or `Ctrl+C` in the launching terminal.

Edit-on-host → `deploy.sh` → re-run on board is the development loop.
