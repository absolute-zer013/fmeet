#!/usr/bin/env python3
"""pixysniff.py — decode EMEET PIXY HID frames from a usbmon text stream.

Use while EMEET Studio runs inside Winboat with the PIXY passed through;
the host kernel still sees every transfer.

Usage:
    sudo modprobe usbmon
    lsusb -d 328f:00c0                      # note Bus BBB Device DDD
    sudo cat /sys/kernel/debug/usb/usbmon/<B>u | ./pixysniff.py --dev DDD | tee session.log

Then toggle ONE setting in EMEET Studio at a time and watch the frames.

usbmon text line format (see Documentation/usb/usbmon.rst):
    <urb-tag> <timestamp> <event S|C|E> <type+dir>:<bus>:<dev>:<ep> <status/setup> <len> [= data...]
type+dir: Ii/Io interrupt in/out, Ci/Co control in/out, Bi/Bo bulk, Zi/Zo iso.

We decode:
  * Io / Ii on the HID endpoints  -> PIXY command frames (PixyBar protocol)
  * Co with setup 21 01 ....      -> UVC SET_CUR to the extension unit
  * Ci with setup a1 81/82/...    -> UVC GET_* (printed compactly)
"""

import argparse
import re
import struct
import sys

KNOWN = {
    (0x01, 0x00): "SET mode",
    (0x01, 0x01): "GET mode",
    (0x03, 0x18): "MOTOR absolute",
    (0x03, 0x19): "MOTOR relative",
    (0x04, 0x00): "SET tracking",
    (0x04, 0x01): "GET tracking",
}

LINE = re.compile(
    r"^\S+\s+\d+\s+(?P<event>[SCE])\s+(?P<tt>[CIBZ][io]):(?P<bus>\d+):(?P<dev>\d+):(?P<ep>\d+)"
    r"\s+(?P<rest>.*)$"
)


def hexbytes(rest: str) -> bytes:
    if "=" not in rest:
        return b""
    blob = rest.split("=", 1)[1].replace(" ", "")
    try:
        return bytes.fromhex(blob)
    except ValueError:
        return b""


def fmt_floats(payload: bytes) -> str:
    """Annotate any aligned 4-byte groups that decode to sane floats."""
    notes = []
    for off in range(0, len(payload) - 3):
        (v,) = struct.unpack_from("<f", payload, off)
        if v == v and -1e4 < v < 1e4 and abs(v) > 1e-4 or v == 0.0:
            if off in (1, 5, 9, 13, 17):  # offsets the known protocol uses
                notes.append(f"f32@{off}={v:.3f}")
    return (" [" + " ".join(notes) + "]") if notes else ""


def decode_hid(direction: str, data: bytes):
    if len(data) < 8 or data[0] != 0x09:
        # unknown framing — print raw so nothing is lost
        print(f"  {direction} raw: {data.hex(' ')}")
        return
    group, sub = data[1] & 0x1F, data[3]
    name = KNOWN.get((group, sub), "UNKNOWN")
    plen = data[5] | (data[6] << 8)
    payload = data[8 : 8 + min(plen, len(data) - 8)]
    print(
        f"  {direction} {data[0]:02x} {data[1]:02x} {data[2]:02x} {data[3]:02x}"
        f"  [{name}] len={plen} payload={payload.hex(' ') or '-'}{fmt_floats(payload)}"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", required=True, help="device address from lsusb (e.g. 038 or 38)")
    ap.add_argument("--all", action="store_true", help="also print unrelated traffic")
    args = ap.parse_args()
    want_dev = int(args.dev)

    print(f"listening for device address {want_dev} … toggle one Studio setting at a time", file=sys.stderr)

    for line in sys.stdin:
        m = LINE.match(line)
        if not m:
            continue
        if int(m["dev"]) != want_dev:
            continue
        tt, event, rest = m["tt"], m["event"], m["rest"]
        data = hexbytes(rest)

        if tt == "Io" and event == "S":          # host -> PIXY (commands)
            decode_hid("->", data)
        elif tt == "Ii" and event == "C" and data:  # PIXY -> host (responses)
            decode_hid("<-", data)
        elif tt == "Co" and event == "S":
            # control OUT; setup packet is in 'rest' before '=': s 21 01 wValue wIndex wLength
            parts = rest.split()
            if len(parts) >= 6 and parts[0] == "s" and parts[1] == "21" and parts[2] == "01":
                wval, widx = parts[3], parts[4]
                print(f"  -> UVC SET_CUR selector=0x{wval[:2]} unit=0x{widx[:2]} data={data.hex(' ')}")
            elif args.all:
                print(f"  -> CTRL {rest}")
        elif tt == "Ci" and event == "C" and args.all:
            print(f"  <- CTRL {rest}")


if __name__ == "__main__":
    main()
