# Changelog

## [0.4.1](https://github.com/feliperun/agent-belt/compare/v0.4.0...v0.4.1) (2026-09-25)


### Documentation

* license the project under MIT ([fa77cdb](https://github.com/feliperun/agent-belt/commit/fa77cdb6de79ad03583fec956f4245e73c8bc380))

## [0.4.0](https://github.com/feliperun/agent-belt/compare/v0.3.0...v0.4.0) (2026-09-25)


### Features

* a fast model cleans the dictated request for the new agent ([9b52446](https://github.com/feliperun/agent-belt/commit/9b524460e321e052a9bd62d536f4884a26f0f994))
* a new agent by voice on Omarchy (hold Shift+F9) ([ac0997d](https://github.com/feliperun/agent-belt/commit/ac0997d32552c2f5e02adf0de740f3abc330e684))
* meaningful session names, intent summaries and a recording history ([223b737](https://github.com/feliperun/agent-belt/commit/223b7373dff116855986119f113e9e3f70c8f319))
* real-time dictation on Linux ([0deef25](https://github.com/feliperun/agent-belt/commit/0deef252045857c077d5422dd8a7a3a3bd83ffbe))
* real-time dictation on the Mac ([c95a113](https://github.com/feliperun/agent-belt/commit/c95a113c85b6def3c82e548aba06e0b87b6493ba))
* **sessions:** agents without a repo, for research ([167a606](https://github.com/feliperun/agent-belt/commit/167a60698398662c1dc74981f2854f2a438339df))
* the new agent gets only the work, as a clear prompt ([0f0d175](https://github.com/feliperun/agent-belt/commit/0f0d17564b2dd613b494ac187de79e8989966b9c))


### Bug Fixes

* adopting an agent could reopen another agent's conversation ([39f768c](https://github.com/feliperun/agent-belt/commit/39f768cef323d2587bd694b96ef5afd04cc059f8))
* create panel marks only real doubts; defaults (not said) are shown dimmer ([333e39c](https://github.com/feliperun/agent-belt/commit/333e39ceb441877610d2228fc3f3b95e591d2716))
* dictation overlay born at full size, starts clean, shows a discreet timer ([b13b0c7](https://github.com/feliperun/agent-belt/commit/b13b0c79f9dd619eabb43659361d94459ce8c49d))
* dictation overlay: the waveform spans the widened pill; no Transcribing while streaming ([11f1479](https://github.com/feliperun/agent-belt/commit/11f147929bff15d29fc98c7b42437ae7053b0485))
* long requests reached the new agent cut short ([13aa529](https://github.com/feliperun/agent-belt/commit/13aa5293cc6dff4c522579bc552df417ec5eaf65))
* machines said by their last name part; the session name in the panel header ([c15e12c](https://github.com/feliperun/agent-belt/commit/c15e12c07d6938f84f1be163eff6594eaa9384a7))
* pressing Shift+F9 again opened another panel on top ([fdb68aa](https://github.com/feliperun/agent-belt/commit/fdb68aa448b685c9c6a089c8c4954e6803aab7c8))
* remote attaches drew accents and symbols as underscores ([8fd215e](https://github.com/feliperun/agent-belt/commit/8fd215e8c5bbc986b1a1f037f3552027003c465c))
* **security:** close quoting and naming holes in the session layer ([fa8f210](https://github.com/feliperun/agent-belt/commit/fa8f21071c107f686f3fd8ff56f8b74f3087b501))
* **security:** harden the network clients, the updater and CI ([e897984](https://github.com/feliperun/agent-belt/commit/e897984e564e41f072c4e4c9845802e4d7d3f1c3))
* **security:** keep recordings, transcripts, keys and runtime files private ([52ceca8](https://github.com/feliperun/agent-belt/commit/52ceca822b7330e51a45e77225a2531c4534e35d))
* the installer hung for minutes stopping the daemon ([0b85b59](https://github.com/feliperun/agent-belt/commit/0b85b59e40b75cdcc2cc0552a1eceab2cb54cb9d))

## [0.3.0](https://github.com/feliperun/agent-belt/compare/v0.2.0...v0.3.0) (2026-09-24)


### Features

* push-to-talk to create an agent (key 5) ([dac0cf4](https://github.com/feliperun/agent-belt/commit/dac0cf43ec2e01a661bfb8a4627646e5cb4bf5ef))
* **sessions:** real-time transcription and create-agent detection ([b563afd](https://github.com/feliperun/agent-belt/commit/b563afd4f7d2e636cb0089abe64879a59c634800))
* Windows new-agent dialog detects the intent; the whole UI in English ([45a052e](https://github.com/feliperun/agent-belt/commit/45a052e1ae5ed8fb52f1f1048037d3be8377c986))


### Bug Fixes

* menu bar icon hidden behind the notch after a restart ([198c88e](https://github.com/feliperun/agent-belt/commit/198c88e02bd06de5b4d1a98745eaf248d53120fe))
* mesh-keys.sh syntax (an apostrophe inside single quotes) ([fa4ac64](https://github.com/feliperun/agent-belt/commit/fa4ac64e76a2cc4cb332640a2f58295c6ecdb1f5))
* **sessions:** new sessions renamed before attaching, 'can't find session' ([9480400](https://github.com/feliperun/agent-belt/commit/9480400d26a6c4f5bd7101b00c7aaad8ee361453))

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
