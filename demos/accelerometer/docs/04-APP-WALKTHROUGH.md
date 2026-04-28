# 04 — `app_accel.py` Function-by-Function Walkthrough

This is the main reference document. Every meaningful section of
[app_accel.py](../app_accel.py) is covered, in source order. For each, you get:

- The relevant code excerpt
- What it does (short)
- Step-by-step explanation when needed
- Why it's done this way (design notes)
- Pointers to the concept primers when a topic needs more background

Section IDs match the line numbers as of the latest version of `app_accel.py`.

---

## 0. The shebang and module docstring (lines 1–2)

```python
#!/usr/bin/env python3
"""EAIE accelerometer-axis app — static 3D tripod, fullscreen ES3, ESC to exit."""
```

The `#!` line lets the file be run directly as `./app_accel.py` (the OS will look
up `python3` via `env` and feed the file to it). The docstring is what
`help(app)` would show.

---

## 1. Process-level setup (lines 4–17)

```python
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)

if "QT_QPA_PLATFORM" not in os.environ:
    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    if os.path.exists(f"{os.environ['XDG_RUNTIME_DIR']}/wayland-0"):
        os.environ.setdefault("WAYLAND_DISPLAY", "wayland-0")
        os.environ["QT_QPA_PLATFORM"] = "wayland"
```

### What it does

1. Restore Ctrl+C to its kernel-default behavior (terminate the process).
2. If we're launched from a non-graphical shell (TTY, serial console, plain
   SSH), auto-discover the LXQt Wayland session env vars and set them so Qt
   can find the compositor.

### Why

