#!/usr/bin/env python3
"""EAIE accelerometer-axis smoke test — fullscreen ES3 window, ESC to exit."""

import os
import signal
import sys

# Restore SIG_DFL so Ctrl+C from the launching terminal kills the process —
# Python's default SIGINT handler can't run from inside Qt's C++ event loop.
signal.signal(signal.SIGINT, signal.SIG_DFL)

# Default Qt to the LXQt Wayland session when launched from a non-graphical shell.
if "QT_QPA_PLATFORM" not in os.environ:
    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    if os.path.exists(f"{os.environ['XDG_RUNTIME_DIR']}/wayland-0"):
        os.environ.setdefault("WAYLAND_DISPLAY", "wayland-0")
        os.environ["QT_QPA_PLATFORM"] = "wayland"

from PySide6.QtCore import Qt
from PySide6.QtGui import QSurfaceFormat
from PySide6.QtOpenGLWidgets import QOpenGLWidget
from PySide6.QtWidgets import QApplication
from OpenGL.GL import (
    GL_COLOR_BUFFER_BIT,
    GL_RENDERER,
    GL_VENDOR,
    GL_VERSION,
    glClear,
    glClearColor,
    glGetString,
)


class SmokeWidget(QOpenGLWidget):
    def initializeGL(self) -> None:
        print(f"GL_VENDOR:   {glGetString(GL_VENDOR).decode()}")
        print(f"GL_RENDERER: {glGetString(GL_RENDERER).decode()}")
        print(f"GL_VERSION:  {glGetString(GL_VERSION).decode()}")
        glClearColor(0.06, 0.07, 0.10, 1.0)

    def paintGL(self) -> None:
        glClear(GL_COLOR_BUFFER_BIT)

    def keyPressEvent(self, event) -> None:
        if event.key() == Qt.Key.Key_Escape:
            self.close()


def main() -> int:
    fmt = QSurfaceFormat()
    fmt.setRenderableType(QSurfaceFormat.RenderableType.OpenGLES)
    fmt.setVersion(3, 0)
    QSurfaceFormat.setDefaultFormat(fmt)

    app = QApplication(sys.argv)
    w = SmokeWidget()
    w.setWindowTitle("EAIE accelerometer axis — smoke test")
    w.showFullScreen()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
