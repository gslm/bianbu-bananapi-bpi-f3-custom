# 03 — OpenGL ES Concepts

This document covers the OpenGL ES 3.0 concepts the demo needs. OpenGL is a
big, decades-old API; we use a small modern subset. Read this if `paintGL` and
the shaders look like an alien language.

If you're already comfortable with modern OpenGL, you can skim this and go
straight to the walkthrough.

## 1. The big picture

A GPU is a chip with thousands of small parallel cores, designed to crunch
huge numbers of similar operations. OpenGL is the API you use to tell the GPU
what to draw and how.

A typical render flow looks like:

```text
        ┌──────────────────────────────────────────┐
CPU:    │  Build vertex data (Python / NumPy)      │
        │  Upload to GPU memory (VBO)              │
        │  Set uniforms (matrices, sensor values)  │
        │  Issue glDrawArrays                      │
        └────────────────────────┬─────────────────┘
                                 │
        ┌────────────────────────▼─────────────────┐
GPU:    │  For each vertex:                        │
        │    run vertex shader → clip-space pos    │
        │  Connect vertices into primitives        │
        │  Rasterize (fill in pixels)              │
        │  For each pixel:                         │
        │    run fragment shader → color           │
        │  Test against depth buffer / blend       │
        │  Write to framebuffer                    │
        └──────────────────────────────────────────┘
                                 │
                                 ▼
                            Pixels on the panel
```

Two of those steps run *programs* you wrote: the **vertex shader** and the
**fragment shader**. The rest is fixed-function (configurable but not
programmable).

## 2. OpenGL ES 3.0 vs desktop OpenGL

OpenGL ES is a stripped-down OpenGL meant for embedded systems (phones,
tablets, game consoles, embedded SoCs like the K1 here). It has:

- The same shader language (GLSL) but fewer features
- A smaller API surface
- No legacy "fixed function" pipeline (you must write shaders)

GLSL ES 3.00 (the version we target) is roughly equivalent to desktop GLSL
1.30. The `#version 300 es` line at the top of our shaders selects it.

On Bianbu's PowerVR driver:

- We get OpenGL ES 3.2 in practice (which is backwards-compatible with 3.0).
- Desktop OpenGL is not available — only ES.
- We must NOT use `PySide6.QtOpenGL` because that module references
  desktop-GL-only classes that the Bianbu Qt build doesn't export. We use
  PyOpenGL instead for direct GL function calls.

## 3. Coordinate spaces

A 3D point in your world goes through several coordinate-system conversions
before becoming a pixel:

```
World space ──(model matrix)──► World ──(view matrix)──► View ──(projection)──► Clip
                                                                                  │
                                                                          (perspective ÷)
                                                                                  │
                                                                                  ▼
                                                                         NDC ([-1,+1]³)
                                                                                  │
                                                                          (viewport)
                                                                                  │
                                                                                  ▼
                                                                         Screen pixels
```

What each space means:

- **Model space** — coordinates "as the object thinks of itself". For a
  standalone scene like ours, model space and world space are the same.
- **World space** — the global 3D coordinate system. For us, +Z is up, the
  origin is at the centre of the scene, units are "G" (1.0 world unit = 1G).
- **View space** — the world re-expressed relative to the camera. Achieved
  with the *view matrix*. Camera sits at origin in view space, looking down
  -Z.
- **Clip space** — what the projection produces. In clip space, anything with
  `|x| < w`, `|y| < w`, `|z| < w` is visible.
- **NDC (Normalized Device Coordinates)** — clip space divided by `w`.
  Visible region is `[-1, +1]` in x, y, z.
- **Screen space** — NDC mapped onto the pixel grid via the viewport.

You don't need to manipulate every space yourself. You build a single matrix
that bakes them all together — the **MVP matrix**.

## 4. The MVP matrix

```text
MVP = Projection × View × Model
```

In `app.py`:

```python
mvp = (self._proj @ self._view @ self._model).astype(np.float32)
```

- `self._model` — identity (no per-object transform)
- `self._view` — built once at init via `_look_at(eye, target, up)`. Encodes
  "camera at (2.5, 2.5, 2.5), looking at origin, with +Z up."
- `self._proj` — built every resize via `_perspective(fov, aspect, near, far)`.
  Encodes the field-of-view and aspect ratio.

