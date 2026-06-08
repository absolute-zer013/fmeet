# EMEET PIXY (328f:00c0) — HID Control Protocol

Reverse-engineered for Linux, confirmed against a **labeled** EMEET Studio
capture (Winboat + usbmon). Two control surfaces:

- **HID interface 4** (32-byte interrupt reports, EP4 IN / EP1 OUT) — proprietary
  commands (PTZ, tracking, modes, audio, privacy timer, feature toggles).
- **UVC** standard processing/camera units + vendor XU — all image quality,
  zoom, exposure, focus, white balance (see UVC section).

Built on PixyBar (RoseWaveStudio, MIT), extended and verified here.

## Frame format (HID)

```
byte 0     0x09         HID Report ID (from the report descriptor — not a magic constant)
byte 1     group        response echoes group OR'd with 0x60
byte 2     channel      0x00 system, 0x01 main/gimbal, 0x02 AI-cam/async
byte 3     sub          sub-command
byte 4     0x00
bytes 5-6  length       total payload length, little-endian u16
byte 7     chunk        payload bytes in this report (multi-report if < length)
bytes 8+   payload
```
Status byte `0x20` = OK, `0x40` = rejected. Floats are LE f32, **degrees** for motors.

## CONFIRMED commands (from labeled capture)

### Mode — group 0x01
| Frame | Meaning | Payload |
|---|---|---|
| `09 01 01 00` | SET camera mode | u8: 0 standard, 1 tracking, 2 privacy, 3 startup |
| `09 01 01 01` | GET mode | resp byte 8 = mode |
| `09 01 00 03` | GET serial | ASCII string |

Setting mode 2 (privacy) triggers async `09 02 00 02` = 3; back to standard -> 0.

### Audio mode — group 0x05, channel 0  [NEW]
| Frame | Meaning | Payload |
|---|---|---|
| `09 05 00 03` | SET audio mode | u8: 1 Live, 2 Noise-Canceling, 3 Original |
| `09 05 00 04` | GET audio mode | resp u8 |

### Privacy auto-timer — group 0x02, channel 1
| Frame | Meaning | Payload |
|---|---|---|
| `09 02 01 00` | SET auto-privacy timeout | u32 sec: 10, 60, 900, **0 = Never** |
| `09 02 01 01` | GET auto-privacy timeout | resp u32 |
| `09 02 00 02` | (async) privacy state push | u8 (3 active / 0 off) |

### Tracking / Focus-Metering — group 0x04
| Frame | Meaning | Payload |
|---|---|---|
| `09 04 00 01` | SET focus-metering mode | u8 + f32; 0 central, 1 face, 2 selected-area |
| `09 04 00 02` | GET focus-metering | resp u8 + f32 |
| `09 04 00 03` | SET (paired w/ 01, same value) | u8 + f32 |
| `09 04 01 00` | SET tracking target | u8 track + 5xf32 |
| `09 04 01 01` | GET tracking | resp u8 + 5xf32 (live subject coords) |
| `09 04 02 00` | SET **gesture control** on/off | `02` + u8 (0/1) |
| `09 04 02 01` | GET gesture control | `02` -> resp `02, value` |

**Focus-metering = the 3-way "Focus/Metering" buttons** (central / face /
selected area), driven by `09 04 00 01`+`03` paired with the same value. The
`09 04` group is mislabeled "tracking" by the sniffer; byte 2 + sub disambiguate.

### Feature toggles — group 0x04, channel 0, sub 0x07/0x08  [MAPPED]
GET `09 04 00 07 <id>` -> `id, value`   ·   SET `09 04 00 08 <id> <value>`

| Feature ID | Meaning |
|---|---|
| `0x01` | **Flip vertical** |
| `0x02` | **Flip horizontal** |
| `0x04` | **Auto-rotate when upside down** (also emits async `09 63 02 01`) |

(IDs `0x0a/0x0c/0x0e` read 0 and weren't tied to a label — likely reserved;
revisit only if a feature is still missing.)

