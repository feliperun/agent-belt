---
type: ADR
id: "0010"
title: "USB and Bluetooth keypad identity"
status: active
date: 2026-10-02
---

## Context

The USB keypad uses the configured vendor/product IDs (default `514c:8850`).
Over Bluetooth Low Energy, MINI-KEYBOARD advertises `05ac:022c`, IDs also used by
unrelated keyboards. Filtering by the USB IDs excludes it; accepting the Bluetooth
IDs alone could intercept another keyboard. Its Bluetooth HID descriptor includes
keyboard, mouse and Consumer Control collections, but no vendor RGB output channel.

## Decision

Share device matching between the input monitor and `agb status` in
`src/keypad_hid.m`. Accept the configured vendor AND product IDs, or the exact
product name `MINI-KEYBOARD` AND a `Bluetooth` or `Bluetooth Low Energy` transport.
Apply the same identity check when routing input, including when other keyboards
are monitored for F5. Keep IOHIDManager's matching active for connection changes.

Both transports use the existing keyboard usages for the six keys and Consumer
Control usages for the knob. RGB commands remain on the USB vendor interface;
never reinterpret standard Bluetooth keyboard LED reports as RGB commands.

## Options considered

- Replace the configured USB IDs with Bluetooth IDs: loses USB and could capture
  an unrelated keyboard.
- Match every keyboard or only the product name: too broad.
- Introduce a separate Bluetooth stack: unnecessary for standard HID inputs and
  unsupported by the observed RGB descriptor.

## Consequences

Pairing through macOS Bluetooth settings is enough; no new runtime configuration
or dependencies are needed. Keys and knob work wirelessly; RGB attention lights
require USB. Deterministic tests exercise matching and input routing with synthetic
HID properties and values, without hardware, real data or service credentials.