In the vertex shader we write:

```glsl
gl_Position = u_mvp * vec4(pos, 1.0);
```

This applies all three transforms in one matrix-vector multiplication.

### Why column-major and the `transpose=GL_TRUE` trick

GPUs convention treats matrices as **column-major** in memory: if you write
out a 4×4 matrix in C as `float m[16]`, slot `m[0]` is the top-left, `m[1]`
is the *second row of column 0*, not "row 0 column 1". The 4×4 looks like:

```
m[ 0]  m[ 4]  m[ 8]  m[12]
m[ 1]  m[ 5]  m[ 9]  m[13]
m[ 2]  m[ 6]  m[10]  m[14]
m[ 3]  m[ 7]  m[11]  m[15]
```

NumPy uses **row-major** by default. When you flatten `np.array([[1,2,3,4],
[5,6,7,8], ...])`, you get `[1,2,3,4,5,6,7,8,...]` — adjacent elements are
along rows, not columns.

If you upload a NumPy matrix to GL without transposing, the GPU reads it
backwards (rows interpreted as columns). The fix:

```python
glUniformMatrix4fv(self._mvp_loc, 1, GL_TRUE, mvp)
                                       ^^^^^^^
                                       transpose=GL_TRUE
```

`GL_TRUE` tells GL "transpose this for me on the way in." After upload, the
shader sees a correct column-major matrix; the math works.

You'll occasionally see code build matrices column-major in NumPy directly,
but `GL_TRUE` is the typical Python-side approach.

### `_perspective` and `_look_at` — one-page summary

Both functions are pure math. `_perspective` builds:

```
[ f/aspect    0       0           0       ]
[    0        f       0           0       ]
[    0        0  (far+near)/(near-far)  (2·far·near)/(near-far) ]
[    0        0      -1           0       ]
```

where `f = 1 / tan(fov/2)`. The bottom-right `0` and bottom row's `-1` is
what gives perspective division (objects further from camera appear smaller).

`_look_at` builds an orthonormal basis from the eye / target / up vectors,
then negates eye position to produce the view matrix. The result effectively
moves the world so the camera sits at origin looking down -Z.

You don't need to memorize either; just trust them. They're textbook
implementations.

## 5. VBOs and vertex attributes

A **VBO** (Vertex Buffer Object) is a chunk of GPU memory holding per-vertex
data — positions, colors, anything else.

Our vertex layout: every vertex is **8 floats**:

```
[ x, y, z,    r, g, b, a,    axis_idx ]
   |          |              |
   position   color (RGBA)   axis index (0/1/2 = scaled, -1 = static)
```

These are interleaved (position, color, axis_idx, position, color, axis_idx,
…), packed into one big NumPy array. Then uploaded once with
`glBufferData`:

```python
self._vbo = int(glGenBuffers(1))           # ask GPU for a buffer ID
glBindBuffer(GL_ARRAY_BUFFER, self._vbo)   # make it the "current" buffer
glBufferData(GL_ARRAY_BUFFER, ...)         # upload data into it
```

### Vertex attribute pointers — telling GL the layout

After uploading raw bytes, we tell GL how to interpret them. For each shader
attribute (location 0, 1, 2…), we describe stride + offset within each vertex:

```python
glEnableVertexAttribArray(0)
glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, VERTEX_STRIDE, ctypes.c_void_p(0))
glEnableVertexAttribArray(1)
glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, VERTEX_STRIDE, ctypes.c_void_p(COLOR_OFFSET))
glEnableVertexAttribArray(2)
glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, VERTEX_STRIDE, ctypes.c_void_p(AXIS_OFFSET))
```

The arguments to `glVertexAttribPointer(location, size, type, normalize, stride, offset)`:

- `location` — the attribute slot in the shader (we use 0 for position, 1 for
  color, 2 for axis_idx; matched by `layout(location = 0)` etc. in GLSL).
- `size` — number of components (3 for xyz, 4 for rgba, 1 for axis_idx).
- `type` — `GL_FLOAT` (32-bit float).
- `normalize` — if true, integer values get auto-mapped to [0, 1]. Always
  `GL_FALSE` for us since we use raw floats.
