# Changelog

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
