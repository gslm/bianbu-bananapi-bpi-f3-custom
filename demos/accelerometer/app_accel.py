#!/usr/bin/env python3
"""EAIE accelerometer-axis app — static 3D tripod, fullscreen ES3, ESC to exit."""

import os
import signal
import sys

# Restore SIG_DFL so Ctrl+C kills the process — Python's default SIGINT handler
# can't run from inside Qt's C++ event loop.
signal.signal(signal.SIGINT, signal.SIG_DFL)

# Default Qt to the LXQt Wayland session when launched from a non-graphical shell.
if "QT_QPA_PLATFORM" not in os.environ:
    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    if os.path.exists(f"{os.environ['XDG_RUNTIME_DIR']}/wayland-0"):
        os.environ.setdefault("WAYLAND_DISPLAY", "wayland-0")
        os.environ["QT_QPA_PLATFORM"] = "wayland"

import ctypes
import math

import numpy as np

# Bianbu's PySide6.QtOpenGL .so fails to load (references desktop-GL symbols
# missing from this ES-only Qt build). We use PyOpenGL for all GL-API access
# and only borrow QOpenGLWidget (from QtOpenGLWidgets, a separate module).
from OpenGL.GL import (
    GL_ALIASED_LINE_WIDTH_RANGE,
    GL_ARRAY_BUFFER,
    GL_BLEND,
    GL_COLOR_BUFFER_BIT,
    GL_COMPILE_STATUS,
    GL_DEPTH_BUFFER_BIT,
    GL_DEPTH_TEST,
    GL_FALSE,
    GL_FLOAT,
    GL_FRAGMENT_SHADER,
    GL_LINES,
    GL_LINK_STATUS,
    GL_ONE_MINUS_SRC_ALPHA,
    GL_DYNAMIC_DRAW,
    GL_RENDERER,
    GL_SRC_ALPHA,
    GL_STATIC_DRAW,
    GL_TRIANGLES,
    GL_TRUE,
    GL_VENDOR,
    GL_VERSION,
    GL_VERTEX_SHADER,
    glAttachShader,
    glBindBuffer,
    glBindVertexArray,
    glBlendFunc,
    glBufferData,
    glBufferSubData,
    glClear,
    glClearColor,
    glCompileShader,
    glCreateProgram,
    glCreateShader,
    glDeleteShader,
    glDepthMask,
    glDisable,
    glDrawArrays,
    glEnable,
    glEnableVertexAttribArray,
    glGenBuffers,
    glGenVertexArrays,
    glGetFloatv,
    glGetProgramInfoLog,
    glGetProgramiv,
    glGetShaderInfoLog,
    glGetShaderiv,
    glGetString,
    glGetUniformLocation,
    glLineWidth,
    glLinkProgram,
    glShaderSource,
    glUniform3f,
    glUniformMatrix4fv,
    glUseProgram,
    glVertexAttribPointer,
    glViewport,
)
from PySide6.QtCore import Qt, QRect, QTimer
from PySide6.QtGui import QColor, QFont, QPainter, QSurfaceFormat
from PySide6.QtOpenGLWidgets import QOpenGLWidget
from PySide6.QtWidgets import QApplication

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

GYRO_RADIUS = 0.15            # arc radius around each axis
GYRO_OMEGA_MAX_DPS = 200.0    # arc fills GYRO_ARC_MAX_RAD at this magnitude
GYRO_ARC_MAX_RAD = math.pi * 1.5  # max sweep = 270°
GYRO_ARC_SEGMENTS_MAX = 64
GYRO_LINE_WIDTH_PX = 5.0

COLOR_X = (1.00, 0.30, 0.30, 1.00)
COLOR_Y = (0.30, 0.90, 0.40, 1.00)
COLOR_Z = (0.45, 0.65, 1.00, 1.00)

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
    # Pick any reference vector not parallel to `direction` to build the basis.
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


GRID_VERTICES = np.array(
    _grid_lines_in_plane(0, 1, GRID_COLOR)    # XY plane (Z = 0)
    + _grid_lines_in_plane(1, 2, GRID_COLOR)  # YZ plane (X = 0)
    + _grid_lines_in_plane(0, 2, GRID_COLOR), # XZ plane (Y = 0)
    dtype=np.float32,
)

ALL_VERTICES = np.concatenate([AXIS_LINE_VERTICES, ARROW_VERTICES, GRID_VERTICES])
LINE_VERT_COUNT = len(AXIS_LINE_VERTICES) // 8
ARROW_VERT_COUNT = len(ARROW_VERTICES) // 8
GRID_VERT_COUNT = len(GRID_VERTICES) // 8

