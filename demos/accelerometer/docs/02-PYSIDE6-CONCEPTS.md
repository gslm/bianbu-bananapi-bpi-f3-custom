# 02 — PySide6 / Qt6 Concepts

This document covers the Qt6 framework concepts the demo uses. Qt is a large
GUI toolkit; we use a small slice of it (a window, an OpenGL canvas, a timer,
2D text). Everything below is scoped to that slice.

## 1. What is Qt? What is PySide6?

**Qt** is a C++ framework for building cross-platform GUI applications. It's
been around since 1995, is maintained by The Qt Company, and powers KDE,
Telegram, VLC, OBS Studio, and a lot of industrial / embedded UIs.

**PySide6** is the official Python binding for Qt 6. You write Python; under
the hood, every call goes into Qt's C++ libraries via auto-generated
`shiboken6` bindings.

There's also **PyQt6** — a different Python binding, by Riverbank Computing,
predating PySide6. The two have nearly identical APIs but slightly different
licensing and packaging. We use PySide6 in this project because Bianbu's
build of Qt 6 is OpenGL-ES-only, and the upstream Debian PyQt6 binary
references desktop-GL symbols that aren't present, so it fails to load. The
Bianbu PySide6 packages are built against Bianbu's own Qt and load cleanly.

If you read PyQt6 tutorials elsewhere, the code transfers almost 1:1: change
the import path from `PyQt6` to `PySide6` and you're done.

## 2. The mental model: event-driven programming

A GUI app is fundamentally different from a script. A script runs top-to-
bottom and exits. A GUI app spends almost all its life sitting idle, waiting
for something to happen — a key press, a mouse move, a timer firing, the
window needing redraw — and reacts.

The "engine" that does the waiting and dispatching is the **event loop**.
Inside Qt, it looks roughly like:

```python
while not quit_requested:
    event = wait_for_next_event()    # blocks until something happens
    dispatch_to_appropriate_handler(event)
```

You don't write that loop. You write the *handlers* (functions that respond
to events) and tell Qt about them. The line in `main()`:

```python
return app.exec()
```

is what enters that loop. It returns only when the application is asked to
quit — either programmatically (`app.quit()`) or by user action (e.g. closing
the last window).

## 3. QApplication — the application object

Every Qt program needs exactly one `QApplication` instance. It owns the event
loop, manages windows, and holds global state.

```python
from PySide6.QtWidgets import QApplication

app = QApplication(sys.argv)         # construct the app
# ... create windows, set things up ...
return app.exec()                    # enter event loop; returns when app quits
```

`sys.argv` is the command-line arguments. Qt parses some of them itself (e.g.
`-style fusion`, `-platform wayland`) so it's polite to hand them in.

## 4. Widgets

A **widget** is anything visible on screen — a button, a text box, a window.
All widgets descend from `QWidget`. A window is just a top-level widget (one
without a parent).

```
QObject
└── QWidget
    ├── QLabel
    ├── QPushButton
    ├── QLineEdit
    ├── QMainWindow
    ├── QOpenGLWidget   ← we use this
    └── ... 100+ more
```

A widget tree forms automatically when you give widgets parents. We have no
tree — `AxisScene` is a single top-level widget that fills the screen.

### Showing a widget

```python
w = AxisScene()
w.setWindowTitle("EAIE accelerometer axis")
w.showFullScreen()
```

`showFullScreen()` makes the widget cover the whole display, no decorations.
There's also `show()` (windowed) and `showMaximized()`.

## 5. QOpenGLWidget — the OpenGL canvas

`QOpenGLWidget` is a widget whose surface is an OpenGL framebuffer. You don't
draw with `QPainter`; you draw with raw OpenGL calls. Qt sets up the GL
context, you fill it.

It exposes three methods you override:

```python
class AxisScene(QOpenGLWidget):
    def initializeGL(self) -> None: ...   # called once when GL is ready
    def resizeGL(self, w, h) -> None: ... # called when widget is resized
    def paintGL(self) -> None: ...        # called when the widget needs repainting
```

**Don't call these yourself.** Qt calls them at the right times:

- `initializeGL` — once, after the GL context has been created. Allocate
  buffers, compile shaders here.
- `resizeGL(w, h)` — once at startup with the initial size, and again on every
  size change. Set the viewport and update your projection matrix here.
- `paintGL` — every time the widget needs repainting. Clear the framebuffer
  and draw your scene here.

### Triggering repaints

`paintGL` doesn't run on its own clock — Qt only calls it when something
caused the widget to be marked "dirty." You force a repaint by calling
`self.update()`:

```python
def _on_sample(self) -> None:
    self._last_g = self._reader.read_g()
    ...
    self.update()  # ask Qt to call paintGL again
```

