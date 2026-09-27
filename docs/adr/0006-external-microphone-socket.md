---
type: ADR
id: "0006"
title: "External microphone over a local socket"
status: active
date: 2026-09-27
---

## Context

A handheld device with its own microphone (an M5StickS3, the "Fordita") should
dictate into the Mac the way the keypad does: same overlay, live transcript,
insertion, voice commands with the agent menu open, and history. Its audio
reaches the Mac over the local network through a small service on the Mac.

Two ways were weighed. A virtual audio device (BlackHole) plus a simulated F5
needs a third-party audio driver and swaps the system's default input for the
duration of every dictation. Feeding the recorder directly keeps the device's
audio inside agent-belt and touches nothing else on the system.

## Decision

1. **The daemon listens on a Unix socket**,
   `~/Library/Application Support/agent-belt/mic.sock`, created owner-only (mode
   0600). A connection is push-to-talk held; its bytes are 16 kHz mono PCM16, the
   format the recorder already captures; closing the connection is the release.
   One session at a time (`src/ext_mic.c`).
2. **The recorder takes pushed audio.** `mk_recorder_push` feeds a recorder that was
   never started with the same buffer, level meter and live handler as the
   AudioQueue callback, and `Live.start` takes a `Source` (`mic` or `external`).
   Everything after capture (streaming, WAV, history, insertion, voice command)
   is the existing push-to-talk path.
3. **The external microphone has its own push-to-talk index** (7), which no
   binding uses. While the keypad or F5 is recording, a socket session is
   accepted but its audio is dropped, as a second held key would be.

## Consequences

- Any process of the same user can dictate by writing to the socket; no other
  user can. There is no token: file permissions are the boundary.
- The protocol has no framing or header. A future format change needs a new
  socket name or a first-byte version, not a silent reinterpretation.
- The device-side service (Fordita's `mac/fordita_mac.py`) is outside this
  repository; it relays HTTP chunks to the socket as they arrive.
