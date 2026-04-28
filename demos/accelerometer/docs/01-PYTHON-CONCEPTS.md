# 01 — Python Concepts Used in `app.py`

This document covers Python language features that show up in
[app.py](../app.py). It's a focused refresher rather than a Python tutorial —
each topic is included only because the code uses it.

If a section sounds familiar, skim it. If something in the walkthrough
([04-APP-WALKTHROUGH.md](04-APP-WALKTHROUGH.md)) confuses you, jump back here.

## 1. Modules, imports, and module-level code

A `.py` file is a **module**. The lines at the top of `app.py` that aren't
inside a function or class are **module-level code**: they run exactly once,
the moment the file is first imported or executed.

The very first lines of `app.py`:

```python
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)

if "QT_QPA_PLATFORM" not in os.environ:
    os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    ...
```

These run at startup time, *before* any function is called. They configure
process-wide state (signal handler, environment variables) early enough that
later imports see the right environment.

### Three forms of import you'll see

```python
import os                                    # bind `os` to the whole module
from OpenGL.GL import glClear, glClearColor  # bind selected names directly
import numpy as np                           # rename to a shorter alias
```

`import os` lets you write `os.environ`, `os.path.exists(...)`, etc.

`from X import Y` makes `Y` a top-level name in your file. We do this with the
GL functions because there are dozens of them and writing
`OpenGL.GL.glDrawArrays(...)` everywhere would be unbearable.

`import numpy as np` is a convention. The whole numerical Python community
calls it `np`.

### Why some imports come AFTER module-level code

Look at `app.py`:

```python
import os, signal, sys              # standard library

signal.signal(...)                  # configure SIGINT
if "QT_QPA_PLATFORM" not in ...:    # configure environment
    ...

import ctypes, math                 # more standard library
import numpy as np                  # third-party
from OpenGL.GL import (...)         # third-party
from PySide6.QtCore import ...      # third-party
```

Importing `PySide6` triggers Qt's library to load. Qt reads
`QT_QPA_PLATFORM` and `WAYLAND_DISPLAY` *at import time* to decide which
platform plugin to use. So the env-var setup has to happen **before** PySide6
is imported, which is why those imports are split.

This is unusual — most projects put all imports at the top. The comment in the
code explains why this one doesn't.

## 2. Constants and the UPPERCASE convention

Python has no real "constants" (you can reassign anything). The convention is
that uppercase names are treated as constants by readers:

```python
AXIS_LEN = 1.0
LINE_WIDTH_PX = 7.5
COLOR_X = (1.00, 0.30, 0.30, 1.00)
G_MS2 = 9.80665
```

If you see uppercase, assume the value is set once and never changed at
runtime. If you see lowercase, assume it's mutable.

## 3. Type hints

Function signatures often look like:

```python
def _read_float(path: str) -> float:
    ...
```

The `path: str` means "this argument is expected to be a string." The
`-> float` means "this function is expected to return a float."

**Python doesn't enforce these.** They're notes for humans (and tools like
mypy or your IDE). At runtime, you can pass anything.

You'll see various forms:

```python
def f(x: int) -> int                                     # one arg
def g(name: str, count: int = 5) -> None                 # default value
def h(items: list[float]) -> tuple[float, float]         # collections
def k(x: float | None) -> tuple[float, float] | None     # union / optional
```

`tuple[float, float]` means "a 2-tuple of floats." The `| None` forms (read as
"or None") indicate a value that might be missing — `_world_to_screen`
returns `tuple[float, float] | None` because a 3D point behind the camera
has no screen position.

## 4. Tuples and tuple unpacking

A **tuple** is a fixed-size, immutable sequence:

```python
COLOR_X = (1.00, 0.30, 0.30, 1.00)
center = (1.0, 0.0, 0.0)
```

You can pull values out by **unpacking**:

```python
gx, gy, gz = self._reader.read_g()           # 3-element tuple → 3 names
r, g, b, a = COLOR_X                          # 4-element tuple → 4 names
```

The number of names on the left must match the tuple's length. If the function
returns three values, write three names.

### Star unpacking

The `*color` form expands a tuple into individual values:

```python
COLOR_X = (1.00, 0.30, 0.30, 1.00)
verts = [0.0, 0.0, 0.0, *COLOR_X, 0.0]
# becomes:
# [0.0, 0.0, 0.0, 1.00, 0.30, 0.30, 1.00, 0.0]
```

We use this constantly in the geometry code to splat (x, y, z) and (r, g, b, a)
into a flat list of floats.