`update()` doesn't redraw immediately — it just adds a "needs paint" flag.
Qt batches these and triggers `paintGL` at most once per display refresh
(via vsync). So calling `update()` 50 times per second on a 60 Hz display
results in roughly 50 actual paints; calling it 500 times per second would
still result in only ~60 actual paints.

### Why `QOpenGLWidget` here, why not pure OpenGL?

Two reasons:

1. **The window/event integration is free.** Without Qt, you'd write all the
   platform glue yourself (Wayland surface, EGL context, input handling).
2. **2D overlays are easy.** After you finish your 3D drawing in `paintGL`,
   you can create a `QPainter` on the widget and use it to draw text, lines,
   icons. We use this for the HUD and tick labels.

## 6. Signals and slots — Qt's event system

Qt has a publish-subscribe pattern called **signals and slots**.

- A **signal** is an event source. Things "emit" signals when something
  happens (a button is clicked, a timer fires, a value changes).
- A **slot** is a handler. You "connect" a slot to a signal so it gets called
  whenever the signal fires.

```python
self._timer = QTimer(self)
self._timer.timeout.connect(self._on_sample)
self._timer.start(SAMPLE_PERIOD_MS)
```

- `self._timer.timeout` is the timer's **signal** (the timer emits it
  periodically).
- `self._on_sample` is our **slot**.
- `.connect(...)` wires them together.

After this, every time the timer fires its `timeout` signal, Qt calls
`self._on_sample()`.

Our app uses signals/slots in only this one place. They're a much bigger deal
in larger Qt apps with buttons, menus, dialogs.

## 7. QTimer — periodic callbacks

`QTimer` calls a slot periodically. Two key methods:

```python
self._timer = QTimer(self)
self._timer.timeout.connect(self._on_sample)
self._timer.start(20)        # 20 ms = 50 Hz
```

After `start(N)`, the timer emits `timeout` every N milliseconds while the
event loop is running. `stop()` halts it. You can change the interval with
`setInterval(N)` and have it fire only once with `setSingleShot(True)`.

The timer fires *on the GUI thread*. So `_on_sample` blocks the rest of the
GUI for however long it takes to run. Sysfs reads take a millisecond or two,
so we're fine.

## 8. QSurfaceFormat — configuring the GL context

Before constructing `QApplication`, we tell Qt what kind of OpenGL context we
want. The shape of `main()`:

```python
def main() -> int:
    fmt = QSurfaceFormat()
    fmt.setRenderableType(QSurfaceFormat.RenderableType.OpenGLES)
    fmt.setVersion(3, 0)
    fmt.setDepthBufferSize(24)
    QSurfaceFormat.setDefaultFormat(fmt)

    app = QApplication(sys.argv)
    ...
```

- `setRenderableType(OpenGLES)` — request OpenGL ES (vs. desktop OpenGL). On
  Bianbu's PowerVR driver, only ES is available.
- `setVersion(3, 0)` — OpenGL ES 3.0 specifically (the version of GLSL we
  write shaders in).
- `setDepthBufferSize(24)` — request a 24-bit depth buffer for depth testing.

`setDefaultFormat(fmt)` makes this the format for any OpenGL widgets created
afterwards. Has to happen *before* `QApplication` is constructed.

## 9. QPainter — 2D drawing on top of GL

`QPainter` is Qt's 2D drawing API: lines, shapes, text, gradients. Inside a
`QOpenGLWidget`'s `paintGL`, after you're done with raw GL, you can create a
`QPainter` to draw 2D content:

```python
painter = QPainter(self)
painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)
painter.setPen(QColor(230, 230, 230))
painter.drawText(20, 32, "G = +0.12, +0.45, +0.78")
painter.end()
```

