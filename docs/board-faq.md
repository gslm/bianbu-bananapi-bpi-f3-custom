# Board FAQ

This document collects practical hardware notes for the current Banana Pi
BPI-F3 bring-up baseline, especially around displays, touch input, and USB
peripherals.

## HDMI Touch Displays

### Why does the display show video, but touch does not work on the board?

Because `HDMI` and `USB` serve different roles:

- `HDMI` carries video only
- `USB` carries touch data
- `USB` often also powers the display

If the panel's USB cable is connected to the development machine instead of the
board, the touch controller enumerates on the development machine and touch
events are delivered there, not to the BPI-F3.

Validated symptom from this project:

- the board displayed LXQt correctly over HDMI
- touch gestures selected text in the serial terminal on the dev machine
- the board itself showed no touchscreen device in `libinput list-devices`

### Correct wiring for an HDMI touch display

Recommended connection model:

- board `HDMI` to display `HDMI` for video
- display `USB` to board `USB` for touch data

If the display needs more power than the board can comfortably provide, use an
external `5V` supply for power, but still keep a USB data path between the
display and the board. Power alone is not enough for touch.

### How do I verify that touch is connected to the board?

Run on the board:

```bash
lsusb
libinput list-devices
```

If the touchscreen is wired correctly, a new USB/input device should appear.
If only the power key and headset jack are listed, the board is not receiving
touch input.

## USB Cameras

### Why does the camera path keep changing?

Raw `/dev/videoN` numbers are not stable. The camera can re-enumerate and come
back as a different device number after reconnects or bus resets.

Use the stable symlink under `/dev/v4l/by-id/` instead. For the currently
validated webcam in this project:

```bash
/dev/v4l/by-id/usb-Xiongmai_web_camera_12345678-video-index0
```

Use `video-index0` for the image stream. `video-index1` is metadata, not the
main preview stream.

### Why does the USB camera sometimes freeze or disappear?

The errors we observed were consistent with USB link or power instability, not
with an `ffplay` problem. Typical symptoms included:

- `VIDIOC_DQBUF: No such device`
- `usb_set_interface failed (-71)`
- `can't set config #1, error -71`

When those appear, check cable quality, power, hub topology, and whether the
camera is sharing an unstable USB path.