VERTEX_STRIDE = 8 * ALL_VERTICES.itemsize
COLOR_OFFSET = 3 * ALL_VERTICES.itemsize
AXIS_OFFSET = 7 * ALL_VERTICES.itemsize

# Reserved region at the end of the VBO for gyro arcs (regenerated per frame).
GYRO_MAX_VERTS = 3 * GYRO_ARC_SEGMENTS_MAX * 2  # 3 axes × max segments × 2 verts/seg
GYRO_RESERVE_BYTES = GYRO_MAX_VERTS * VERTEX_STRIDE
GYRO_OFFSET_VERTS = LINE_VERT_COUNT + ARROW_VERT_COUNT + GRID_VERT_COUNT
GYRO_OFFSET_BYTES = ALL_VERTICES.nbytes


def _gyro_arc_vertices(
    axis: int,
    omega_dps: float,
    color: tuple[float, float, float, float],
) -> list[float]:
    """Line vertices for one gyro arc curling around axis at distance 1.0 from origin."""
    omega_norm = max(-1.0, min(1.0, omega_dps / GYRO_OMEGA_MAX_DPS))
    arc_rad = omega_norm * GYRO_ARC_MAX_RAD
    n_segs = max(1, int(GYRO_ARC_SEGMENTS_MAX * abs(omega_norm)))

    # Center on the axis at the static 1G mark; u, v form a right-handed basis
    # so positive omega sweeps CCW around +axis (right-hand rule).
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

BG_COLOR = (0.06, 0.07, 0.10, 1.0)

G_MS2 = 9.80665
RAD_TO_DEG = 180.0 / math.pi
SYSFS_IIO = "/sys/bus/iio/devices/iio:device1"
SAMPLE_PERIOD_MS = 20  # 50 Hz
PRINT_EVERY_N = 1      # 1 = print every sample = 50 Hz console rate


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

    def _on_sample(self) -> None:
        try:
            new_g = self._reader.read_g()
            new_gyro = self._reader.read_gyro_dps()
        except OSError as e:
            # Transient sysfs/I2C failure (flaky wiring etc.). Keep last good
            # values and warn sparingly so the console isn't flooded.
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
        # Allocate static + dynamic (gyro) regions in one buffer; load static now.
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

        # Fixed isometric view, Z-up. Eye on (1,1,1)*r gives equal foreshortening
        # on all three axes — the visual signature of an isometric projection.
        self._view = _look_at(
            np.array([2.5, 2.5, 2.5], dtype=np.float32),
            np.array([0.0, 0.0, 0.0], dtype=np.float32),
            np.array([0.0, 0.0, 1.0], dtype=np.float32),
        )

    def resizeGL(self, w: int, h: int) -> None:
        glViewport(0, 0, w, h)
        aspect = w / max(h, 1)
        self._proj = _perspective(45.0, aspect, 0.1, 100.0)

    def paintGL(self) -> None:
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
        # Numpy matrices are row-major; GL expects column-major. We pass
        # transpose=GL_TRUE so the driver flips them on upload.
        mvp = (self._proj @ self._view @ self._model).astype(np.float32)
        # Build gyro arc geometry for this frame and stream it into the
        # reserved tail of the VBO. Variable length depending on |omega|.
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

        # Opaque pass: axis lines, arrowheads, gyro arcs all write depth.
        glLineWidth(LINE_WIDTH_PX)
        glDrawArrays(GL_LINES, 0, LINE_VERT_COUNT)
        glDrawArrays(GL_TRIANGLES, LINE_VERT_COUNT, ARROW_VERT_COUNT)
        if gyro_n_verts:
            glLineWidth(GYRO_LINE_WIDTH_PX)
            glDrawArrays(GL_LINES, GYRO_OFFSET_VERTS, gyro_n_verts)

        # Transparent pass: faint grid lines.
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

    def _world_to_screen(self, world: tuple[float, float, float]) -> tuple[float, float] | None:
        clip = self._mvp_cache @ np.array([world[0], world[1], world[2], 1.0], dtype=np.float32)
        if abs(clip[3]) < 1e-6:
            return None
        ndc = clip[:3] / clip[3]
        if ndc[2] < -1.0 or ndc[2] > 1.0:
            return None
        w, h = self.width(), self.height()
        return ((ndc[0] + 1.0) * 0.5 * w, (1.0 - ndc[1]) * 0.5 * h)

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

    def keyPressEvent(self, event) -> None:
        if event.key() == Qt.Key.Key_Escape:
            self.close()

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton and \
                self._exit_button_rect.contains(event.position().toPoint()):
            self.close()
            return
        super().mousePressEvent(event)


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
