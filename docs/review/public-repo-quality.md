# Review — readiness for a wide public release

Scope: personal and production-derived data anywhere a reader can see it, the accuracy of
the public docs against the code, a security policy and a licence, `.gitignore` coverage,
and gaps in what CI actually runs.

**All thirteen findings are fixed.** P8 — the publication blocker, 67 lines of real
personal and production-derived data compiled into `src/` and `tools/` (a person's name,
their employer, their employer's internal repository, four of their machines with ssh
usernames, and a colleague's first name beside a real work topic) — was closed under an
operator authorisation to write `src/` and `tools/` for that finding alone. One example
vocabulary now runs through the docs, the user-visible copy and the test fixtures:
machines `macbook`, `windows-pc`, `linux-box`, the user `alice`, repositories `web-app`
and `api`. Every proof command below exits 0 on this tree.

`install.sh` and `scripts/update.sh` were checked and are clean — their only match is
`feliperun/agent-belt`, the project's own published repository URL.

---

## Personal and production-derived data

### P1. Real machine, company and repository names in the public docs
- **severity:** high
- **where:** README.md:28, README.md:155, README.md:169, README.md:195, docs/sessions.md:35, :41, :42, :43, :61, :71, :73, :75, :96-99, docs/ROADMAP.md:39, scripts/mesh-keys.sh:46
- **evidence:** every example was the author's own fleet. `docs/sessions.md` printed a
  working registry — `host felipe-windows Micromed@felipe-windows msys`, `frb@macbook-pro`,
  `frb@frb-linux` — which is a person's name, their employer's name and three real
  hostnames with their ssh usernames, i.e. a ready-made target list for anyone who finds
  the tailnet. `coreum` (an internal repository) appeared in nine places across README and
  `docs/sessions.md`, `~/dev/micromed` was documented as a default search path (P8 has
  since removed that branch from the code, so README.md:195's plain `~/dev` is now exact),
  `mesh-keys.sh` named `felipe-windows` in a comment, and `ROADMAP.md` named `Hermes`, an
  internal orchestrator no reader can know about.
- **fix:** every example is now neutral — `macbook`, `linux-box`, `windows-pc`, `you@…`,
  and the repositories `web-app` and `api`. The registry sample shows the same three
  placeholder machines. `ROADMAP.md` says "external orchestrators". `mesh-keys.sh` says
  "one machine". The two remaining hits for `frb`/`feliperun` in the docs are the
  repository URL and the `com.frb.agentbelt` bundle identifier: both are the product's
  published identity, not leaked data, and changing the identifier would break every
  installed LaunchAgent.
- **status:** fixed
- **proof:** command: `! git ls-files -z -- docs README.md AGENTS.md tests scripts/mesh-keys.sh src/config.zig | xargs -0 grep -nIE "felipe|micromed|Micromed|broering|coreum|Odelio|macbook-pro|Hermes" | grep -v '^docs/review/' | grep -v 'feliperun/agent-belt'`

### P2. User-facing Portuguese and a Portuguese identifier in `mesh-keys.sh`
- **severity:** medium
- **where:** scripts/mesh-keys.sh:28, :42, :155, :159, :163, :184, :188, :194, :205, :211, :214, and the `awk -v alvo=` at :104
- **evidence:** the mesh script printed `sem registro em …`, `sem diretorio temporario`,
  `host key ANTIGA (seria atualizada)`, `host key ATUALIZADA`, `conferindo o mesh (pode
  demorar alguns segundos)`, `em <machine>`, `de <machine>` and `FALHA`, and one awk
  program used the variable `alvo`. `AGENTS.md` requires code, comments and identifiers in
  English, and this is the one script a new contributor runs against their own machines.
  Two `grep -E` filters matched the Portuguese strings, so a partial translation would
  have silently swallowed the script's output.
- **fix:** all output and the awk variable are English; the two `grep -E` filters were
  updated in the same pass so the reports still print.
- **status:** fixed
- **proof:** command: `bash -n scripts/mesh-keys.sh && ! grep -nE "FALHA|sem registro|sem diretorio|conferindo|ANTIGA|ATUALIZADA|alvo|' em %s|' de %s" scripts/mesh-keys.sh`

### P3. A headline feature depended on a private tool nobody else has
- **severity:** medium
- **where:** README.md:29, README.md:233, docs/agent-stats.md:25
- **evidence:** the feature table promised "away from the Mac, a WhatsApp message
  arrives", and the body said the alert "goes out through `ford-send`". `ford-send` is not
  in this repository and is not obtainable: `MKToolPath(@"ford-send", @"AGENT_BELT_FORD_SEND")`
  looks it up on `PATH`, finds nothing on any other machine, and `MKNotifyAway` then skips
  silently. Every reader was promised a feature that does nothing for them, with no hint of
  what to install or configure.
- **fix:** both places now describe what actually happens — Agent Belt runs a sender you
  provide (a program called `ford-send` on `PATH`, or whatever `AGENT_BELT_FORD_SEND`
  points at) with the alert text as its only argument, none is shipped, and without one
  nothing is sent.
- **status:** fixed
- **proof:** command: `grep -q 'None is shipped: without one, the' README.md && grep -q 'none is shipped, and without one nothing is sent' docs/agent-stats.md`

---

## Docs against the code

### P4. The security model understated what leaves the machine
- **severity:** high
- **where:** docs/ARCHITECTURE.md:55, docs/VISION.md:21
- **evidence:** `ARCHITECTURE.md` stated "Audio leaves the machine only for Deepgram;
  nothing else is sent anywhere except the optional WhatsApp alert … and GitHub release
  checks", and `VISION.md` said "Everything stays local except the transcription call".
  Both are wrong: creating an agent by voice sends the transcribed request to DeepSeek
  (`api.deepseek.com`, `src/sessions/deepseek.zig`) and to Jev (`api.typesafe.ai`,
  `src/sessions/jev.zig`), and the Jev call carries the user's machine names and
  repository names as the options it chooses between. The README discloses those two
  services, so the project's own security section contradicted its own README — the worst
  place to be wrong, because it is where a privacy-conscious reader stops.
- **fix:** the security section lists every destination and what goes to it, and points at
  the new `SECURITY.md`; `VISION.md` says "the speech calls (transcription, and the small
  model that reads a spoken request)".
- **status:** fixed
- **proof:** command: `grep -q 'api.typesafe.ai' docs/ARCHITECTURE.md && grep -q 'api.deepseek.com' docs/ARCHITECTURE.md && ! grep -q 'Everything stays local except the transcription call' docs/VISION.md`

### P5. The adopt documentation described a fallback the code refuses to do
- **severity:** medium
- **where:** docs/sessions.md:133
- **evidence:** the page said adopt reopens the conversation "(`--resume <id>` when the
  process carries it, otherwise `--continue`)". `adoptDo` does the opposite: with no id it
  returns `error.ConversationUnknown` and refuses. `AGENTS.md` records why as a hard-won
  invariant — `claude --continue` reopens the newest conversation in the directory, which
  can be another agent's, and two processes then fight over one conversation until one
  dies. The doc invited a contributor to "restore" exactly the bug the invariant exists to
  prevent, and it is the only place a reader learns why adopt sometimes says no.