The same syntax works in function calls:

```python
glClearColor(*BG_COLOR)
# is equivalent to:
glClearColor(BG_COLOR[0], BG_COLOR[1], BG_COLOR[2], BG_COLOR[3])
```

## 5. f-strings

`f"..."` is an **f-string** — a string with embedded expressions. Used heavily
for logging:

```python
print(f"GL_VENDOR:   {glGetString(GL_VENDOR).decode()}")
print(f"G: x={gx:+.2f} y={gy:+.2f} z={gz:+.2f}")
```

Anything inside `{...}` is a Python expression; its result is converted to a
string and inserted.

The `:+.2f` format spec controls how the number is rendered:

- `+` always show the sign
- `.2` two decimal places
- `f` fixed-point format

So `+1.23456` becomes `"+1.23"`, and `-0.001` becomes `"-0.00"`.
Other format specs you'll see in the code:

- `:+5.2f` — sign, minimum 5 chars wide, 2 decimals → `"+1.23"` or `" -0.50"`
- `:+7.1f` — sign, 7 chars wide, 1 decimal → `"  +12.3"`
- `:.6e` — scientific notation, 6 decimals → `"5.985000e-04"`
- `{e!r}` — repr() of the value (debugging-friendly form)

## 6. Lists, list comprehensions, generator expressions

A list:

```python
out = []
out.append(1.0)
out.extend([2.0, 3.0])         # add multiple items
```

A **list comprehension** builds a list in one line:

```python
rim = [base_center + radius * (np.cos(a) * u + np.sin(a) * v) for a in angles]
# equivalent to:
rim = []
for a in angles:
    rim.append(base_center + radius * (np.cos(a) * u + np.sin(a) * v))
```

A **generator expression** is the same syntax with parentheses, but produces
values lazily one at a time instead of building a full list:

```python
gx, gy, gz = (
    _read_float(p) * self._accel_scale / G_MS2 for p in self._accel_paths
)
```

In this case, the three values are pulled out by tuple-unpacking on the left,
so we never materialize a list.

## 7. Classes — the bare minimum

A **class** groups data and functions that operate on it:

```python
class ImuReader:
    """Read MPU6050 accel (G) + gyro (deg/s) from IIO sysfs."""

    def __init__(self, sysfs_dir: str = SYSFS_IIO) -> None:
        self._accel_paths = ...
        self._accel_scale = _read_float(...)

    def read_g(self) -> tuple[float, float, float]:
        ...
```

Pieces to recognize:

- `class ImuReader:` declares a class (a template for objects).
- `__init__` is the **constructor**. It runs when you do `ImuReader()`.
- `self` is the conventional name for "this object" — every method's first
  argument is `self`, even though you don't pass it explicitly when calling.
- `self._accel_paths = ...` stores data on the object. You can later read it
  back as `self._accel_paths`.
- The leading underscore (`_accel_paths`) is a **convention for "private."**
  Python doesn't enforce it; it's just a hint to readers that "this is
  internal to the class, don't poke at it from outside."

Calling code:

```python
reader = ImuReader()                  # __init__ runs
g = reader.read_g()                   # method call; self = reader
# ImuReader.read_g(reader) would do the same thing.
```

### Inheritance and `super()`

A class can extend another:

```python
class AxisScene(QOpenGLWidget):
    def __init__(self):
        super().__init__()       # call the parent's __init__ first
        self._program = 0
        ...
```

`AxisScene` inherits everything `QOpenGLWidget` has — that's how we get the
ability to render OpenGL inside a Qt window. `super().__init__()` runs the
parent's setup so the widget is properly initialized before we add our own
state.

You'll see other parent methods we override (`initializeGL`, `paintGL`,
`resizeGL`, `keyPressEvent`). These are Qt's "callback" methods — Qt calls
them; we don't.

## 8. File I/O

Reading a file:

```python
def _read_float(path: str) -> float:
    with open(path) as f:
        return float(f.read().strip())
```

- `open(path)` opens the file for reading (default mode).
- `with ... as f:` is a **context manager**: when the block exits (normally or
  via an exception), the file is automatically closed.
- `f.read()` reads the entire content as a string.
- `.strip()` removes leading/trailing whitespace (newlines, spaces).
- `float(...)` converts the string to a number.

This is how we read sysfs files like `/sys/bus/iio/devices/iio:device1/in_accel_x_raw`.

## 9. Exceptions

Code that might fail can be wrapped:

