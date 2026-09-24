# Changelog

## [0.2.0](https://github.com/feliperun/agent-belt/compare/v0.1.0...v0.2.0) (2026-09-24)


### ⚠ BREAKING CHANGES

* the work, work-session and tm commands are gone; use agb.

### Features

* agent sessions ported to Zig; humane agb new; agb on Linux and Windows ([12a8cd7](https://github.com/feliperun/agent-belt/commit/12a8cd7a104c30aafe3de99013a3d8b2a0ba96f4))
* F5 (the Mac's microphone key) as push-to-talk ([bd20f2e](https://github.com/feliperun/agent-belt/commit/bd20f2e15e5384b0a8f1d8172b68d1dd1c54ae9b))
* **linux:** desktop agent menu, Waybar module and push-to-talk for Hyprland ([5c4966e](https://github.com/feliperun/agent-belt/commit/5c4966efe6898556a80de59da24c3b0f5f8729c1))
* **linux:** Omarchy integration: Lua binds, bar module and its own menu ([aae746b](https://github.com/feliperun/agent-belt/commit/aae746b2f3c0d1e13178801be2c4dded913dc8f5))
* one CLI (agb runs agent sessions) and a native menu bar menu ([1884418](https://github.com/feliperun/agent-belt/commit/188441826516ecc3688d2150aac46202cdcbdac8))
* **sessions:** agb repos, tmux and git resolved on every PATH ([faa84c5](https://github.com/feliperun/agent-belt/commit/faa84c529b114db62ed74fdb43daa66cfe516d5f))
* the Mac's dictation overlay on Windows and Linux ([e1e9d2d](https://github.com/feliperun/agent-belt/commit/e1e9d2d499c6cd4d0b50d915d10fd58224e97dab))
* **windows:** tray daemon with session menu, new-agent dialog and dictation ([ce79386](https://github.com/feliperun/agent-belt/commit/ce793861a5c939aedacde2950a3d2478ac10d07a))


### Bug Fixes

* agb version reported a leak in release builds ([ecc65ab](https://github.com/feliperun/agent-belt/commit/ecc65ab7ced11a1613aac922cbf3bdc4023ddf86))
* dictation hung on the clipboard fallback; deploy failed over a running agb ([7b0bcc3](https://github.com/feliperun/agent-belt/commit/7b0bcc370d1a6f2705caf524cc3c109862dcfe8e))
* F5 push-to-talk no longer fights macOS Dictation; recording cues ([7e0d481](https://github.com/feliperun/agent-belt/commit/7e0d48180f38643515b8e6928f7a9fef9fda5c04))
* fn+F5 recorded nothing ([329e5be](https://github.com/feliperun/agent-belt/commit/329e5be82f785103cf2a8ae86851eb684eac4657))
* **linux:** first dictated key lost, stacked notifications, empty new-agent prompt ([8d8198d](https://github.com/feliperun/agent-belt/commit/8d8198d46bbb588ad67db32e4d9f5867c7c2485d))
* **linux:** remote attach from Ghostty, 2 s dictation delay, silent menu failures ([649f055](https://github.com/feliperun/agent-belt/commit/649f055f777221f32b2cc806324955f28b3056e3))
* menu bar click did nothing ([2caa043](https://github.com/feliperun/agent-belt/commit/2caa0435f162ae4e69b4533d5dd0cdbb95e5f943))
* overlay below the Omarchy bar; microphone level with the Mac's curve ([632c8c5](https://github.com/feliperun/agent-belt/commit/632c8c57b60e96361ae44c2ad5cf461ac84c7450))
* **sessions:** agb deploy removes the bash tools agb replaced ([08b3f8a](https://github.com/feliperun/agent-belt/commit/08b3f8a7b969e6d1d8174e05b15bad4252a4800f))
* **windows:** remote agb calls hung when agb ran inside an ssh session ([0afaab6](https://github.com/feliperun/agent-belt/commit/0afaab66ed88eb7a1434f1095895dbe272dc7831))

## 0.1.0 (2026-09-23)

First version of Agent Belt (formerly minikeyboard).

### Features

* push-to-talk with Deepgram transcription and an animated overlay (listening / deciphering)
* switch coding agents with key 4, going first to whoever is waiting for you or has finished; switch HUD
* agents menu on key 1, `⌃⌥Space` or a click on the menu bar: title, recap, time, cost, tokens and Claude and Codex quotas
* create agents by voice or with `agb new`, via `work --prompt` on any machine in the tailnet
* key LEDs: white while recording, cyan while transcribing, red waiting, green finished, reactive white wave
* the knob scrolls the page; its button takes the agents back to the bottom
* Esc, Delete and Return on keys 0, 2 and 5; shortcuts on the Mac keyboard to use it without the mini keyboard
* WhatsApp alert when an agent is waiting for you and the Mac is idle
* `work`/`tm` (formerly the tmux repository) included; installer with LaunchAgent, icon, links to the permissions and automatic updates