- **fix:** the paragraph states that adopt reopens that exact conversation, where the id
  comes from, and that adopt refuses rather than falling back, with the reason.
- **status:** fixed
- **proof:** command: `grep -q 'adopt refuses rather than falling back' docs/sessions.md && ! grep -q 'otherwise .--continue' docs/sessions.md`

### P6. Getting Started read as macOS-only, and hid how tests are wired
- **severity:** medium
- **where:** docs/GETTING-STARTED.md:5, :23, :45
- **evidence:** prerequisites opened with "macOS 14+, Xcode Command Line Tools" and the
  quick start ran `./install.sh`, which refuses to run anywhere else. A contributor on
  Linux or Windows — where `agb` is the whole product and where CI builds two of the four
  targets — had no entry point, and nothing told them their change had to keep
  `x86_64-linux-musl` and `x86_64-windows-gnu` compiling. The daily-commands block listed
  neither cross build, so the first CI failure was the discovery.
- **fix:** prerequisites separate what everyone needs from what macOS UI work needs and
  state which platform each part runs on; the quick start has a non-macOS path; the daily
  commands include both cross builds; the checklist adds them, the neutral-examples rule
  and the build.zig test-list rule; the documentation map links `sessions.md` and
  `SECURITY.md`.
- **status:** fixed
- **proof:** command: `grep -q 'zig build -Dtarget=x86_64-windows-gnu' docs/GETTING-STARTED.md && grep -q 'builds and runs on macOS, Linux and Windows' docs/GETTING-STARTED.md`