### Motor / PTZ — group 0x03
| Frame | Meaning | Payload |
|---|---|---|
| `09 03 01 18` | Motor ABSOLUTE | u8 axis (1 pan, 2 tilt) + f32 deg |
| `09 03 01 19` | Motor RELATIVE | u8 axis + f32 delta deg — **never moved the gimbal on hardware; abandoned** |
| `09 63 01 20` | **velocity stream (knob/joystick)** | f32 pan_vel + f32 tilt_vel + 0x4 |
| `09 03 01 14` | **GET live position** | u8 + f32 pan + f32 tilt |
| `09 03 01 16` | preset slot read/write | u8 slot + f32 pan + f32 tilt |
| `09 03 01 17` | preset/motor status | resp u8 |
| `09 03 01 00` | abs-axis variant | u8 axis + f32 (saw tilt -45) |

`09 63 01 20` is specifically the **on-screen knob** (velocity vectors, ~+/-30
deg/s, zero-vector to stop). It is the ONLY motion primitive that actually moves
the gimbal on hardware, so **arrow buttons drive a timed velocity pulse on this
channel** (drive at a fixed speed for `step° / speed` seconds, then stop) — the
relative commands never moved it and absolute is unreliable for non-zero targets.
Presets are the `No.1/No.2/No.3` slots via `09 03 01 16`.

## UVC controls (NOT HID — use v4l2 / UVCIOC_CTRL_QUERY)

All confirmed by labels. **Image quality, zoom, exposure, focus, WB are standard
UVC** — most reachable via `v4l2-ctl`.

| Unit | Selector | Control | Range seen |
|---|---|---|---|
| 0x03 PU | 0x02 | Brightness | `00 00`-`ff 00` (0-255) |
| 0x03 PU | 0x03 | Contrast | 0-255 |
| 0x03 PU | 0x04 | **ISO/gain** | `00 00`/`64 00` (0-100) |
| 0x03 PU | 0x05 | **Anti-flicker** (powerline freq) | 1=50Hz, 2=60Hz |
| 0x03 PU | 0x06 | Tone (hue) | 0-255 |
| 0x03 PU | 0x07 | Saturation | 0-255 |
| 0x03 PU | 0x08 | Sharpness | 0-255 |
| 0x03 PU | 0x0a | White-balance temp | `4c 1d`=7500, `fc 08`=2300 |
| 0x03 PU | 0x0b | AWB auto lock | 0/1 |
| 0x01 CT | 0x02 | Auto-exposure mode | UVC `8`=auto / `1`=manual; via v4l2 `auto_exposure` it's a **menu 0–3: 1=manual, 3=aperture-priority(auto)** |
| 0x01 CT | 0x04 | Exposure time (EV) | `01 00 00 00`...`88 13 00 00` (=5000) |
| 0x01 CT | 0x06 | **Focus** (abs) | `00 00`-`ff 03` (0-1023); also focus-lock pair |
| 0x01 CT | 0x08 | Focus auto (AF/lock) | 0 lock, 1 AF |
| 0x01 CT | 0x0b | **Zoom** (abs) | `64 00`=100...`96 00`=150 (far->near) |
| 0x02 XU | 0x01/0x02 | Vendor XU keepalive | `00 0a`/`00` per stream frame |

**Focus-metering region** depends on focus being in **Lock** mode (AF off) — the
3-button metering is disabled while AF is on. **Flip** is HID (group 4 features),
not the UVC flip control.

## Behavioral facts
1. **Stream gating** — motor/mode ignored unless a V4L2 stream is open; mode
   reads `startup`(3) until then. A controller must hold the device open.
2. **Motion** — only the velocity channel (`09 63 01 20`) moves the gimbal in
   practice. Knob = continuous velocity; arrows = a timed velocity pulse on the
   same channel; recenter = absolute pair (`09 03 01 18`). Relative (`09 63/03 01 19`)
   never moved hardware.
3. **Zoom only at 2K/1080p/720p @30** (digital crop needs the higher modes).
4. **Out-of-range absolutes** return `0x40` and can wedge the controller until
   power-cycle — clamp; measure real limits with 1deg steps.
5. **Async pushes** — camera emits unsolicited frames: `09 02 00 02` (privacy
   state), `09 63 02 01` (auto-rotate event). Keep a read loop, not just poll.

## No host-side control (ignore for a Linux app)
Start-recording, screen-capture, whiteboard/desktop mode, audio-mixing, and the
filter presets produced **no device traffic** — pure Studio-side software
features, not camera commands. Nothing to replicate.

## Still slightly open
- Preset **save vs recall** exact framing on `09 03 01 16` (isolate one save + one recall)
- Confirm `09 03 01 00` semantics (axis limit vs alt-absolute)
- Exact pan/tilt mechanical limits