```python
try:
    new_g = self._reader.read_g()
    new_gyro = self._reader.read_gyro_dps()
except OSError as e:
    self._read_errors += 1
    if self._read_errors == 1 or self._read_errors % 50 == 0:
        print(f"[warn] sensor read failed: {e!r}")
    self.update()
    return
```

If a `read_g()` call raises an `OSError` (kernel returned an error, file
disappeared, etc.), control jumps to the `except` block. `e` is the exception
object; `e!r` formats it with its full debug representation.

This is how we made the demo robust to flaky I2C wiring — a bad read warns
once and the app keeps running on the previous good values.

`raise` does the opposite — fires off an exception:

```python
if not glGetShaderiv(sid, GL_COMPILE_STATUS):
    log = glGetShaderInfoLog(sid).decode()
    glDeleteShader(sid)
    raise RuntimeError(f"shader compile failed: {log}")
```

`RuntimeError` is a generic "something went wrong" exception. Caller code
that doesn't catch it gets a traceback and a stopped program, which is
appropriate at startup time.

## 10. The `if __name__ == "__main__":` idiom

The very last lines of `app.py`:

```python
if __name__ == "__main__":
    sys.exit(main())
```

Every Python file has an automatic variable `__name__`. When you run
`python3 app.py`, that file's `__name__` is the string `"__main__"`. When some
*other* file does `import app`, that file's `__name__` becomes `"app"`.

The idiom means: "only call `main()` if this file was the program that was
launched directly." It's a polite gesture so that anyone importing
[app.py](../app.py) for inspection doesn't accidentally start the GUI.

`sys.exit(rc)` exits the program with return code `rc`. Standard Unix:
0 = success, non-zero = failure. We pass through whatever `main()` returns
(which is whatever Qt's `app.exec()` returns).

## 11. NumPy in 60 seconds

NumPy (`np`) provides fast numerical arrays and matrix math.

A 1D array of floats:

```python
AXIS_LINE_VERTICES = np.array([0.0, 0.0, 0.0, 1.0, 0.3, 0.3, 1.0, 0.0],
                              dtype=np.float32)
```

`dtype=np.float32` matters: OpenGL expects 32-bit floats. Without specifying,
NumPy would default to 64-bit floats (`float64`), which the GPU can't directly
consume.

A 2D array (matrix):

```python
M = np.array(
    [
        [f / aspect, 0.0, 0.0, 0.0],
        [0.0,        f,   0.0, 0.0],
        ...
    ],
    dtype=np.float32,
)
```

Useful operations you'll see:

- `np.cross(a, b)` — vector cross product (returns 3-vector)
- `np.dot(a, b)` — vector dot product (returns scalar)
- `np.linalg.norm(v)` — vector length
- `np.linspace(0, 2*pi, 16, endpoint=False)` — 16 evenly-spaced values
- `np.cos(arr)`, `np.sin(arr)` — element-wise trig
- `M @ N` — matrix multiplication (yes, `@` is a Python operator for this)
- `arr.astype(np.float32)` — convert array to a different dtype
- `arr.size`, `arr.shape`, `arr.nbytes`, `arr.itemsize` — metadata
- `arr.tobytes()`, passing arrays to GL functions — they're just contiguous
  memory under the hood

A few things that trip beginners up:

- `np.cross(a, b)` requires both arguments to be length 3 (or, for 2D, 2).
- `arr / scalar` divides every element by the scalar (broadcast).
- Matrix-vector: `M @ v` requires shapes to match. A 4×4 matrix times a
  4-vector returns a 4-vector.

## 12. Common formatters / patterns to remember

| Pattern | What it does |
|---|---|
| `f"{x:+.2f}"` | Number with sign, 2 decimals |
| `f"{path!r}"` | `repr(path)` — debug-readable form |
| `*tup` in a list | Splatting tuple into a flat list |
| `list[float]` | Type hint: list of floats |
| `tuple[float, float, float]` | Type hint: 3-tuple of floats |
| `... | None` | Type hint: this value or None |
| `with open(p) as f:` | Auto-close file on block exit |
| `try / except OSError as e:` | Catch I/O errors |
| `super().__init__()` | Initialize the parent class |
| `if __name__ == "__main__":` | Run only when launched directly |

## 13. What you do NOT need for this project

- `async`/`await` (we don't use it)
- Decorators beyond `@property`-style ones (we don't define custom ones)
- Generators with `yield` (only generator *expressions*)
- Metaclasses, descriptors, `__slots__`
- `dataclasses` or `attrs`

If a Python tutorial dwells on those, skip them — they don't appear in this
demo.