**Ctrl+C fix**: Python's default SIGINT handler converts SIGINT into a
`KeyboardInterrupt` exception, but only when Python bytecode is executing.
While `app.exec()` is running (Qt's event loop in C++), Python doesn't
execute any bytecode, so the signal sits in limbo. Setting the disposition
to `SIG_DFL` means the kernel terminates immediately on Ctrl+C.

**Env discovery**: When you log in via SSH or a serial console, your shell
has its own environment, separate from the LXQt Wayland session. Without
`WAYLAND_DISPLAY` and `QT_QPA_PLATFORM=wayland`, Qt falls back to its default
platform plugin (`xcb`, i.e. X11), which can't connect to anything. The
auto-discovery looks for `wayland-0` in the user's runtime directory and
points Qt at it.

### Order matters

This block runs **before** PySide6 is imported. Qt reads
`QT_QPA_PLATFORM` once at import time; setting it after the import would be
too late.

### See also

- [01-PYTHON-CONCEPTS.md §1](01-PYTHON-CONCEPTS.md#1-modules-imports-and-module-level-code) — module-level execution order
- [02-PYSIDE6-CONCEPTS.md §8](02-PYSIDE6-CONCEPTS.md#8-qsurfaceformat--configuring-the-gl-context) — Qt platform plugins

---

## 2. Third-party imports (lines 19–88)

```python
import ctypes
import math

import numpy as np

from OpenGL.GL import (
    GL_ALIASED_LINE_WIDTH_RANGE, ... ,
    glDrawArrays, ... , glViewport,
)
from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QColor, QFont, QPainter, QSurfaceFormat
from PySide6.QtOpenGLWidgets import QOpenGLWidget
from PySide6.QtWidgets import QApplication
```

### What it does

Pulls in the third-party libraries we use:

- `ctypes` — only for `ctypes.c_void_p(offset)` when calling
  `glVertexAttribPointer`.
- `math` — `math.pi`, `math.cos`, `math.sin`.
- `numpy as np` — array math, vector ops, matrix multiplication.
- `OpenGL.GL` — PyOpenGL bindings for raw OpenGL ES function calls.
- `PySide6.QtCore` — `Qt` enum namespace, `QTimer`, `QRect` (used for the Exit button's hit rectangle).
- `PySide6.QtGui` — drawing primitives (`QColor`, `QFont`, `QPainter`,
  `QSurfaceFormat`).
- `PySide6.QtOpenGLWidgets` — `QOpenGLWidget`, our 3D canvas widget.
- `PySide6.QtWidgets` — `QApplication`.

### Design note: why **not** `PySide6.QtOpenGL`

You might expect to use `QOpenGLBuffer`, `QOpenGLShaderProgram`, etc. from
`PySide6.QtOpenGL`. We don't — that module's binary references desktop-GL
helper classes (`QOpenGLFunctions_4_0_Core`) that Bianbu's ES-only Qt build
doesn't export. The whole module fails to load. We use PyOpenGL for all GL
calls instead.

`QOpenGLWidget` itself lives in `QtOpenGLWidgets` (a separate module with a
lighter symbol footprint) and loads fine.

### See also

- [03-OPENGL-CONCEPTS.md §2](03-OPENGL-CONCEPTS.md#2-opengl-es-30-vs-desktop-opengl) — why PyOpenGL not PySide6.QtOpenGL

---

## 3. Vertex and fragment shader sources (lines 90–116)

```python
VERTEX_SHADER = """#version 300 es
precision highp float;
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec4 a_color;
layout(location = 2) in float a_axis;
uniform mat4 u_mvp;
uniform vec3 u_g;
out vec4 v_color;
void main() {
    vec3 pos = a_pos;
    int idx = int(a_axis);
    if (idx == 0) pos.x *= u_g.x;
    else if (idx == 1) pos.y *= u_g.y;
    else if (idx == 2) pos.z *= u_g.z;
    v_color = a_color;
    gl_Position = u_mvp * vec4(pos, 1.0);
}
"""

FRAGMENT_SHADER = """#version 300 es
precision mediump float;
in vec4 v_color;
out vec4 fragColor;
void main() {
    fragColor = v_color;
}
"""
```

### What they do

These are GLSL ES 3.00 source strings. They're text now; later, we compile
them on the GPU when `initializeGL` runs.

**Vertex shader** — runs once per vertex. It does two things:

1. Optionally scales the vertex position by a per-axis G value (so the X
   arrow's vertices stretch with `u_g.x`, etc.).
2. Multiplies by the MVP matrix to produce clip-space position.

The conditional scaling is the trick that lets us use one VBO for both the
static geometry (planes, grid; tagged with `a_axis = -1`) and the dynamic
G-driven axes (tagged 0/1/2).

**Fragment shader** — runs once per pixel. It just emits the interpolated
color from the vertex shader. No lighting, no textures.

### Design note: why include axis_idx as a vertex attribute?

Two cleaner-looking alternatives we *could* have used:

- **Three separate draw calls** with three model matrices, one per axis. More
  GL state changes per frame.
- **Re-upload vertex data every frame** with the G-scaling baked into
  positions. Simple but wasteful CPU/bandwidth for unchanging geometry.

The "axis_idx attribute + uniform u_g" approach keeps everything in one VBO
and one draw call per primitive type, with the GPU doing the per-vertex
multiply for free.

### See also

- [03-OPENGL-CONCEPTS.md §8](03-OPENGL-CONCEPTS.md#8-shaders--glsl-es-300-in-5-minutes) — GLSL syntax
- [03-OPENGL-CONCEPTS.md §7](03-OPENGL-CONCEPTS.md#7-uniforms-vs-attributes) — uniforms vs attributes

---

## 4. Geometry constants (lines 118–138)

```python
AXIS_LEN = 1.0
LINE_WIDTH_PX = 7.5
ARROW_HEIGHT = 0.13
ARROW_RADIUS = 0.05
ARROW_SEGMENTS = 16
LINE_END = AXIS_LEN - ARROW_HEIGHT

GRID_HALF = 2.0   # grid and tick labels extend ±2G in each axis
GRID_STEP = 0.5   # one grid line and one tick label every 0.5G
GRID_LINE_WIDTH_PX = 1.0
GRID_COLOR = (0.75, 0.75, 0.80, 0.12)  # very faint cool-white

GYRO_RADIUS = 0.15
GYRO_OMEGA_MAX_DPS = 200.0
GYRO_ARC_MAX_RAD = math.pi * 1.5  # max sweep = 270°
GYRO_ARC_SEGMENTS_MAX = 64
GYRO_LINE_WIDTH_PX = 5.0

COLOR_X = (1.00, 0.30, 0.30, 1.00)
COLOR_Y = (0.30, 0.90, 0.40, 1.00)
COLOR_Z = (0.45, 0.65, 1.00, 1.00)
```

### What they are

Tunable visual parameters in **world units**, except `*_PX` and `*_DPS` which
are pixel sizes / degrees-per-second. World units = G — 1 unit equals 1G.

| Constant | Meaning |
|---|---|
| `AXIS_LEN` | Length of a colored arrow at 1G (in world units) |
| `LINE_WIDTH_PX` | Pixel width of axis lines |
| `ARROW_HEIGHT`, `ARROW_RADIUS` | Cone tip dimensions |
| `LINE_END` | Where the line stops and the cone begins (= AXIS_LEN − ARROW_HEIGHT) |
| `GRID_HALF` | Grid extends from −GRID_HALF to +GRID_HALF (±2G) |
| `GRID_STEP` | Spacing between grid lines and tick labels (0.5G) |
| `GRID_COLOR` | RGBA, alpha = 0.12 = very faint |
| `GYRO_RADIUS` | Distance from each axis where gyro arcs orbit |
| `GYRO_OMEGA_MAX_DPS` | Angular velocity that maps to a 270° arc |
| `GYRO_ARC_MAX_RAD` | Max arc sweep in radians |
| `GYRO_ARC_SEGMENTS_MAX` | Max line segments per arc (smoothness) |
| `COLOR_X/Y/Z` | RGBA tuples for axis colors (alpha=1.0) |

### Tuning these

Almost every visual question (axis size, arrow proportions, color saturation,
grid density, plane alpha, gyro sensitivity) is one constant change. Designed
that way deliberately for fast iteration.

---

## 5. `AXIS_LINE_VERTICES` (lines 140–152)

```python
# Three line segments: origin → tip-of-line on each axis. Z is up.
# Each vertex carries an axis index (0/1/2 = scale by u_g.x/y/z; -1 = static).
AXIS_LINE_VERTICES = np.array(
    [
        0.0, 0.0, 0.0,        *COLOR_X, 0.0,
        LINE_END, 0.0, 0.0,   *COLOR_X, 0.0,
        0.0, 0.0, 0.0,        *COLOR_Y, 1.0,
        0.0, LINE_END, 0.0,   *COLOR_Y, 1.0,
        0.0, 0.0, 0.0,        *COLOR_Z, 2.0,
        0.0, 0.0, LINE_END,   *COLOR_Z, 2.0,
    ],
    dtype=np.float32,
)
```

### What it is

Six vertices, eight floats each = 48 floats total. Six vertices = three
line segments (each line is a pair of vertices: start and end).

| Vertex | x, y, z | r, g, b, a | axis_idx |
|---|---|---|---|
| 1 | 0, 0, 0 | red | 0 (X) |
| 2 | LINE_END, 0, 0 | red | 0 (X) |
| 3 | 0, 0, 0 | green | 1 (Y) |
| 4 | 0, LINE_END, 0 | green | 1 (Y) |
| 5 | 0, 0, 0 | blue | 2 (Z) |
| 6 | 0, 0, LINE_END | blue | 2 (Z) |

`*COLOR_X` expands the 4-tuple inline, so each vertex row really is 8 floats.

### Why `LINE_END`, not `AXIS_LEN`

Each axis line goes from the origin to **just shy of** the full length —
specifically `AXIS_LEN - ARROW_HEIGHT`. The arrowhead cone fills the gap
from `LINE_END` to `AXIS_LEN`. So the visible total "arrow" length is
exactly `AXIS_LEN`, with the line covering most of it and the cone covering
the tip.

### See also

- [01-PYTHON-CONCEPTS.md §4](01-PYTHON-CONCEPTS.md#4-tuples-and-tuple-unpacking) — star unpacking
- [03-OPENGL-CONCEPTS.md §5](03-OPENGL-CONCEPTS.md#5-vbos-and-vertex-attributes) — vertex layout

---

## 6. `_cone_vertices` (lines 155–182)

```python
def _cone_vertices(
    base_center: np.ndarray,
    direction: np.ndarray,
    height: float,
    radius: float,
    color: tuple[float, float, float, float],
    axis_idx: float,
    segments: int = ARROW_SEGMENTS,
) -> np.ndarray:
    """Closed cone as interleaved (xyz, rgba, axis_idx) triangle vertices."""
    base_center = np.asarray(base_center, dtype=np.float32)
    direction = np.asarray(direction, dtype=np.float32)
    ref = np.array([0.0, 0.0, 1.0], dtype=np.float32) if abs(direction[2]) < 0.9 \
        else np.array([1.0, 0.0, 0.0], dtype=np.float32)
    u = np.cross(direction, ref); u /= np.linalg.norm(u)
    v = np.cross(direction, u);   v /= np.linalg.norm(v)
    tip = base_center + direction * height
    angles = np.linspace(0.0, 2.0 * np.pi, segments, endpoint=False)
    rim = [base_center + radius * (np.cos(a) * u + np.sin(a) * v) for a in angles]

    a = axis_idx
    out: list[float] = []
    for i in range(segments):
        j = (i + 1) % segments
        out.extend([*tip, *color, a, *rim[i], *color, a, *rim[j], *color, a])
        out.extend([*base_center, *color, a, *rim[j], *color, a, *rim[i], *color, a])
    return np.array(out, dtype=np.float32)
```

### What it does

Generates triangle vertices for one closed cone (an arrowhead): a
`segments`-sided pyramid. Returns a flat NumPy array of vertices, each
8 floats wide.

For `segments=16`: 16 side triangles + 16 base triangles = 32 triangles =
**96 vertices** = 768 floats.

### Step by step

```python
base_center = np.asarray(...)
direction = np.asarray(...)
```

Coerce inputs to float32 NumPy arrays.

```python
ref = ... [0,0,1] if abs(direction[2]) < 0.9 else [1,0,0]
u = np.cross(direction, ref); u /= np.linalg.norm(u)
v = np.cross(direction, u);   v /= np.linalg.norm(v)
```

Build a 2D basis (`u`, `v`) perpendicular to `direction`. These two unit
vectors will be used to walk around the cone's circular base.

The `ref` selection avoids picking a reference vector parallel to
`direction` (which would make the cross product zero). If `direction` is
mostly along Z, use X as reference; otherwise use Z.

```python
tip = base_center + direction * height
```

Tip of the cone, `height` units along the direction vector.

```python
angles = np.linspace(0.0, 2.0 * np.pi, segments, endpoint=False)
rim = [base_center + radius * (np.cos(a) * u + np.sin(a) * v) for a in angles]
```

`segments` evenly-spaced points around the circle perpendicular to the cone's
axis. `endpoint=False` because we don't want the start and end to coincide
(angle 0 and angle 2π are the same point).

```python
for i in range(segments):
    j = (i + 1) % segments
    out.extend([*tip, *color, a, *rim[i], *color, a, *rim[j], *color, a])
    out.extend([*base_center, *color, a, *rim[j], *color, a, *rim[i], *color, a])
```

For each segment around the circle, emit two triangles:

- **Side triangle**: tip + adjacent rim points.
- **Base triangle**: base center + adjacent rim points (in reverse order so
  its normal points back away from the tip — but we don't enable culling
  anyway, so the order is for principle, not correctness).

`(i + 1) % segments` makes the last segment wrap around: vertex 15 connects
back to vertex 0.

### Design notes

- Each vertex carries the same `axis_idx` (passed in by the caller). The
  whole cone scales as one unit when its axis's G value changes.
- Color is also per-vertex but identical across all vertices of one cone.
- `np.linspace` gives floats between 0 and 2π; `np.cos(a)` and `np.sin(a)`
  give the in-plane direction at each step.

### See also

- [03-OPENGL-CONCEPTS.md §9](03-OPENGL-CONCEPTS.md#9-primitive-types) — `GL_TRIANGLES`

---

## 7. `ARROW_VERTICES` (lines 185–200)

```python
ARROW_VERTICES = np.concatenate(
    [
        _cone_vertices(
            np.array([LINE_END, 0.0, 0.0]), np.array([1.0, 0.0, 0.0]),
            ARROW_HEIGHT, ARROW_RADIUS, COLOR_X, 0.0,
        ),
        _cone_vertices(
            np.array([0.0, LINE_END, 0.0]), np.array([0.0, 1.0, 0.0]),
            ARROW_HEIGHT, ARROW_RADIUS, COLOR_Y, 1.0,
        ),
        _cone_vertices(
            np.array([0.0, 0.0, LINE_END]), np.array([0.0, 0.0, 1.0]),
            ARROW_HEIGHT, ARROW_RADIUS, COLOR_Z, 2.0,
        ),
    ]
)
```

### What it is

Three cones — one per axis — concatenated into a single NumPy array. Each is
positioned at the line's endpoint, points along the axis, in that axis's
color, tagged with the appropriate axis_idx (so each cone scales with its
own G uniform).

### Result

3 cones × 96 vertices = **288 vertices** = 2304 floats.

---

## 8. `_grid_lines_in_plane` (lines 203–225)

```python
def _grid_lines_in_plane(
    axis_a: int,
    axis_b: int,
    color: tuple[float, float, float, float],
    half: float = GRID_HALF,
    step: float = GRID_STEP,
    axis_idx: float = -1.0,
) -> list[float]:
    """Lines of an axis-aligned grid in the plane spanned by axis_a and axis_b."""
    a = axis_idx
    out: list[float] = []
    n_steps = int(round(2.0 * half / step)) + 1
    for i in range(n_steps):
        t = -half + i * step
        # Line parallel to axis_b at axis_a = t.
        v0 = [0.0, 0.0, 0.0]; v0[axis_a] = t; v0[axis_b] = -half
        v1 = [0.0, 0.0, 0.0]; v1[axis_a] = t; v1[axis_b] = +half
        out.extend([*v0, *color, a, *v1, *color, a])
        # Line parallel to axis_a at axis_b = t.
        v0 = [0.0, 0.0, 0.0]; v0[axis_b] = t; v0[axis_a] = -half
        v1 = [0.0, 0.0, 0.0]; v1[axis_b] = t; v1[axis_a] = +half
        out.extend([*v0, *color, a, *v1, *color, a])
    return out
```

### What it does

Produces line segments for a square grid in one of the three coordinate
planes. `axis_a` and `axis_b` are integers `0`/`1`/`2` for X/Y/Z respectively;
the third axis (perpendicular to the plane) is implicitly zero.

### Step by step

For `_grid_lines_in_plane(0, 1)` (XY plane), with `half=2.0` and `step=0.5`:

- `n_steps = round(2 * 2 / 0.5) + 1 = 9` — nine lines along each direction.
- For each `t` in `[-2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2]`:
  - One line parallel to Y at X=t — goes from `(t, -2, 0)` to `(t, +2, 0)`.
  - One line parallel to X at Y=t — goes from `(-2, t, 0)` to `(+2, t, 0)`.

That's 9 + 9 = 18 lines per plane, 36 vertices per plane.

### Why `v0 = [0, 0, 0]; v0[axis_a] = t; v0[axis_b] = -half`

This is a clean way to set two coordinates of a 3-vector while leaving the
third at zero. The "third" coordinate is determined implicitly: it's the one
that's neither `axis_a` nor `axis_b`, and we leave its `0.0` initial value
alone.

For the YZ plane (`axis_a=1, axis_b=2`), the X coordinate stays zero. For the
XZ plane (`axis_a=0, axis_b=2`), the Y stays zero.

---

## 9. `GRID_VERTICES` (lines 228–233)

```python
GRID_VERTICES = np.array(
    _grid_lines_in_plane(0, 1, GRID_COLOR)    # XY plane (Z = 0)
    + _grid_lines_in_plane(1, 2, GRID_COLOR)  # YZ plane (X = 0)
    + _grid_lines_in_plane(0, 2, GRID_COLOR), # XZ plane (Y = 0)
    dtype=np.float32,
)
```

### What it is

All grid lines for all three planes, concatenated. 3 planes × 36 vertices =
**108 vertices** = 864 floats.

`+` here concatenates Python lists (`_grid_lines_in_plane` returns a
`list[float]`, not a NumPy array — that's a deliberate choice, since it's
easier to build with `.extend(...)`). Then `np.array(...)` converts the final
flat list to a NumPy float32 array.

---

## 10. `ALL_VERTICES` and offsets/strides (lines 235–248)

```python
ALL_VERTICES = np.concatenate([AXIS_LINE_VERTICES, ARROW_VERTICES, GRID_VERTICES])
LINE_VERT_COUNT = len(AXIS_LINE_VERTICES) // 8
ARROW_VERT_COUNT = len(ARROW_VERTICES) // 8
GRID_VERT_COUNT = len(GRID_VERTICES) // 8

VERTEX_STRIDE = 8 * ALL_VERTICES.itemsize
COLOR_OFFSET = 3 * ALL_VERTICES.itemsize
AXIS_OFFSET = 7 * ALL_VERTICES.itemsize

# Reserved region at the end of the VBO for gyro arcs (regenerated per frame).
GYRO_MAX_VERTS = 3 * GYRO_ARC_SEGMENTS_MAX * 2
GYRO_RESERVE_BYTES = GYRO_MAX_VERTS * VERTEX_STRIDE
GYRO_OFFSET_VERTS = LINE_VERT_COUNT + ARROW_VERT_COUNT + GRID_VERT_COUNT
GYRO_OFFSET_BYTES = ALL_VERTICES.nbytes
```

### What it does

Combines all static geometry into one big NumPy array, computes vertex
counts (`// 8` because each vertex is 8 floats), and works out the byte
offsets/strides for `glVertexAttribPointer`.

### Layout

```
ALL_VERTICES =  AXIS_LINE_VERTICES   |  ARROW_VERTICES   |  GRID_VERTICES
                  (6 verts)             (288 verts)         (108 verts)

Vertex format: [x, y, z, r, g, b, a, axis_idx]  — 8 floats × 4 bytes = 32 bytes/vertex

Offsets within each vertex:
  position:  0  bytes
  color:    12  bytes  (= 3 floats × 4 bytes)
  axis_idx: 28  bytes  (= 7 floats × 4 bytes)
  total:    32  bytes  (= VERTEX_STRIDE)
```

### Gyro reservation

The VBO will hold the static geometry above *plus* extra empty bytes at the
end for gyro arcs. The arcs vary in length each frame as ω changes, so they
can't be baked in at startup — they're streamed via `glBufferSubData` later.

`GYRO_MAX_VERTS = 3 × 64 × 2 = 384` — three axes, up to 64 segments per arc,
2 vertices per segment (a line segment).

`GYRO_OFFSET_VERTS = 6 + 288 + 108 = 402` — the gyro region starts at this
vertex index.

`GYRO_OFFSET_BYTES = ALL_VERTICES.nbytes` — same offset in bytes (the static
region's total byte size).

---

## 11. `_gyro_arc_vertices` (lines 251–277)

```python
def _gyro_arc_vertices(
    axis: int,
    omega_dps: float,
    color: tuple[float, float, float, float],
) -> list[float]:
    """Line vertices for one gyro arc curling around axis at distance 1.0 from origin."""
    omega_norm = max(-1.0, min(1.0, omega_dps / GYRO_OMEGA_MAX_DPS))
    arc_rad = omega_norm * GYRO_ARC_MAX_RAD
    n_segs = max(1, int(GYRO_ARC_SEGMENTS_MAX * abs(omega_norm)))

    if axis == 0:
        center = np.array([1.0, 0.0, 0.0]); u = np.array([0.0, 1.0, 0.0]); v = np.array([0.0, 0.0, 1.0])
    elif axis == 1:
        center = np.array([0.0, 1.0, 0.0]); u = np.array([0.0, 0.0, 1.0]); v = np.array([1.0, 0.0, 0.0])
    else:
        center = np.array([0.0, 0.0, 1.0]); u = np.array([1.0, 0.0, 0.0]); v = np.array([0.0, 1.0, 0.0])

    angles = np.linspace(0.0, arc_rad, n_segs + 1)
    pts = [center + GYRO_RADIUS * (math.cos(a) * u + math.sin(a) * v) for a in angles]

    out: list[float] = []
    for i in range(n_segs):
        out.extend([*pts[i], *color, -1.0])
        out.extend([*pts[i + 1], *color, -1.0])
    return out
```

### What it does

Builds a partial-circle arc curling around one axis at a distance of 1.0
from the origin. The arc's angular span is proportional to ω, capped at
±270° at ω = ±200 dps.

### Step by step

```python
omega_norm = max(-1.0, min(1.0, omega_dps / GYRO_OMEGA_MAX_DPS))
```

Map ω from "deg/s" to "fraction of max" (clamped to [-1, +1]).

```python
arc_rad = omega_norm * GYRO_ARC_MAX_RAD
```

Convert that fraction to actual radians of sweep. Sign preserved: positive
ω → positive sweep (CCW); negative → CW.

```python
n_segs = max(1, int(GYRO_ARC_SEGMENTS_MAX * abs(omega_norm)))
```

Number of line segments for this arc, proportional to its length. At
saturation (|ω_norm|=1.0), 64 segments. At small ω, very few segments.
`max(1, ...)` ensures we don't try to draw zero segments.

### The `(center, u, v)` basis selection

For each axis, we pick:

- `center` — the static 1G point on the axis where the arc orbits.
- `u`, `v` — two unit vectors spanning the plane perpendicular to the axis.

The choice of `u, v` is deliberate: positive ω about the axis sweeps from
`+u` toward `+v` (CCW when viewed from +axis), matching the right-hand rule.

For X axis: arc lies in YZ plane, sweeps from +Y to +Z to -Y to -Z. ✓

### Vertex emission

```python
angles = np.linspace(0.0, arc_rad, n_segs + 1)
pts = [center + GYRO_RADIUS * (math.cos(a) * u + math.sin(a) * v) for a in angles]

for i in range(n_segs):
    out.extend([*pts[i], *color, -1.0])
    out.extend([*pts[i + 1], *color, -1.0])
```

`linspace` gives `n_segs + 1` angle values (one per arc endpoint, the rest
are the segment joins). `pts` has the same length. We emit `n_segs` line
segments, each as two consecutive vertices.

`axis_idx = -1.0` so the vertex shader doesn't scale these by `u_g` — the
arc is a static reference to the 1G point, not something the G value should
deform.

### See also

- [03-OPENGL-CONCEPTS.md §14](03-OPENGL-CONCEPTS.md#14-streaming-dynamic-geometry--glbuffersubdata) — streaming with glBufferSubData

---

## 12. Sensor and runtime constants (lines 279–285)

```python
BG_COLOR = (0.06, 0.07, 0.10, 1.0)

G_MS2 = 9.80665
RAD_TO_DEG = 180.0 / math.pi
SYSFS_IIO = "/sys/bus/iio/devices/iio:device1"
SAMPLE_PERIOD_MS = 20  # 50 Hz
PRINT_EVERY_N = 1      # 1 = print every sample = 50 Hz console rate
```

`G_MS2` is standard gravity in m/s². Used to convert raw IIO accel readings
(in m/s²) to G.

`SAMPLE_PERIOD_MS = 20` makes the QTimer fire every 20 ms, i.e. 50 Hz.

`PRINT_EVERY_N` is a console-spam knob — set to N to print every Nth sample.

---

## 13. `_read_float` and `ImuReader` (lines 288–318)

```python
def _read_float(path: str) -> float:
    with open(path) as f:
        return float(f.read().strip())


class ImuReader:
    """Read MPU6050 accel (G) + gyro (deg/s) from IIO sysfs."""

    def __init__(self, sysfs_dir: str = SYSFS_IIO) -> None:
        self._accel_paths = tuple(
            f"{sysfs_dir}/in_accel_{ax}_raw" for ax in ("x", "y", "z")
        )
        self._gyro_paths = tuple(
            f"{sysfs_dir}/in_anglvel_{ax}_raw" for ax in ("x", "y", "z")
        )
        self._accel_scale = _read_float(f"{sysfs_dir}/in_accel_scale")
        self._gyro_scale = _read_float(f"{sysfs_dir}/in_anglvel_scale")
        print(f"accel scale: {self._accel_scale:.6e} m/s²/LSB")
        print(f"gyro scale:  {self._gyro_scale:.6e} rad/s/LSB  (path={sysfs_dir})")

    def read_g(self) -> tuple[float, float, float]:
        gx, gy, gz = (
            _read_float(p) * self._accel_scale / G_MS2 for p in self._accel_paths
        )
        return gx, gy, gz

    def read_gyro_dps(self) -> tuple[float, float, float]:
        wx, wy, wz = (
            _read_float(p) * self._gyro_scale * RAD_TO_DEG for p in self._gyro_paths
        )
        return wx, wy, wz
```

### What it is

The thin wrapper that reads IMU values from IIO sysfs and converts them to
human-friendly units.

### `__init__`

Builds the three accel and three gyro path strings, reads the *scale*
attributes once (those don't change between samples), prints them for
diagnostics.

The scale values are in:

- `in_accel_scale`: m/s² per LSB (raw integer count)
- `in_anglvel_scale`: rad/s per LSB

### `read_g` and `read_gyro_dps`

Each opens three files, reads a raw integer, multiplies by the scale, and in
the case of accel divides by `G_MS2` to convert m/s² → G; for gyro
multiplies by `RAD_TO_DEG` to convert rad/s → deg/s.

The generator-expression-into-tuple form:

```python
gx, gy, gz = (
    _read_float(p) * self._accel_scale / G_MS2 for p in self._accel_paths
)
```

is a compact way to read three files and unpack into three names without
building a list.

### Performance note

Each `read_g()` opens three sysfs files; each `read_gyro_dps()` opens three
more. Six file opens per timer firing × 50 Hz = 300 syscalls/second. The
underlying I2C transactions to the MPU6050 take ~1 ms each. Total per
timer: ~6 ms of work. Comfortably within the 20 ms budget.

If/when we go past ~100 Hz, this approach will start to bottleneck and we'll
switch to the IIO buffer chardev (a single `read()` returns a struct with all
six values atomically, and the kernel paces it via the chip's data-ready
interrupt). That's a planned future change.

### See also

- [01-PYTHON-CONCEPTS.md §8](01-PYTHON-CONCEPTS.md#8-file-io) — `with open(...)`
- [01-PYTHON-CONCEPTS.md §7](01-PYTHON-CONCEPTS.md#7-classes--the-bare-minimum) — class basics

---

## 14. Shader compilation helpers (lines 321–340)

```python
def _compile_shader(kind: int, source: str) -> int:
    sid = glCreateShader(kind)
    glShaderSource(sid, source)
    glCompileShader(sid)
    if not glGetShaderiv(sid, GL_COMPILE_STATUS):
        log = glGetShaderInfoLog(sid).decode()
        glDeleteShader(sid)
        raise RuntimeError(f"shader compile failed: {log}")
    return sid


def _link_program(vs: int, fs: int) -> int:
    pid = glCreateProgram()
    glAttachShader(pid, vs)
    glAttachShader(pid, fs)
    glLinkProgram(pid)
    if not glGetProgramiv(pid, GL_LINK_STATUS):
        log = glGetProgramInfoLog(pid).decode()
        raise RuntimeError(f"program link failed: {log}")
    return pid
```

### What they do

Standard GLSL compile/link cycle, with error checking that turns GL failures
into Python exceptions.

`_compile_shader(kind, source)` takes either `GL_VERTEX_SHADER` or
`GL_FRAGMENT_SHADER` and a source string. Returns the shader ID on success;
raises `RuntimeError` on failure with the driver's error log.

`_link_program(vs, fs)` takes two shader IDs and links them into a program.
Returns the program ID on success; raises on failure.

These are called once each in `initializeGL`, then the shader IDs can be
deleted (the program holds references).

### See also

- [03-OPENGL-CONCEPTS.md §8](03-OPENGL-CONCEPTS.md#8-shaders--glsl-es-300-in-5-minutes) — compile/link cycle

---

## 15. Math helpers — `_perspective` and `_look_at` (lines 343–370)

```python
def _perspective(fov_deg: float, aspect: float, near: float, far: float) -> np.ndarray:
    f = 1.0 / np.tan(np.radians(fov_deg) / 2.0)
    return np.array(
        [
            [f / aspect, 0.0, 0.0,                            0.0],
            [0.0,        f,   0.0,                            0.0],
            [0.0,        0.0, (far + near) / (near - far),    (2.0 * far * near) / (near - far)],
            [0.0,        0.0, -1.0,                           0.0],
        ],
        dtype=np.float32,
    )


def _look_at(eye: np.ndarray, target: np.ndarray, up: np.ndarray) -> np.ndarray:
    f = target - eye
    f /= np.linalg.norm(f)
    s = np.cross(f, up)
    s /= np.linalg.norm(s)
    u = np.cross(s, f)
    return np.array(
        [
            [ s[0],  s[1],  s[2], -np.dot(s, eye)],
            [ u[0],  u[1],  u[2], -np.dot(u, eye)],
            [-f[0], -f[1], -f[2],  np.dot(f, eye)],
            [ 0.0,   0.0,   0.0,   1.0],
        ],
        dtype=np.float32,
    )
```

### What they are

`_perspective` builds a 4×4 perspective projection matrix.
`_look_at` builds a 4×4 view (camera) matrix from eye/target/up vectors.

Both are direct implementations of the standard OpenGL formulas. You don't
need to memorize them.

### Inputs

`_perspective`:

- `fov_deg` — vertical field of view in degrees
- `aspect` — width/height of the viewport
- `near`, `far` — distances of the near and far clipping planes

`_look_at`:

- `eye` — camera position (world space)
- `target` — what the camera is looking at
- `up` — direction that should be "up" in the resulting image (we use
  `(0, 0, 1)` because we use Z-up convention)

The result of both is a row-major NumPy 4×4 — which we'll need to flag as
transposed when uploading (see paintGL).

### See also

- [03-OPENGL-CONCEPTS.md §3](03-OPENGL-CONCEPTS.md#3-coordinate-spaces) — coordinate spaces
- [03-OPENGL-CONCEPTS.md §4](03-OPENGL-CONCEPTS.md#4-the-mvp-matrix) — MVP matrix and column-major convention

---

## 16. `AxisScene.__init__` (lines 373–392)

```python
class AxisScene(QOpenGLWidget):
    def __init__(self):
        super().__init__()
        self._program = 0
        self._vao = 0
        self._vbo = 0
        self._mvp_loc = -1
        self._proj = np.eye(4, dtype=np.float32)
        self._view = np.eye(4, dtype=np.float32)
        self._model = np.eye(4, dtype=np.float32)
        self._mvp_cache = np.eye(4, dtype=np.float32)

        self._reader = ImuReader()
        self._sample_count = 0
        self._read_errors = 0
        self._last_g = (0.0, 0.0, 0.0)
        self._last_gyro_dps = (0.0, 0.0, 0.0)
        self._exit_button_rect = QRect()
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._on_sample)
        self._timer.start(SAMPLE_PERIOD_MS)
```

### What it does

Constructs the widget and initializes its state. **No GL calls happen here**
— the GL context isn't ready yet. GL setup is deferred to `initializeGL`.

### State variables

- `_program`, `_vao`, `_vbo` — GL object IDs (0 = "not yet allocated")
- `_mvp_loc`, `_g_loc` — uniform locations (set in initializeGL)
- `_proj`, `_view`, `_model` — the three matrices that combine into MVP
- `_mvp_cache` — last computed MVP, used by `_world_to_screen` for projecting
  3D positions to 2D screen coords for the QPainter overlay
- `_reader` — `ImuReader` instance, opens sysfs paths
- `_sample_count`, `_read_errors` — diagnostics counters
- `_last_g`, `_last_gyro_dps` — most recent sensor readings, stored here so
  `paintGL` can pick them up
- `_exit_button_rect` — screen-space rectangle of the Exit button, written by
  `_draw_overlay` each frame and read by `mousePressEvent` for hit-testing

### The timer

```python
self._timer = QTimer(self)
self._timer.timeout.connect(self._on_sample)
self._timer.start(SAMPLE_PERIOD_MS)
```

Three lines that create the 50-Hz sampling cadence. Passing `self` as the
timer's parent ensures Qt destroys the timer when the widget is destroyed
(no leak).

### See also

- [02-PYSIDE6-CONCEPTS.md §6](02-PYSIDE6-CONCEPTS.md#6-signals-and-slots--qts-event-system) — signals/slots
- [02-PYSIDE6-CONCEPTS.md §7](02-PYSIDE6-CONCEPTS.md#7-qtimer--periodic-callbacks) — QTimer

---

## 17. `_on_sample` (lines 394–424)

```python
def _on_sample(self) -> None:
    try:
        new_g = self._reader.read_g()
        new_gyro = self._reader.read_gyro_dps()
    except OSError as e:
        self._read_errors += 1
        if self._read_errors == 1 or self._read_errors % 50 == 0:
            print(
                f"[warn] sensor read failed: {e!r}  "
                f"(consecutive errors: {self._read_errors})"
            )
        self.update()
        return

    if self._read_errors:
        print(f"[info] sensor read recovered after {self._read_errors} error(s)")
        self._read_errors = 0

    self._last_g = new_g
    self._last_gyro_dps = new_gyro
    self._sample_count += 1
    if self._sample_count % PRINT_EVERY_N == 0:
        gx, gy, gz = self._last_g
        wx, wy, wz = self._last_gyro_dps
        print(
            f"G: x={gx:+.2f} y={gy:+.2f} z={gz:+.2f}   "
            f"ω°/s: x={wx:+7.1f} y={wy:+7.1f} z={wz:+7.1f}"
        )
    self.update()  # trigger paintGL so the HUD reflects the latest sample
```

### What it does

Slot called every 20 ms by `self._timer`. Reads sensors, updates state,
optionally logs to console, requests a repaint.

### Robustness — the try/except

If any of the six sysfs reads fails (typical: I2C transient on flaky wiring,
returns `OSError(EINVAL)`), we:

1. Increment `_read_errors`.
2. Log on the first error and every 50th after, to make persistent failures
   visible without flooding the console.
3. Trigger a repaint anyway (so the HUD doesn't freeze) and return.
4. **Don't** update `_last_g` / `_last_gyro_dps` — keep showing the previous
   good values.

When reads start succeeding again, log a recovery message and reset the
counter.

### Update flow

If reads succeed:

- Save the new readings to `_last_g`/`_last_gyro_dps`.
- Increment sample count and optionally print.
- `self.update()` to schedule a repaint.

The repaint is async — Qt will call `paintGL` on the next refresh, possibly
coalescing multiple `update()` calls into one paint.

### See also

- [01-PYTHON-CONCEPTS.md §9](01-PYTHON-CONCEPTS.md#9-exceptions) — try/except
- [02-PYSIDE6-CONCEPTS.md §11](02-PYSIDE6-CONCEPTS.md#11-the-update-repaint-cycle-in-detail) — update() lifecycle

---

## 18. `initializeGL` (lines 426–472)

```python
def initializeGL(self) -> None:
    print(f"GL_VENDOR:   {glGetString(GL_VENDOR).decode()}")
    print(f"GL_RENDERER: {glGetString(GL_RENDERER).decode()}")
    print(f"GL_VERSION:  {glGetString(GL_VERSION).decode()}")
    lw_range = glGetFloatv(GL_ALIASED_LINE_WIDTH_RANGE)
    print(f"line width range: {tuple(lw_range)}  (requested {LINE_WIDTH_PX})")

    glClearColor(*BG_COLOR)
    glEnable(GL_DEPTH_TEST)
    glLineWidth(LINE_WIDTH_PX)

    vs = _compile_shader(GL_VERTEX_SHADER, VERTEX_SHADER)
    fs = _compile_shader(GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
    self._program = _link_program(vs, fs)
    glDeleteShader(vs)
    glDeleteShader(fs)
    self._mvp_loc = glGetUniformLocation(self._program, "u_mvp")
    self._g_loc = glGetUniformLocation(self._program, "u_g")

    self._vao = int(glGenVertexArrays(1))
    glBindVertexArray(self._vao)

    self._vbo = int(glGenBuffers(1))
    glBindBuffer(GL_ARRAY_BUFFER, self._vbo)
    glBufferData(
        GL_ARRAY_BUFFER, ALL_VERTICES.nbytes + GYRO_RESERVE_BYTES, None, GL_DYNAMIC_DRAW
    )
    glBufferSubData(GL_ARRAY_BUFFER, 0, ALL_VERTICES.nbytes, ALL_VERTICES)

    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, VERTEX_STRIDE, ctypes.c_void_p(0))
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, VERTEX_STRIDE, ctypes.c_void_p(COLOR_OFFSET))
    glEnableVertexAttribArray(2)
    glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, VERTEX_STRIDE, ctypes.c_void_p(AXIS_OFFSET))

    glBindBuffer(GL_ARRAY_BUFFER, 0)
    glBindVertexArray(0)

    self._view = _look_at(
        np.array([2.5, 2.5, 2.5], dtype=np.float32),
        np.array([0.0, 0.0, 0.0], dtype=np.float32),
        np.array([0.0, 0.0, 1.0], dtype=np.float32),
    )
```

### What it does

Called once by Qt after the GL context is ready. All one-time GPU setup
happens here.

### Step by step

1. **Diagnostic prints** — vendor, renderer, version, line-width range. These
   end up on stdout so you can see them in the SSH session that launched the
   app. Not strictly required, but invaluable when debugging environmental
   issues.

2. **Render state**:
   - `glClearColor(*BG_COLOR)` — pick the background color for `glClear`.
   - `glEnable(GL_DEPTH_TEST)` — turn on depth testing.
   - `glLineWidth(LINE_WIDTH_PX)` — set initial line width (will be changed
     between draw calls in `paintGL`).

3. **Compile and link shaders**:
   - Compile vertex and fragment shaders separately.
   - Link into a program.
   - Delete shaders (program holds them).
   - Look up uniform locations once.

4. **Allocate VAO + VBO**:
   - One VAO (records attribute layout).
   - One VBO (holds vertex data).
   - Allocate the VBO with **enough room for static + gyro reserve**, but
     don't upload any data yet (`None` data argument).
   - Then `glBufferSubData` uploads just the static portion — leaving the
     reserved tail empty for `paintGL` to write into.

5. **Configure attribute pointers**:
   - Three attributes: position (3 floats at offset 0), color (4 floats at
     offset 12), axis_idx (1 float at offset 28).
   - Each enabled with `glEnableVertexAttribArray` and described with
     `glVertexAttribPointer`.

6. **Unbind VBO and VAO**: clean state.

7. **Build view matrix** for the fixed isometric camera. Eye at (2.5, 2.5,
   2.5), looking at origin, with +Z up. This matrix is built once and reused
   forever (camera doesn't move).

### Why allocate the VBO with `glBufferData(..., None, GL_DYNAMIC_DRAW)` then `glBufferSubData`

A clean way to "size and tag, then fill the static portion." If we did
`glBufferData(..., ALL_VERTICES, ...)` directly, we'd allocate exactly the
size of the static data, leaving no room for gyro arcs. Allocating a bigger
empty region and then sub-uploading the static portion gives us both.

`GL_DYNAMIC_DRAW` is a hint that the buffer will be modified; the driver may
choose memory placement accordingly.

### See also

- [03-OPENGL-CONCEPTS.md §6](03-OPENGL-CONCEPTS.md#6-vaos) — VAO mechanics
- [03-OPENGL-CONCEPTS.md §5](03-OPENGL-CONCEPTS.md#5-vbos-and-vertex-attributes) — vertex layout

---

## 19. `resizeGL` (lines 474–477)

```python
def resizeGL(self, w: int, h: int) -> None:
    glViewport(0, 0, w, h)
    aspect = w / max(h, 1)
    self._proj = _perspective(45.0, aspect, 0.1, 100.0)
```

### What it does

Called by Qt with the new size whenever the widget is resized — including
once at startup. Two responsibilities:

- **Tell GL the framebuffer size** (`glViewport`).
- **Recompute the projection matrix** to match the new aspect ratio (so
  squares stay square instead of stretching).

`max(h, 1)` is defensive — if Qt ever passes height = 0 (it shouldn't, but),
we avoid a divide-by-zero.

The projection has 45° vertical FOV, near plane 0.1, far plane 100.

---

## 20. `paintGL` (lines 479–524)

```python
def paintGL(self) -> None:
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    mvp = (self._proj @ self._view @ self._model).astype(np.float32)
    wx, wy, wz = self._last_gyro_dps
    gyro_floats = (
        _gyro_arc_vertices(0, wx, COLOR_X)
        + _gyro_arc_vertices(1, wy, COLOR_Y)
        + _gyro_arc_vertices(2, wz, COLOR_Z)
    )
    gyro_data = np.array(gyro_floats, dtype=np.float32)
    gyro_n_verts = gyro_data.size // 8
    if gyro_n_verts:
        glBindBuffer(GL_ARRAY_BUFFER, self._vbo)
        glBufferSubData(GL_ARRAY_BUFFER, GYRO_OFFSET_BYTES, gyro_data.nbytes, gyro_data)

    glUseProgram(self._program)
    glUniformMatrix4fv(self._mvp_loc, 1, GL_TRUE, mvp)
    glUniform3f(self._g_loc, *self._last_g)
    glBindVertexArray(self._vao)

    glLineWidth(LINE_WIDTH_PX)
    glDrawArrays(GL_LINES, 0, LINE_VERT_COUNT)
    glDrawArrays(GL_TRIANGLES, LINE_VERT_COUNT, ARROW_VERT_COUNT)
    if gyro_n_verts:
        glLineWidth(GYRO_LINE_WIDTH_PX)
        glDrawArrays(GL_LINES, GYRO_OFFSET_VERTS, gyro_n_verts)

    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
    glLineWidth(GRID_LINE_WIDTH_PX)
    glDrawArrays(GL_LINES, LINE_VERT_COUNT + ARROW_VERT_COUNT, GRID_VERT_COUNT)
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)

    glBindVertexArray(0)
    glUseProgram(0)

    self._mvp_cache = mvp
    self._draw_overlay()
```

### What it does

Renders one frame. Called by Qt whenever the widget needs repainting (we
trigger that with `self.update()` in `_on_sample`).

### High-level structure

1. Clear color and depth buffers.
2. Compute the current MVP.
3. Build gyro arc geometry from the latest ω readings; stream it into the
   VBO's reserved tail.
4. Bind program, set uniforms, bind VAO.
5. **Opaque pass**: axis lines, arrowhead cones, gyro arcs (each at its
   own line width).
6. **Transparent pass**: grid lines (with blending on, depth-write off).
7. Unbind.
8. Cache MVP for screen projection in the overlay.
9. Run the QPainter overlay (`_draw_overlay`).

### Step by step

```python
glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
```

Wipe the color buffer to `BG_COLOR` and reset the depth buffer to its max
"farthest" value.

```python
mvp = (self._proj @ self._view @ self._model).astype(np.float32)
```

Multiply the three matrices in NumPy. The `@` operator is matrix multiply.
`.astype(np.float32)` ensures the result is float32 — important because GL
expects 32-bit floats.

```python
wx, wy, wz = self._last_gyro_dps
gyro_floats = (
    _gyro_arc_vertices(0, wx, COLOR_X)
    + _gyro_arc_vertices(1, wy, COLOR_Y)
    + _gyro_arc_vertices(2, wz, COLOR_Z)
)
gyro_data = np.array(gyro_floats, dtype=np.float32)
gyro_n_verts = gyro_data.size // 8
```

Build the three gyro arcs as Python lists, concatenate, convert to NumPy.
`gyro_n_verts` is the actual vertex count (variable, depending on ω).

```python
if gyro_n_verts:
    glBindBuffer(GL_ARRAY_BUFFER, self._vbo)
    glBufferSubData(GL_ARRAY_BUFFER, GYRO_OFFSET_BYTES, gyro_data.nbytes, gyro_data)
```

If there are any gyro vertices to draw, stream them into the VBO's reserved
tail. `glBufferSubData` updates a sub-region without re-allocating. Skipping
the upload when `gyro_n_verts == 0` saves a tiny bit of work when all three
ω values round to zero.

```python
glUseProgram(self._program)
glUniformMatrix4fv(self._mvp_loc, 1, GL_TRUE, mvp)
glUniform3f(self._g_loc, *self._last_g)
glBindVertexArray(self._vao)
```

Activate the program, push the uniforms (MVP and current G readings), bind
the VAO so attribute layout is restored.

`GL_TRUE` is the transpose flag — see
[03-OPENGL-CONCEPTS.md §4](03-OPENGL-CONCEPTS.md#4-the-mvp-matrix).

```python
glLineWidth(LINE_WIDTH_PX)
glDrawArrays(GL_LINES, 0, LINE_VERT_COUNT)             # axis lines
glDrawArrays(GL_TRIANGLES, LINE_VERT_COUNT, ARROW_VERT_COUNT)  # arrowhead cones
if gyro_n_verts:
    glLineWidth(GYRO_LINE_WIDTH_PX)
    glDrawArrays(GL_LINES, GYRO_OFFSET_VERTS, gyro_n_verts)
```

Three opaque draws. Note we change line width between axis lines and gyro
arcs (the cones in between are triangles, so line width doesn't apply).

```python
glEnable(GL_BLEND)
glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
glDepthMask(GL_FALSE)
glLineWidth(GRID_LINE_WIDTH_PX)
glDrawArrays(GL_LINES, LINE_VERT_COUNT + ARROW_VERT_COUNT, GRID_VERT_COUNT)
glDepthMask(GL_TRUE)
glDisable(GL_BLEND)
```

Transparent pass — turn on blending, disable depth-write, draw the grid,
restore state.

```python
self._mvp_cache = mvp
self._draw_overlay()
```

Cache the MVP so `_draw_overlay` (and `_world_to_screen`) can project 3D
points to 2D screen coordinates without recomputing.

### Why update gyro geometry every frame, not just on sample?

You might think the right place to upload gyro is in `_on_sample`. Two
reasons we don't:

1. `glBufferSubData` requires an active GL context. `_on_sample` runs from a
   timer callback; there's no GL context current there.
2. The cost is trivial — at most ~12 KB per frame. Zero practical
   performance hit.

So we just do it inside `paintGL`, where the context is active.

### See also

- [03-OPENGL-CONCEPTS.md §15](03-OPENGL-CONCEPTS.md#15-the-render-order-in-paintgl--why-this-sequence) — render order rationale

---

## 21. `_world_to_screen` (lines 526–534)

```python
def _world_to_screen(self, world: tuple[float, float, float]) -> tuple[float, float] | None:
    clip = self._mvp_cache @ np.array([world[0], world[1], world[2], 1.0], dtype=np.float32)
    if abs(clip[3]) < 1e-6:
        return None
    ndc = clip[:3] / clip[3]
    if ndc[2] < -1.0 or ndc[2] > 1.0:
        return None
    w, h = self.width(), self.height()
    return ((ndc[0] + 1.0) * 0.5 * w, (1.0 - ndc[1]) * 0.5 * h)
```

### What it does

Projects a 3D world-space point to a 2D pixel coordinate on the widget.
Used by `_draw_overlay` to place text labels at axis positions.

### The math

```python
clip = MVP × [x, y, z, 1]
```

This is exactly what the vertex shader does — multiply the position by the
MVP matrix to get clip-space coordinates. Result is a 4-component vector
`[xc, yc, zc, wc]`.

```python
ndc = clip[:3] / clip[3]
```

Perspective divide: divide x, y, z by w to get Normalized Device Coordinates
in the range `[-1, +1]`.

```python
return ((ndc[0] + 1.0) * 0.5 * w, (1.0 - ndc[1]) * 0.5 * h)
```

Map NDC to pixel coordinates:

- NDC x in [-1, +1] → screen x in [0, w]: `(ndc.x + 1) / 2 * w`
- NDC y in [-1, +1] → screen y in [0, h]: `(1 - ndc.y) / 2 * h`
  (Y is **flipped** because Qt's coordinate system is y-down, OpenGL is y-up)

### Why return `None` sometimes

Two failure modes:

- `clip[3]` near zero — the point is on the plane of the camera (the math
  blows up).
- `ndc[2]` outside `[-1, +1]` — the point is in front of the near plane or
  behind the far plane (off-screen in depth).

In both cases there's no sensible 2D position; we tell the caller "skip this
label."

### See also

- [03-OPENGL-CONCEPTS.md §3](03-OPENGL-CONCEPTS.md#3-coordinate-spaces) — clip space → NDC → screen

---

## 22. `_draw_overlay` (lines 536–585)

```python
def _draw_overlay(self) -> None:
    painter = QPainter(self)
    painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)

    # HUD — top-left.
    hud_font = QFont()
    hud_font.setStyleHint(QFont.StyleHint.TypeWriter)
    hud_font.setFamily("Monospace")
    hud_font.setPointSize(13)
    hud_font.setBold(True)
    painter.setFont(hud_font)
    painter.setPen(QColor(230, 230, 230))
    gx, gy, gz = self._last_g
    wx, wy, wz = self._last_gyro_dps
    painter.drawText(20, 32,  f"G    X={gx:+5.2f}  Y={gy:+5.2f}  Z={gz:+5.2f}")
    painter.drawText(20, 58,  f"ω°/s X={wx:+6.1f} Y={wy:+6.1f} Z={wz:+6.1f}")

    # Axis tick labels along the positive direction of each axis.
    tick_font = QFont()
    tick_font.setPointSize(11)
    painter.setFont(tick_font)
    ticks = [GRID_STEP * (i + 1) for i in range(int(round(GRID_HALF / GRID_STEP)))]

    for g in ticks:
        self._draw_tick_label(painter, (g, 0.0, 0.0), f"{g:.2f}G", COLOR_X)
        self._draw_tick_label(painter, (0.0, g, 0.0), f"{g:.2f}G", COLOR_Y)
        self._draw_tick_label(painter, (0.0, 0.0, g), f"{g:.2f}G", COLOR_Z)

    # Axis-letter labels (X, Y, Z) at both extremes of each axis.
    border_font = QFont()
    border_font.setPointSize(16)
    border_font.setBold(True)
    painter.setFont(border_font)
    for axis_idx, letter, rgba in (
        (0, "X", COLOR_X),
        (1, "Y", COLOR_Y),
        (2, "Z", COLOR_Z),
    ):
        painter.setPen(QColor(
            int(rgba[0] * 255), int(rgba[1] * 255), int(rgba[2] * 255), 255
        ))
        for sign in (+1.0, -1.0):
            pos = [0.0, 0.0, 0.0]
            pos[axis_idx] = sign * GRID_HALF
            sp = self._world_to_screen(tuple(pos))
            if sp is None:
                continue
            painter.drawText(int(sp[0]) + 10, int(sp[1]) + 6, letter)

    # Exit button — top right. Rect is cached so mousePressEvent can hit-test it.
    btn_w, btn_h, btn_margin = 100, 40, 20
    self._exit_button_rect = QRect(
        self.width() - btn_margin - btn_w, btn_margin, btn_w, btn_h
    )
    painter.setBrush(QColor(45, 45, 50, 220))
    painter.setPen(QColor(200, 200, 200, 180))
    painter.drawRoundedRect(self._exit_button_rect, 6, 6)

    btn_font = QFont()
    btn_font.setPointSize(13)
    btn_font.setBold(True)
    painter.setFont(btn_font)
    painter.setPen(QColor(240, 240, 240))
    painter.drawText(self._exit_button_rect, Qt.AlignmentFlag.AlignCenter, "Exit")

    painter.end()
```

### What it does

Draws all 2D text and UI overlays on top of the rendered 3D scene.

### Four sections

**HUD (top-left)** — fixed pixel position. Two lines of monospaced text with
the live G and ω readings. `+5.2f` and `+6.1f` give consistent column widths
so values don't jitter as they change sign or magnitude.

**Tick labels** — the values like "0.50G", "1.00G", etc. positioned at each
positive-axis grid tick. We project the 3D world position to 2D first.

`ticks = [GRID_STEP * (i + 1) for i in range(int(round(GRID_HALF / GRID_STEP)))]`
generates `[0.5, 1.0, 1.5, 2.0]` (with current GRID_STEP=0.5, GRID_HALF=2.0).

**Border letters** — bold "X" / "Y" / "Z" at both ends of each axis. We
build a position vector by setting one component to `±GRID_HALF` and leaving
the other two at zero.

**Exit button (top-right)** — a 100×40 rounded rectangle with the text "Exit"
centered. The rectangle is computed from `self.width()` so it follows the
right edge if the widget is ever resized, and stored in
`self._exit_button_rect` so `mousePressEvent` can hit-test it. Drawing a
filled shape with `setBrush(...) + setPen(...) + drawRoundedRect(...)` is
new pattern in this overlay; previous sections only drew text.

### Color mapping

```python
QColor(int(rgba[0] * 255), int(rgba[1] * 255), int(rgba[2] * 255), 255)
```

`COLOR_X` etc. store RGBA as floats in `[0, 1]`. Qt's `QColor` wants ints in
`[0, 255]`. The multiplication by 255 + cast to int is the conversion.

The `255` at the end is alpha — full opacity for the border letters. The
tick labels use `200` (slightly transparent) because they're decorative
clutter we don't want competing too hard with the 3D scene.

### See also

- [02-PYSIDE6-CONCEPTS.md §9](02-PYSIDE6-CONCEPTS.md#9-qpainter--2d-drawing-on-top-of-gl) — QPainter on QOpenGLWidget

---

## 23. `_draw_tick_label` (lines 587–598)

```python
def _draw_tick_label(
    self,
    painter: QPainter,
    world_pos: tuple[float, float, float],
    text: str,
    rgba: tuple[float, float, float, float],
) -> None:
    sp = self._world_to_screen(world_pos)
    if sp is None:
        return
    painter.setPen(QColor(int(rgba[0] * 255), int(rgba[1] * 255), int(rgba[2] * 255), 200))
    painter.drawText(int(sp[0]) + 5, int(sp[1]) - 2, text)
```

### What it does

Helper for the tick-label loop in `_draw_overlay`. Takes a world position,
projects to screen, sets the painter's pen color from the RGBA tuple, and
draws the text with a small (+5, −2) offset so it sits next to the projected
point rather than directly on top of it.

Returns early if the world point doesn't project (off-screen / behind camera).

---

## 24. `keyPressEvent`

```python
def keyPressEvent(self, event) -> None:
    if event.key() == Qt.Key.Key_Escape:
        self.close()
```

### What it does

Qt calls this whenever a key is pressed while the widget has focus. We close
the widget on Escape; closing the last top-level widget triggers `app.quit()`.

This is one of three exit paths:

1. **ESC** (this method).
2. **Click the Exit button** in the top-right corner — handled by
   `mousePressEvent` (next section).
3. **Ctrl+C in the launching terminal** — handled by the kernel because of
   the `SIG_DFL` line at module top.

### See also

- [02-PYSIDE6-CONCEPTS.md §10](02-PYSIDE6-CONCEPTS.md#10-input-events--keyboard-and-mouse) — input events

---

## 25. `mousePressEvent`

```python
def mousePressEvent(self, event) -> None:
    if event.button() == Qt.MouseButton.LeftButton and \
            self._exit_button_rect.contains(event.position().toPoint()):
        self.close()
        return
    super().mousePressEvent(event)
```

### What it does

Qt calls this whenever the user presses a mouse button (or, on a touchscreen,
taps) while the widget has focus. We hit-test the click against the Exit
button's cached rectangle; if it's inside, we close.

### Step by step

```python
if event.button() == Qt.MouseButton.LeftButton and \
        self._exit_button_rect.contains(event.position().toPoint()):
```

- `event.button()` — which button caused the event. `Qt.MouseButton.LeftButton`
  is the primary button (and on touchscreens, taps map to left-button presses).
- `event.position()` — the click position in the widget's local coords as a
  `QPointF` (floating-point).
- `.toPoint()` — convert to integer-pixel `QPoint`.
- `self._exit_button_rect.contains(...)` — does the click fall inside the
  cached button rectangle?

```python
self.close()
return
```

If we matched, close the widget and return early — don't pass the event up
to the base class.

```python
super().mousePressEvent(event)
```

Otherwise call the parent's handler. `QOpenGLWidget` doesn't do anything
useful with mouse events on its own, but calling `super` is the polite
default; if you ever subclass `AxisScene` further, you'll want this in place.

### How the rectangle stays in sync

`self._exit_button_rect` is rebuilt from `self.width()` every frame inside
`_draw_overlay`. So even if the widget gets resized between paints, the next
paint refreshes the rectangle and `mousePressEvent` reads the up-to-date
value.

Touch input "just works" — Qt translates touch events into mouse events by
default. If you ever want true multi-touch (pinch, two-finger pan, etc.),
that's a different API (`QTouchEvent`), but we don't need it here.

### See also

- [02-PYSIDE6-CONCEPTS.md §10](02-PYSIDE6-CONCEPTS.md#10-input-events--keyboard-and-mouse) — input events

---

## 26. `main` and entry point

```python
def main() -> int:
    fmt = QSurfaceFormat()
    fmt.setRenderableType(QSurfaceFormat.RenderableType.OpenGLES)
    fmt.setVersion(3, 0)
    fmt.setDepthBufferSize(24)
    QSurfaceFormat.setDefaultFormat(fmt)

    app = QApplication(sys.argv)
    w = AxisScene()
    w.setWindowTitle("EAIE accelerometer axis")
    w.showFullScreen()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
```

### What it does

The standard PySide6 startup dance:

1. **Build a `QSurfaceFormat`** describing the GL context we want (ES 3.0,
   24-bit depth buffer). Set it as the default before creating any widgets.
2. **Create the `QApplication`** — the event loop owner.
3. **Create our widget**, set its window title, show it fullscreen.
4. **Enter the event loop** with `app.exec()` and return its exit code.

### See also

- [02-PYSIDE6-CONCEPTS.md §3](02-PYSIDE6-CONCEPTS.md#3-qapplication--the-application-object) — QApplication
- [02-PYSIDE6-CONCEPTS.md §8](02-PYSIDE6-CONCEPTS.md#8-qsurfaceformat--configuring-the-gl-context) — QSurfaceFormat
- [01-PYTHON-CONCEPTS.md §10](01-PYTHON-CONCEPTS.md#10-the-if-__name__--__main__-idiom) — entry-point idiom

---

## End-to-end frame trace

Once everything is set up, a typical frame looks like:

```
T=0 ms     timer fires (50 Hz cadence)
            ↓
           _on_sample()
             ├─ ImuReader.read_g()      → 3 sysfs reads + I2C transactions
             ├─ ImuReader.read_gyro_dps() → 3 sysfs reads + I2C transactions
             ├─ store in _last_g, _last_gyro_dps
             ├─ console print
             └─ self.update()           → mark widget dirty
            ↓
T~5 ms     control returns to event loop
            ↓
           Qt: "widget is dirty, request repaint, wait for vsync"
            ↓
T~16 ms    vsync; Qt calls paintGL()
             ├─ glClear
             ├─ compute MVP
             ├─ build gyro arc geometry (CPU)
             ├─ glBufferSubData → upload gyro region
             ├─ glDrawArrays × 4 (axes, arrows, gyro arcs, grid)
             ├─ _draw_overlay()
             │    ├─ HUD text
             │    ├─ tick labels (3 axes × 4 ticks = 12 labels)
             │    └─ border letters (3 axes × 2 ends = 6 letters)
             └─ swap buffers (next vsync)
            ↓
T~17 ms    pixels appear on the panel
            ↓
T=20 ms    timer fires again, loop repeats
```

End-to-end latency from chip motion to pixel update: ~25–35 ms (sensor sample
period + I2C + render + vsync + panel pixel response). At 50 Hz sampling on a
60 Hz display, this is comfortably below the perceptual threshold for "live"
visualization.