Coordinate system: `(0, 0)` is the **top-left corner** of the widget, x grows
right, y grows down (different from OpenGL's y-up convention!).

`drawText(x, y, "...")` puts the text's baseline at `y`. So if `y = 32` the
text appears just above pixel row 32.

### Fonts and colors

```python
font = QFont()
font.setStyleHint(QFont.StyleHint.TypeWriter)
font.setFamily("Monospace")
font.setPointSize(13)
font.setBold(True)
painter.setFont(font)

painter.setPen(QColor(230, 230, 230))            # opaque grey
painter.setPen(QColor(255, 64, 64, 200))         # semi-transparent red (RGBA)
```

`setStyleHint(TypeWriter)` is a fallback hint: "if 'Monospace' isn't on this
system, pick any monospace font." On Bianbu, "Monospace" exists, so the hint
is a safety net.

### Mixing GL and QPainter — the rule

**Do all your raw GL drawing first, then create the QPainter.** Don't
interleave. Inside `paintGL`:

```python
def paintGL(self):
    glClear(...)
    self._draw_3d_scene()       # all glClear / glDrawArrays / etc. here

    painter = QPainter(self)    # then start the painter
    painter.drawText(...)
    painter.end()               # important: explicitly end before paintGL returns
```

If you forget `painter.end()`, weird artifacts can appear in the next frame.
Putting `painter.end()` as the last line of the helper that creates the
painter is a robust habit.

## 10. Input events — keyboard and mouse

`QWidget` exposes input events as overridable methods. Qt calls them
whenever the widget has focus and the user does something. We use two:

### Keyboard — `keyPressEvent`

```python
def keyPressEvent(self, event) -> None:
    if event.key() == Qt.Key.Key_Escape:
        self.close()
```

`event.key()` returns one of the `Qt.Key.*` enum values. `self.close()`
closes the widget; closing the last top-level widget triggers `app.quit()`,
which exits `app.exec()`.

### Mouse — `mousePressEvent`

```python
def mousePressEvent(self, event) -> None:
    if event.button() == Qt.MouseButton.LeftButton and \
            self._exit_button_rect.contains(event.position().toPoint()):
        self.close()
        return
    super().mousePressEvent(event)
```

`event.button()` returns the button that triggered the event
(`Qt.MouseButton.LeftButton` is the primary one).
`event.position()` returns the click position in the widget's local
coordinates as a `QPointF`; `.toPoint()` converts it to a pixel-integer
`QPoint`.

For things like a clickable button drawn via `QPainter` (no actual
`QPushButton` widget), you do hit-testing manually: keep a `QRect` of the
button's screen rectangle, and ask if the click is inside it.

### Touch on a touchscreen

Qt translates touch events into mouse events by default, so a tap on the
panel triggers `mousePressEvent` exactly the same way a click does. You
don't need anything special. If you ever want pinch / multi-finger
gestures, that's `QTouchEvent` — different API, not used here.

### Other input events

All work the same way: `mouseMoveEvent`, `mouseReleaseEvent`,
`mouseDoubleClickEvent`, `wheelEvent`, `keyReleaseEvent`. Override the ones
you need; ignore the rest.

## 11. The `update()` repaint cycle in detail

The full sequence on each sample:

```
QTimer (every 20 ms)
   │  emits .timeout signal
   ▼
self._on_sample()
   │  reads sensor, stores _last_g / _last_gyro_dps
   │  calls self.update()       ← marks widget dirty
   ▼
(control returns to event loop)
   │  Qt notices widget is dirty
   │  ...waits until display is ready (vsync)
   ▼
self.paintGL()
   │  reads _last_g / _last_gyro_dps
   │  redraws the scene + HUD
   ▼
(control returns to event loop)
```

Notice: the timer reads sensors and stores values; `paintGL` later picks
them up. They communicate through the widget's instance variables.

The timer can fire faster than the display can refresh — and that's fine.
Multiple `update()` calls collapse into a single repaint per refresh. So the
HUD always shows the *latest* sample; intermediate samples between vsyncs are
not drawn but also not lost from a data perspective (they were stored).

## 12. Qt enums in PySide6

Qt enums are accessed via the class — and as of Qt 6, the recommended style
is "scoped":

```python
Qt.Key.Key_Escape                           # not Qt.Key_Escape
QFont.StyleHint.TypeWriter
QSurfaceFormat.RenderableType.OpenGLES
QPainter.RenderHint.TextAntialiasing
```

Older code (Qt 5 era) wrote `Qt.Key_Escape`. Both work in PySide6 6.x but the
scoped form is preferred.

## 13. What you do NOT use here from Qt

Qt has lots of features the demo doesn't touch:

- `QML` and Qt Quick (declarative UI)
- `QObject` parent/child memory management beyond what we need
- Layout managers (`QHBoxLayout`, `QGridLayout`)
- Models and views (`QStandardItemModel`)
- Threads (`QThread`, `QtConcurrent`)
- Networking (`QNetworkAccessManager`)
- Internationalization (`tr()`)

If a Qt tutorial dwells on those, you can safely defer them.

## 14. Quick reference

| Class / function | What it is |
|---|---|
| `QApplication` | The application; owns the event loop |
| `QWidget` | Anything visible on screen |
| `QOpenGLWidget` | A widget whose surface is OpenGL |
| `paintGL` / `initializeGL` / `resizeGL` | Override these to render |
| `update()` | Mark widget dirty → triggers paintGL |
| `QTimer` | Periodic callback via signal/slot |
| `QSurfaceFormat` | Configure GL context (version, depth) |
| `QPainter` | 2D drawing (text, shapes) |
| `QFont`, `QColor` | Painter style |
| `keyPressEvent` / `mousePressEvent` | Override to handle keyboard / mouse / touch |
| `app.exec()` | Enter the event loop; returns when app quits |
| `Qt.Key.*` | Keyboard key enums |