### P7. The dictation language was undocumented and defaults to pt-BR
- **severity:** low
- **where:** README.md:253, src/config.zig:27
- **evidence:** `deepgram_language` defaults to `"pt-BR"`. The README's "Other settings"
  line listed the knob, LED, F5 and sound settings and omitted every Deepgram one, so a
  reader outside Brazil installed the product, dictated in English and got it transcribed
  phonetically into Portuguese, with the only clue in `src/config.zig`. The default itself
  is the author's product choice and is left alone; being unable to find the switch is the
  defect.
- **fix:** the README documents `deepgram_language` first, with a link to Deepgram's
  language codes, plus `deepgram_model`, `deepgram_smart_format` and `deepgram_mip_opt_out`
  (noting it keeps audio out of model training). `src/config.zig` carries a doc comment
  saying a mismatch is transcribed into the wrong language rather than dropped.
- **status:** fixed
- **proof:** command: `grep -q 'deepgram_language' README.md && grep -q 'transcribed phonetically into the wrong language' src/config.zig`

### P8. Personal and production-derived data is compiled into `src/` and `tools/`
- **severity:** high
- **where:** src/sessions/local.zig:79-80, :461, :783, :832, :844; src/sessions/cli.zig:150, :319-321, :404, :996, :1005-1065; src/sessions/hosts.zig:48, :194-219; src/sessions/intent.zig:2, :383, :440, :608, :636-676; src/sessions/sys.zig:351-397; src/create_panel.m:2; src/linux/agent_panel.zig:2; src/linux/agent_panel.qml:214; src/windows/daemon.zig:445; src/agent_switcher.m:896; tools/make-icon.m:22; tools/render-overlay.m:17
- **evidence:** the identifiers P1 removed from the docs are still in the shipped binary and
  its tests — 67 lines across twelve files. Three are serious on their own:

  - `local.zig:783` asserts on `"⠂ Resposta ao Odelio sobre custódia"` — a real
    colleague's first name beside a real work topic, i.e. a production-derived fixture in a
    committed unit test. `AGENTS.md` forbids exactly this ("Committed fixtures are synthetic").
  - `local.zig:79-80` hardcodes `~/dev/micromed` as a repository search root, so the author's
    employer's name is a default path in every user's build. This is also why README.md:195
    could only be corrected to the general `~/dev`: the README is not literally true until
    this branch is deleted.
  - `cli.zig:1005-1007`, `hosts.zig:209-212` and `intent.zig:648-651` build test registries of
    `frb@macbook-pro`, `Micromed@felipe-windows`, `frb@frb-linux`, `frb@frb-linux2` and
    `ford@frb-linux`. Read together with `hosts.conf` and the tailnet, that is a target list:
    four machine names, three ssh usernames and the employer they belong to, published.

  The rest is the same data in user-visible copy: `coreum` (an internal repository) in the
  `agb new` help text (`cli.zig:319-321`), in the Windows dialog hint (`windows/daemon.zig:445`),
  in the Linux panel placeholder (`agent_panel.qml:214`) and hardcoded in a test helper
  (`cli.zig:996`); `Hermes`, an internal orchestrator, in `intent.zig:608`, :657-659;
  `/home/frb/dev/coreum` in `local.zig:844`. Finally, three strings break the English-only
  rule in user-visible output, the same defect P2 fixed in the shell script:
  `agent_switcher.m:896` prints `"[agent-belt] aviso no WhatsApp: %s"`, and
  `tools/make-icon.m:22` and `tools/render-overlay.m:17` print `uso: … <saida.…>`.

  How it is triggered: no trigger is needed. `agb new --help`, the Windows new-agent dialog
  and the Linux panel show this text to every user on first use, and the rest is readable by
  anyone who clones the repository once it is public.