- `stride` — bytes between consecutive vertices (8 floats × 4 bytes = 32).
- `offset` — bytes from the start of each vertex to where this attribute
  begins. Wrapped in `ctypes.c_void_p` because GL expects a pointer-typed
  argument.

```
Vertex N stride = 32 bytes
       offset 0          offset 12          offset 28
       │                 │                  │
       ▼                 ▼                  ▼
       [ x  y  z ] [ r  g  b  a ] [ axis_idx ]
       <position>   <color>        <axis_idx>
       3 floats    4 floats         1 float
       12 bytes    16 bytes         4 bytes
```

## 6. VAOs

A **VAO** (Vertex Array Object) is a tiny GPU object that *records* the
attribute pointer state. After you set up your attribute pointers once, you
bind the VAO before drawing to "replay" them — much faster than reconfiguring
every frame.

```python
self._vao = int(glGenVertexArrays(1))
glBindVertexArray(self._vao)
# ... configure VBO and attribute pointers (now captured by the VAO) ...
glBindVertexArray(0)

# Later, in paintGL:
glBindVertexArray(self._vao)
glDrawArrays(...)
```

You set up the VAO once in `initializeGL`; from then on, paintGL just binds
it and draws.

## 7. Uniforms vs attributes

Two different ways to pass data into shaders:

| Concept | What it is | Per-vertex? | Examples in our code |
|---|---|---|---|
| **Attribute** | Stream of values, one per vertex | yes | position, color, axis_idx |
| **Uniform** | Single value shared by all vertices/fragments in one draw | no | MVP matrix, current G readings |

Attributes come from the VBO. Uniforms are set with `glUniform*` calls just
before `glDrawArrays`:

```python
glUniformMatrix4fv(self._mvp_loc, 1, GL_TRUE, mvp)   # 4×4 matrix
glUniform3f(self._g_loc, *self._last_g)               # vec3
```

`self._mvp_loc` and `self._g_loc` are the uniform's *location* in the
linked program — looked up once with `glGetUniformLocation(program, "u_mvp")`.

## 8. Shaders — GLSL ES 3.00 in 5 minutes

A shader is a small program written in **GLSL** (OpenGL Shading Language).
Like C, but with built-in vector and matrix types.

Our vertex shader:

```glsl
#version 300 es
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
```

Line by line:

- `#version 300 es` — GLSL ES 3.00.
- `precision highp float;` — default precision for floats. ES requires you to
  specify (desktop GL doesn't).
- `in vec3 a_pos;` — input attribute, vector of 3 floats. Matches what we
  upload via `glVertexAttribPointer(0, 3, ...)`.
- `uniform mat4 u_mvp;` — uniform 4×4 matrix.
- `out vec4 v_color;` — output passed to the fragment shader.
- `void main() { ... }` — the entry point. Runs once per vertex.
- `gl_Position` — magic built-in: where this vertex ends up in clip space.
  Required output of the vertex shader.

Notable GLSL features used:

- Component access on vectors: `pos.x`, `u_g.y`, `pos.xyz`, etc.
- Constructors: `vec4(pos, 1.0)` builds a vec4 from a vec3 and a scalar.
- Matrix-vector multiplication: `u_mvp * vec4(pos, 1.0)`.

Our fragment shader is even simpler:

```glsl
#version 300 es
precision mediump float;
in vec4 v_color;
out vec4 fragColor;
void main() {
    fragColor = v_color;
}
```

It runs once per pixel inside each primitive. It receives the
linearly-interpolated `v_color` (Qt does the interpolation for free between
vertices) and writes it directly to the output. No lighting, no texture, no
math.

`mediump` is enough for color — saves GPU power on embedded chips. Vertex
shader uses `highp` because position math needs precision.

### Compile / link cycle

A shader is text → bytes via:

```python
sid = glCreateShader(GL_VERTEX_SHADER)        # get an ID for a shader slot
glShaderSource(sid, source)                    # give it the source code
glCompileShader(sid)                           # compile (driver-specific)
if not glGetShaderiv(sid, GL_COMPILE_STATUS):
    log = glGetShaderInfoLog(sid).decode()
    raise RuntimeError(f"shader compile failed: {log}")
```

Then a *program* is two shaders linked together:

```python
pid = glCreateProgram()
glAttachShader(pid, vs)
glAttachShader(pid, fs)
glLinkProgram(pid)
# then check GL_LINK_STATUS the same way
```

Once linked, the individual shader IDs can be deleted (program holds
references):

```python
glDeleteShader(vs)
glDeleteShader(fs)
```

## 9. Primitive types

`glDrawArrays(MODE, first, count)` tells GL "interpret the next `count`
vertices starting at index `first` as primitives of type MODE." The two
modes we use:

- `GL_LINES` — every two consecutive vertices form an independent line
  segment. So 6 vertices = 3 lines.
- `GL_TRIANGLES` — every three consecutive vertices form an independent
  triangle. So 96 vertices = 32 triangles.

Other primitives exist (`GL_LINE_STRIP`, `GL_TRIANGLE_FAN`, etc.) but we don't
use them.

## 10. Depth testing

When two pieces of geometry overlap in the same pixel, who wins? Usually:
whichever is closer to the camera. The **depth buffer** stores the depth of
each pixel; before drawing, GL compares the incoming pixel's depth against
the stored depth and discards it if it's behind.

Two state pieces:

```python
glEnable(GL_DEPTH_TEST)        # enable the test (we do this in initializeGL)
glDepthMask(GL_TRUE / GL_FALSE) # whether successful tests update the buffer
```

With **GL_TRUE** (the default), passing pixels both render *and* update the
depth buffer. With **GL_FALSE**, they render but don't update — useful for
transparent geometry that shouldn't occlude what comes next.

In `paintGL`:

```python
# Opaque pass — write depth
glDrawArrays(...)   # axis lines, arrows, gyro arcs

# Transparent pass — DON'T write depth
glEnable(GL_BLEND)
glDepthMask(GL_FALSE)
glDrawArrays(...)   # grid lines
glDepthMask(GL_TRUE)
glDisable(GL_BLEND)
```

This ordering ensures grid lines:

- Pass the depth test (so they're occluded by closer opaque axes).
- Don't write to the depth buffer (so they don't occlude each other based on
  draw order).

`glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)` at the start of each
frame resets both buffers.

## 11. Alpha blending

Solid objects ignore the framebuffer's existing color and overwrite it.
Transparent objects need to *blend*: their color combines with what's already
there.

GL's blending equation:

```
output = src_factor * src_color + dst_factor * dst_color
```

We use the standard "alpha over" blend:

```python
glEnable(GL_BLEND)
glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
```

Which expands to:

```
output = src_alpha * src_color + (1 - src_alpha) * dst_color
```

A grid line with alpha = 0.12 mostly preserves what's behind it, contributing
just a bit of cool-white tint.

When you're done with transparent geometry, `glDisable(GL_BLEND)` so
subsequent draws don't accidentally blend.

## 12. Line width

`glLineWidth(N)` sets the width in pixels of subsequent line draws. ES only
guarantees width 1.0 is supported; many drivers support more. The PowerVR
driver here supports up to 16.0 (we query and print this at startup).

We change line width between draw calls:

```python
glLineWidth(LINE_WIDTH_PX)         # 7.5 — thick axis lines
glDrawArrays(GL_LINES, 0, ...)      # axes
glLineWidth(GYRO_LINE_WIDTH_PX)     # 5.0 — medium gyro arcs
glDrawArrays(GL_LINES, ...)
glLineWidth(GRID_LINE_WIDTH_PX)     # 1.0 — thin grid
glDrawArrays(GL_LINES, ...)
```

## 13. Clear color, viewport

```python
glClearColor(0.06, 0.07, 0.10, 1.0)  # background dark blue-grey
glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
```

`glClearColor` sets the color used by `glClear` to fill the framebuffer.
Called once in `initializeGL`; affects every frame.

```python
glViewport(0, 0, w, h)
```

Tells GL "draw into pixels (0, 0) to (w, h) of the framebuffer." Set in
`resizeGL` whenever the widget is resized.

## 14. Streaming dynamic geometry — `glBufferSubData`

Static geometry (axes, arrows, grid) lives in the VBO untouched. The gyro
arcs change every frame as ω varies. For dynamic data, we use `glBufferSubData`
to update only a region of the VBO:

```python
# Reserve extra space at end of VBO at init time:
glBufferData(GL_ARRAY_BUFFER, ALL_VERTICES.nbytes + GYRO_RESERVE_BYTES, None, GL_DYNAMIC_DRAW)
glBufferSubData(GL_ARRAY_BUFFER, 0, ALL_VERTICES.nbytes, ALL_VERTICES)

# Each frame, update just the gyro region:
glBufferSubData(GL_ARRAY_BUFFER, GYRO_OFFSET_BYTES, gyro_data.nbytes, gyro_data)
```

`GL_DYNAMIC_DRAW` is a hint that the buffer will be re-uploaded often; the
driver may pick a different memory location accordingly. The hint is purely
advisory — it doesn't change correctness.

## 15. The render order in paintGL — why this sequence

The `paintGL` function does these in order:

1. `glClear` — wipe the frame and depth buffer.
2. Build MVP matrix and gyro geometry.
3. `glUseProgram` — activate our compiled program.
4. Set uniforms (MVP, current G).
5. `glBindVertexArray` — restore attribute layout.
6. **Opaque pass** — depth-write on, blend off:
   - axis lines
   - arrowhead cones
   - gyro arcs
7. **Transparent pass** — depth-write off, blend on:
   - grid lines
8. Restore state (blend off, depth-write on).
9. `_draw_overlay()` — QPainter for HUD and tick labels.

Why opaque first? They write the depth buffer, so transparent things drawn
later are correctly occluded by them.

Why grid in transparent pass? Grid alpha = 0.12 — without blending, those
lines would be almost-invisible nearly-white instead of barely-tinted. With
depth-write off, the grid lines on the (Z=0) XY plane don't fight with grid
lines on (X=0) YZ plane that pass through the same screen pixel.

## 16. Common gotchas

- **Forgetting `dtype=np.float32` on a NumPy array passed to GL**. The driver
  silently misinterprets the data as garbage.
- **Forgetting `transpose=GL_TRUE` when uploading a NumPy matrix**. Geometry
  appears transposed (and very weird).
- **Setting attribute pointers without binding the VAO first**. The state
  isn't captured; the next draw uses unrelated state.
- **Forgetting to enable an attribute** with `glEnableVertexAttribArray(N)`.
  The shader receives garbage for that attribute.
- **Drawing transparent objects with depth-write on**. They occlude each
  other based on draw order, which is rarely what you want.
- **Running `paintGL` outside `initializeGL`'s GL context lifetime**. (Doesn't
  apply to us — Qt manages contexts correctly.)

