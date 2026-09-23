# LED protocol (514c:8850, 6 keys + knob)

Obtained by reverse engineering the official Mac configurator
(`http://www.szxiaozi.com/MACEN.zip`, `MINI_KEYBOARD.app`, functions
`Widget::SetRgb_Led_Key` and `Widget::HID_write`) and confirmed on the hardware on
2026-09-23. None of this comes from manufacturer documentation.

## Transport

- Configuration interface: usage page `0xFF00`, usage `0x01`, report ID `0x03`.
- 65-byte output reports (report ID + 64 data bytes, zeros for the rest), via
  `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x03, buf, 65)`.
- The device only responds ~250 ms after being opened.
- Writes less than ~150 ms apart are silently dropped; use 300 ms.

## Sequence

```
03 FB FB FB                                     identify; answers 03 FB 06 01 (6 keys, 1 knob)
  300 ms
03 FE B0 01 08 00 00 00 00 00 01 00 <color<<4|mode>
```

Without the identification right before it, the LED command is ignored. The
`03 FD FE FF` commit the app sends afterwards **is not needed**: the LED command
itself is already persisted (the color survives unplugging). Every change writes to flash.

| byte | value | meaning |
|---|---|---|
| 1–2 | `FE B0` | LED command |
| 3 | `01` | layer, starting at 1 |
| 4 | `08` | "LED" type (the app uses `01` keys, `02` media, `03`/`05` mouse) |
| 10 | `01` | fixed |
| 12 | `color<<4 \| mode` | |

Colors (the app's table): `1` red, `2` orange, `3` yellow, `4` green,
`5` cyan, `6` blue, `7` purple. Color `0` turns off in fixed mode and is **white** in reactive mode.

Modes, as observed on this unit (the manual says otherwise for 2 and 3):

| mode | effect |
|---|---|
| 0 | off |
| 1 | fixed color |
| 2 | reactive: off; a wave of the color runs across all keys on press and on release (color 0 = white) |
| 3 | reactive, same as 2 |
| 4 | reactive, only the pressed key lights up |
| 5 | fixed white (the color is ignored; `65` confirmed) |

There is no continuous animation and no rainbow: everything that animates reacts to keys. Changing
the color from the host is slow (≥ 600 ms per change, with identification) and writes to flash at
every step.

## Commands that must never be sent

On the same channel, according to other projects for this VID:PID:

- `03 FD <slot> …`: rewrites a key's mapping in flash.
- `03 FC FC …`: changes the keyboard model persistently and irreversibly.
- 64 zeroed bytes (the ch57x-keyboard-tool "init").
- The per-key RGB format (`03 FE B0 <layer-1> <mode> R G B …`) belongs to another
  firmware with the same VID:PID; here it does nothing.

## Use in agent-belt

`src/led.m`: a thread always applies the latest desired state and skips repeated
writes. Priority: recording (fixed white) > transcribing (fixed cyan) >
agent waiting for you (red) > agent finished and not yet seen (green) >
base (reactive white wave, `02`). `"led": false` in the config turns it off. Manual:
`agb led <color> <mode>`.