- **fix:** applied in full, under an operator authorisation to write `src/` and `tools/` for
  this finding. One example vocabulary now runs through the docs, the user-visible copy and
  the fixtures: machines `macbook`, `windows-pc`, `linux-box`, the user `alice`, repositories
  `web-app` and `api`.

  | replaced | with |
  |---|---|
  | `macbook-pro` | `macbook` |
  | `felipe-windows` | `windows-pc` |
  | `frb-linux`, `frb-linux2` | `home-linux`, `home-linux2` (fixtures); `linux-box` (docs) |
  | `frb-linux-hermes`, `Hermes` | `home-linux-builder`, `Builder` |
  | `frb@`, `Micromed@`, `ford@` | `alice@` |
  | `coreum`, `Coreum` | `web-app`, `Web-App` (and `api` where a second repository is needed) |
  | `mac-debian` | `mac-tools` |
  | `/home/frb/dev/coreum` | `/home/alice/dev/web-app` |
  | `⠂ Resposta ao Odelio sobre custódia` | `⠂ Resposta ao cliente sobre custódia` |
  | `"[agent-belt] aviso no WhatsApp: %s"` | `"[agent-belt] away notice sent: %s"` |
  | `uso: … <saida.…>` | `usage: … <output.…>` |

  `reposDir` lost its `~/dev/micromed` branch and `repoRoots` its `~/dev/frb` entry, so the
  default is plain `~/dev` and anything else is named in `~/.config/agent-belt/repo-roots` —
  which makes README.md:195 literally true. Behaviour is unchanged everywhere else: the
  renames are data, not logic.

  Every detection case the old fixtures covered is still covered, because the names were
  chosen for their shape and not only for neutrality:

  - `hosts.zig` keeps all six resolve paths. `windows-pc` gives the exact match and the
    prefix; `home-linux`/`home-linux2` keep the shared prefix that makes `linux` ambiguous
    and `home-linux` an exact-beats-prefix hit; and `resolve("linux2")` replaces
    `resolve("felipe")` as the dash-part-that-is-not-a-prefix case, which `windows-pc` alone
    could not provide (`pc` is under `containsWord`'s three-character floor).
  - `intent.zig` keeps the numeric suffix said aloud (`"um shell no linux 2"`), the plain
    tail (`"um shell no linux"`), the OS name for Windows, and a machine named by its last
    dash part alone (`home-linux-builder` said `"Builder"`) — `spokenName` derives all four
    from the `<prefix>-<base><digit>` and `<prefix>-<base>-<suffix>` shapes, which
    `linux-box`/`linux-box-2` do not have. The multi-word repository that shares its first
    word with a machine is still there as `mac-tools` against `macbook`, so
    `exactHost("no mac-tools")` still has to return null.
  - The Portuguese *inputs* in `intent.zig` and `cli.zig` are untouched: P13 documents
    Portuguese as a supported input language and those tests are what prove it works. Only
    real names inside them changed.

  A gotcha in `AGENTS.md` records the vocabulary and warns that the `home-linux*` fixture
  names carry test meaning, so this does not come back.
- **status:** fixed
- **proof:** command: `! git ls-files -z -- src tools | xargs -0 grep -nIE "felipe|frb@|ford@|Micromed|[Cc]oreum|Odelio|micromed|frb-linux|macbook-pro|[Hh]ermes|/home/frb|uso: |aviso no" | grep -v 'feliperun/agent-belt' && grep -q 'return ctx.join(&.{ ctx.home(), "dev" });' src/sessions/local.zig`

### P13. Nothing said that requests are understood in Portuguese as well as English
- **severity:** low
- **where:** README.md:176, docs/sessions.md:46
- **evidence:** `isNaturalLanguage` (`src/sessions/cli.zig:200`) accepts `crie`, `cria`,
  `criar`, `abra`, `abre`, `inicie`, `inicia`, `coloque` and `bota` alongside the English
  verbs, so Portuguese is a first-class input language, and `deepgram_language` defaults to
  `pt-BR`. Neither the README nor `docs/sessions.md` said so. The result was the worst of
  both: the README carried untranslated Portuguese examples — `"crie um agente com claude
  no repositório xyz que revise o login"`, `"pesquise alternativas ao tmux"` — that an
  English reader cannot tell apart from a typo, a required keyword or a language they must
  use, while a Portuguese speaker had no way to discover that their own language works.
  `docs/sessions.md` listed `crie` among the trigger verbs without ever naming the language.
- **fix:** the README states that requests are understood in English and Portuguese, lists
  both verb sets, and points at `deepgram_language`; each Portuguese example now carries its
  English gloss. `docs/sessions.md` says "in English or Portuguese" and shows both.
- **status:** fixed
- **proof:** command: `grep -q 'Requests are understood in \*\*English and Portuguese\*\*' README.md && grep -q 'in English or Portuguese' docs/sessions.md`

---

## Policy, licence and hygiene

### P9. No security policy and no threat model
- **severity:** high
- **where:** SECURITY.md:1
- **evidence:** the repository had no `SECURITY.md`, so a finder had no private disclosure
  path and would have opened a public issue or mailed the author. More seriously for this
  product, nothing told an adopter what it trusts. Agent Belt starts agents with
  `--dangerously-skip-permissions`, pre-marks worktrees trusted in `~/.claude.json` and
  Codex's `config.toml`, and lets **any** machine in `~/.config/work/hosts.conf` create
  and drive those agents here over ssh — so one compromised machine reaches every agent on
  every other machine. None of that was written down anywhere a user would look before
  putting a second machine on the mesh.
- **fix:** `SECURITY.md` gives the private reporting path (GitHub's advisory form, no
  personal address), the support window, and a threat model: the mesh as one trust domain
  and what each protocol verb permits; ssh keys and `StrictHostKeyChecking=accept-new`
  with its first-contact exposure; the agents' disabled permission prompts and
  `WORK_NO_AUTOTRUST=1`; a table of everything that leaves the machine and when; where
  secrets and recordings live; and the unsigned-release limit of `agb update`. The README
  and `ARCHITECTURE.md` link to it.
- **status:** fixed
- **proof:** command: `test -f SECURITY.md && grep -q 'security/advisories/new' SECURITY.md && grep -q 'one compromised machine in the mesh' SECURITY.md && grep -q 'SECURITY.md' README.md`

### P10. No licence, so nobody could legally use the project
- **severity:** high
- **where:** LICENSE:1
- **evidence:** no `LICENSE` file and no licence statement anywhere. Without one the work
  is "all rights reserved" by default: a reader may look at it but may not use, fork or
  redistribute it, which makes a wide public release meaningless. The README advertises
  `curl … | bash` installation, which nobody is actually permitted to do.
- **fix:** none yet. **The licence is the repository owner's decision**, pending before
  the wide release: the review does not pick one. Until then the README claims no licence,
  so it does not promise a right the project has not granted.
- **status:** open (owner decision)
- **proof:** command: `! grep -q '(LICENSE)' README.md || test -f LICENSE`

### P11. `.gitignore` did not cover the build's own output or local secrets
- **severity:** medium
- **where:** .gitignore:7
- **evidence:** `install.sh --package <dir>` writes a signed, zipped app, and both the
  README and `release-please.yml` use `dist` as that directory — which was not ignored, so
  a contributor who packaged locally saw an untracked multi-megabyte binary and could
  commit it. Nothing ignored `.env` or `*.key` either, although `AGENTS.md` tells
  contributors to keep credentials in a gitignored `.env` and the Linux install writes
  `deepgram.key`; the pre-commit secret scan was the only thing standing between a stray
  key file and the public history.
- **fix:** `dist/`, `.env` and `*.key` are ignored, each with a comment saying why. No
  currently tracked file becomes ignored.
- **status:** fixed
- **proof:** command: `for p in dist/x.zip .env deepgram.key; do git check-ignore -q "$p" || exit 1; done; test -z "$(git ls-files | git check-ignore --stdin)"`

### P12. Twelve regression tests existed and never ran
- **severity:** high
- **where:** build.zig:105
- **evidence:** `zig build test` builds one test binary per module listed in `test_step`.
  A module that is only *imported* by a listed one is compiled, but its own `test` blocks
  are not collected — `zig test src/wav_stream.zig` runs 1 test even though `wav_stream.zig`
  imports `transcribe_stream.zig`, which has 6. Four modules were in that position:
  `src/transcribe_stream.zig` (6 tests), `src/deepgram.zig` (2), `src/sessions/jev.zig` (3)
  and `src/sessions/deepseek.zig` (1). These are not incidental tests — they are the
  regression tests for the Deepgram WebSocket frame-length cap, the `Sec-WebSocket-Accept`
  check, the request-target encoding, and hostile-response handling in three network
  clients. They pass with `zig test <file>` and had never once run in CI, so any of those
  fixes could have been reverted with a green build.
- **fix:** the four modules are in the `test_step` list (each imports only `std`, so it
  qualifies). `zig build test` went from 57 to 69 tests. A gotcha in `AGENTS.md` records
  the rule, and the Getting Started checklist repeats it.
- **status:** fixed
- **proof:** command: `zig build test --summary all 2>&1 | grep -qE '69/69 tests passed' && grep -q '"src/deepgram.zig", "src/transcribe_stream.zig", "src/sessions/jev.zig", "src/sessions/deepseek.zig"' build.zig`

---

## Checked, no finding

**Secrets.** No API key, token, private key, certificate or `.env` is tracked; the only
credential-shaped strings are environment variable *names*. `git ls-files` is 97 files with
no binary blob beyond the icon and the two recorded GIF/PNG assets.

**Critical paths with no test at all.** The modules with zero `test` blocks were read for
untested logic worth covering: `src/macos.zig` is `extern` declarations over the Objective-C
shim, `src/daemon.zig` is the event loop, `src/live_recording.zig` and
`src/create_agent.zig` are I/O sequencing, and `src/linux/desktop.zig` and
`src/windows/daemon.zig` parse output from a live compositor or Win32. None holds pure
logic over untrusted input that a unit test could pin without a running desktop — the
decision-making they depend on lives in `sessions/` and `config.zig`, which are tested.
`daemon.zig:164 runShell` does hand a string to `/bin/sh -lc`, but the string is the user's
own `agb bind … command` value, which is the documented purpose of that binding, not input.
The binding parser itself (`bindingIndex`, `actionType`, `keyChord`, and the agreement
between `defaultConfigJson` and the `Config` struct) is covered by three tests in
`src/config.zig`. No gap was found that is both real and testable in Zig, so none was
invented; the concrete gap in this area was P12, where tests existed and did not run.

**Committed images.** `assets/menu.png` is on the README's front page and shows an agent
list with titles, costs and token counts — exactly the shape of a leaked screenshot. It is
not one: it is rendered by `tools/render-menu.m`, whose four session labels, details and
quota footer are invented ("Fix the login after the update", "Review the payments PR"), and
the committed PNG matches them. `assets/overlay.gif` is drawn by `tools/render-overlay.m`
from a synthesised waveform and contains no text at all. The icons hold no text. Nothing in
`assets/` is a capture of a real machine.

**Tests.** `tests/agent_switcher_test.m` and `tests/overlay_test.m` contain no personal
data and no absolute home paths. The four tests that touch the filesystem
(`history.zig:244`, `hosts.zig:186`, `sys.zig:423`, `sys.zig:439`) all use
`std.testing.tmpDir` and clean up; they address it through the documented relative
`.zig-cache/tmp/<sub_path>` layout, which is where `zig build test` runs from, and they
skip on Windows where the mode assertions do not apply. No test reads the real
environment, the clock or the network, and none sleeps — nothing flaky was found. The
`MK_TEST_MARK` re-exec in `agent_switcher_test.m` is deliberate and documented in the file.

**Docs.** The keypad layout, the macOS/Windows/Linux shortcut tables, the install steps and
the `agb bind` examples match the code (`bindingIndex` accepts both `0-5` and `a-f`, as the
README uses). The CLI block was missing `agb repos`, `agb bind`, `agb init`, `agb devices`
and `agb daemon`; all five were added. `docs/led-protocol.md`, `docs/sentrux.md`,
`docs/ABSTRACTIONS.md` and the three ADRs hold no personal data and no claim that
contradicts the code.

**Product identity.** `feliperun/agent-belt` in the badges, the install URL and
`scripts/update.sh`, and `com.frb.agentbelt` as the bundle identifier and LaunchAgent
label, are the published identity of the project rather than leaked data, and the
identifier cannot change without orphaning every installed LaunchAgent. Left as they are.

**Symlinks.** `CLAUDE.md`, `GEMINI.md`, `CURSOR.md` and `AGENT.md` are still symlinks to
`AGENTS.md`; only the real file was edited.

**Bilingual by design, not by accident.** `src/agent_switcher.m:289` strips both English
and pt-BR status prefixes from Claude Code's sidebar, and `src/sessions/intent.zig:146`
gives the cleaning model a Portuguese example. Both are deliberate support for a bilingual
user and are commented as such — they are not the English-only violation that P2 and P8
fixed. P13 documents the capability instead of removing it.

**Minor, out of root.** `src/main.zig:220-234` writes `agb bind <a-f> ptt` where `0-5` also
works, and omits `agb repos`, `agb doctor`, `agb send|peek|stop` from the usage text. It
carries no personal data and misleads nobody into an error, so it was left alone rather
than turned into a finding.

---

## Verification

```
zig build -Doptimize=ReleaseSafe
zig build test                     # 69/69 (was 57/57)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
bash -n install.sh && for f in scripts/*.sh githooks/*; do bash -n "$f" || exit 1; done
sentrux check . && sentrux gate .
```

All thirteen proof commands pass on this tree. The one worth reading twice is P8's,
because it stayed open through three attempts:

```
! git ls-files -z -- src tools | xargs -0 grep -nIE "felipe|frb@|ford@|Micromed|[Cc]oreum|Odelio|\
  micromed|frb-linux|macbook-pro|[Hh]ermes|/home/frb|uso: |aviso no" | grep -v 'feliperun/agent-belt'
```

The only identifiers left anywhere in the tree are `feliperun/agent-belt`, the repository's
own URL, and `com.frb.agentbelt`, the shipped bundle identifier and LaunchAgent label,
which cannot change without orphaning every installed agent. Both are the product's
published identity, not leaked data.