## 17. Reference: every GL function used in `app.py`

| Function | What it does |
|---|---|
| `glGetString` | Get a string (GL_VENDOR/RENDERER/VERSION) |
| `glGetFloatv` | Get a float-valued state (line width range, etc.) |
| `glClearColor` | Set the color used by glClear |
| `glClear` | Fill the framebuffer / depth buffer with the clear values |
| `glEnable` / `glDisable` | Toggle a state (DEPTH_TEST, BLEND) |
| `glBlendFunc` | Configure how src/dst colors combine |
| `glDepthMask` | Toggle whether depth writes are allowed |
| `glLineWidth` | Set pixel width of subsequent line draws |
| `glViewport` | Set the pixel rectangle to draw into |
| `glCreateShader` / `glShaderSource` / `glCompileShader` | Build a shader from source |
| `glGetShaderiv` / `glGetShaderInfoLog` | Inspect a shader's compile status |
| `glDeleteShader` | Free a shader after linking |
| `glCreateProgram` / `glAttachShader` / `glLinkProgram` | Build a program from shaders |
| `glGetProgramiv` / `glGetProgramInfoLog` | Inspect a program's link status |
| `glUseProgram` | Activate a program (its shaders run on subsequent draws) |
| `glGetUniformLocation` | Look up a uniform's index in a program |
| `glUniformMatrix4fv` | Set a 4×4 matrix uniform |
| `glUniform3f` | Set a vec3 uniform from three floats |
| `glGenVertexArrays` / `glBindVertexArray` | Create / activate a VAO |
| `glGenBuffers` / `glBindBuffer` | Create / activate a VBO |
| `glBufferData` | Allocate / upload to a buffer |
| `glBufferSubData` | Update a sub-range of an existing buffer |
| `glEnableVertexAttribArray` | Enable a vertex attribute |
| `glVertexAttribPointer` | Describe the layout of a vertex attribute |
| `glDrawArrays` | Draw N vertices as the given primitive |
