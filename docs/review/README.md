# Security and quality review

agent-belt, 2026-09-25, before wide public release.

Four areas were read adversarially against the code. Every defect found is recorded
as a requirement: what is wrong, how it is triggered, what changed, and a command
that exits 0 only while the fix holds.

```sh
bash scripts/review-proofs.sh        # every proof, stopping at the first that fails
bash scripts/review-proofs.sh R      # one area, by id prefix
```

The runner reads the proofs out of the findings files as it goes, so a finding
cannot be added without its proof joining the run, and a fix cannot be undone
without the run going red.

## Where it stands

**64 findings — 59 fixed, 4 accepted, 1 open.** 5 critical, 17 high, 26 medium, 16 low. All 64 proofs pass. The open one, P10, is the licence: the owner's decision, pending before the wide release.

The critical ones:

- **LDS-1** — Linux runtime files land in a world-writable `/tmp`
- **N1** — a WebSocket frame length from the wire sizes an allocation, unchecked
- **N15** — a release tag from the network was spliced into a shell command
- **R1** — a curly apostrophe closed the PowerShell quoting, so dictated text ran as code on Windows hosts
- **R7** — an entry in `hosts.conf` could be an ssh option instead of a machine

**Accepted** means a defect the project carries on purpose, with the reason in its
block. There are four, and one is only half settled:

| ID | Why |
|---|---|
| N21 | `agb update` builds the *source* of a release tag over HTTPS and never executes a release asset, so replacing the uploaded zip cannot run code. Signing it would need a key the project does not have. |
| R9 | `StrictHostKeyChecking=accept-new`: `agb hosts discover` and `agb deploy` reach machines that were never seeded into `known_hosts`. A **changed** key is still refused. |
| R12 | Agents start with their permission prompts off and the worktree pre-trusted — that is the product. `WORK_NO_AUTOTRUST=1` turns the trust writes off, and each file is backed up before the first change. |
| LDS-12 | Half product, half deferred. Linux typing cannot avoid argv (`wtype` takes the text only as an argument). Moving `_intent`/`_summary`/`--prompt` to the environment rewrites the panel↔CLI protocol across two front-ends no review run can exercise, so **that half is still open**. |

## Findings

Severity is the reviewer's, against a public release: *critical* is remote or
cross-user code execution, *high* is a leak of data or credentials or a crash an
outsider can cause, *medium* is a defect needing a precondition, *low* is hygiene.

### Local data and secrets

[`local-data-and-secrets.md`](./local-data-and-secrets.md) — what agb writes to disk and keeps: recordings, transcripts, runtime files, API keys.

| ID | Sev | Finding | Status | Proof |
|---|---|---|---|---|
| LDS-1 | critical | Linux runtime files land in a world-writable /tmp | fixed | `bash -c '! grep -q "XDG_RUNTIME_DIR\") orelse \"/tmp\"" src/linux/desktop.zig && grep -q "createPrivateDir" src/linux/desktop.zig && zig test src/sessions/sys.zig'` |
| LDS-2 | high | Sixty days of recordings and transcripts readable by every local user | fixed | `zig test src/history.zig` |
| LDS-3 | high | install.sh hands the Deepgram key to `ps` | fixed | `bash -c '! grep -q "security add-generic-password" install.sh && grep -q "security -i" install.sh && bash -n install.sh'` |
| LDS-4 | high | Spoken prompts and caches written readable by everyone | fixed | `zig test src/sessions/sys.zig` |
| LDS-5 | medium | The Linux Deepgram key kept a loose mode across installs | fixed | `bash -c 'grep -q "sys.writeFileAtomic(ctx, path, key)" src/linux/desktop.zig && ! grep -q "fromMode(0o600)" src/linux/desktop.zig'` |
| LDS-6 | medium | The dictated request written to the daemon log | fixed | `bash -c '! grep -q "new agent: %s\\\\n\", command.UTF8String" src/create_panel.m && ! grep -q "VOICE COMMAND: {s}" src/daemon.zig && ! grep -q "open: {s}\", .{line.items}" src/windows/daemon.zig'` |
| LDS-7 | low | The transcript handed to the notification daemon | fixed | `bash -c '! grep -q "notify(ctx, \"Agent Belt\", text, 1)" src/linux/desktop.zig'` |
| LDS-8 | low | Voice and transcript left in the runtime directory after use | fixed | `bash -c 'grep -q "agb-ptt.final" src/linux/desktop.zig && grep -q "agb-agent.final" src/linux/agent_panel.zig && grep -q "deleteFile(ctx.io, p)" src/linux/agent_panel.zig'` |
| LDS-9 | low | The Keychain key left in freed memory, and read after free | fixed | `bash -c 'grep -q "@memset(span, 0)" src/macos.zig && grep -q "fn wipe" src/live_recording.zig && grep -q "BOOL readable = secret != NULL" src/system.m'` |
| LDS-10 | low | The 60-day retention only ran when a new recording was saved | fixed | `bash -c 'grep -q "prune(io, d) catch {}" src/history.zig'` |
| LDS-11 | low | `--uninstall` said nothing about the recordings left behind | fixed | `bash -c 'grep -q "your recordings and transcripts stay in" install.sh && bash -n install.sh'` |
| LDS-12 | medium | The dictated request travels in process arguments | **accepted** | `grep -q '"wtype", "-s", "120", "--", text' src/linux/desktop.zig` |
| LDS-13 | medium | The last spoken request kept for ever in ~/Library/Caches, mode 0755 | fixed | `! grep -q 'NSFilePosixPermissions: @0755' src/agent_switcher.m && grep -q 'zsh -l\\nrm -f' src/agent_switcher.m && [ "$(grep -c 'NSFilePosixPermissions: @0700' src/agent_switcher.m)" = 2 ]` |

### Network clients and updates

[`network-and-updates.md`](./network-and-updates.md) — the Deepgram, Jev and DeepSeek clients, response parsing, the self-update path and the release workflows.

| ID | Sev | Finding | Status | Proof |
|---|---|---|---|---|
| N1 | critical | A frame length from the wire sizes an allocation, unchecked | fixed | `zig test --test-filter "above the message cap" src/transcribe_stream.zig` |
| N2 | high | Any `101` response was accepted as a WebSocket | fixed | `zig test --test-filter "Sec-WebSocket-Accept" src/transcribe_stream.zig` |
| N3 | medium | A 16-bit length of exactly 127 consumed eight more bytes | fixed | `zig test --test-filter "16-bit length of 127" src/transcribe_stream.zig` |
| N4 | medium | Control frames and unknown opcodes were not validated | fixed | `zig test --test-filter "oversized or fragmented control frame" src/transcribe_stream.zig` |
| N5 | medium | Configured values were spliced raw into the upgrade request | fixed | `zig test --test-filter "percent-encodes" src/transcribe_stream.zig` |
| N6 | medium | An endless header block held the recording thread forever | fixed | `zig test --test-filter "endless header block" src/transcribe_stream.zig` |
| N7 | low | An API key containing CRLF aborted the daemon or injected a header | fixed | `test "$(grep -c 'indexOfAny(u8, .*api_key, "\\r\\n") != null) return error.InvalidApiKey' src/transcribe_stream.zig src/deepgram.zig src/sessions/jev.zig src/sessions/deepseek.zig \| grep -c ':1')" = 4` |
| N8 | medium | Configured values were spliced raw into the request URL | fixed | `zig test --test-filter "percent-encodes" src/deepgram.zig` |
| N9 | medium | The API key rode in a header that survives a cross-domain redirect | fixed | `grep -q '.redirect_behavior = .unhandled' src/deepgram.zig` |
| N10 | low | The whole server-controlled body went to the log, in Portuguese | fixed | `! grep -q 'retornou' src/deepgram.zig && grep -q 'return body\[0..@min(body.len, 512)\];' src/deepgram.zig` |
| N11 | high | A reply that is not the documented shape aborted the daemon | fixed | `zig test --test-filter "hostile Jev response" src/sessions/jev.zig` |
| N12 | high | The response body was allocated without a bound | fixed | `grep -q 'error.WriteFailed => return error.JevResponseTooLarge' src/sessions/jev.zig && grep -q 'var response = std.Io.Writer.fixed(buffer);' src/sessions/jev.zig` |
| N13 | low | Answers already parsed leaked when a later one was missing | fixed | `zig test --test-filter "frees what was already parsed" src/sessions/jev.zig` |
| N14 | high | The response body was allocated without a bound | fixed | `grep -q 'error.WriteFailed => return error.DeepSeekResponseTooLarge' src/sessions/deepseek.zig && grep -q 'var response = std.Io.Writer.fixed(buffer);' src/sessions/deepseek.zig` |
| N15 | critical | A release tag from the network was spliced into a shell command | fixed | `! grep -q 'stringWithFormat:@"exec' src/updater.m && bash -c 'rm -f /tmp/agb-pwn; out=$(/bin/bash -c "exec \"\$0\" \${1:+\"\$1\"} >>\"\$2\" 2>&1" /bin/echo "v1; touch /tmp/agb-pwn" /dev/stdout); test ! -e /tmp/agb-pwn && test "$out" = "v1; touch /tmp/agb-pwn"'` |
| N16 | medium | The release URL was opened without checking scheme, host or type | fixed | `grep -q 'isEqual:@"https"' src/updater.m && grep -q 'isEqual:@"github.com"' src/updater.m` |
| N17 | low | The release response was parsed whatever its status or size | fixed | `grep -q 'status != 200 \|\| data.length == 0 \|\| data.length > 1024 \* 1024' src/updater.m` |
| N18 | high | `curl -L` could be redirected off HTTPS | fixed | `grep -q -- "--proto '=https' --proto-redir '=https'" scripts/update.sh` |
| N19 | medium | The tag was not validated before it became part of a URL | fixed | `bash -c 'for bad in "v1;id" "../../x" "a b" "v1..2"; do bash scripts/update.sh "$bad" >/dev/null 2>&1 && exit 1; done; exit 0'` |
| N20 | medium | A truncated download was still unpacked and installed | fixed | `! grep -qE 'curl[^\|]*\\|[[:space:]]*tar' scripts/update.sh && grep -q '\[ -x "$dir/source/install.sh" \]' scripts/update.sh` |
| N21 | medium | What the updater installs carries no signature or checksum | **accepted** | `grep -q 'archive/refs/tags' scripts/update.sh && grep -q -- "--proto-redir '=https'" scripts/update.sh` |
| N22 | medium | Every action was referenced by a mutable tag | fixed | `! grep -rqE 'uses: .*@v[0-9]' .github/workflows/ && test "$(grep -rhoE 'uses: [^ ]+@[0-9a-f]{40}' .github/workflows/ \| wc -l \| tr -d ' ')" = 6` |
| N23 | medium | Jobs ran with the repository's default token permissions | fixed | `ruby -ryaml -e 'Dir[".github/workflows/*.yml"].each{\|f\| d=YAML.load_file(f); d["jobs"].each{\|n,j\| p=j["permissions"]\|\|d["permissions"]; abort "#{f}/#{n}: no permissions" if p.nil?; abort "#{f}/#{n}: unexpected write" if p.is_a?(Hash) && p.any?{\|k,v\| v=="write" && !["contents","pull-requests"].include?(k)} }}'` |
| N24 | medium | The Sentrux binary was downloaded and executed unverified | fixed | `grep -q 'sha256sum --check --strict' .github/workflows/quality.yml && grep -q 'SENTRUX_SHA256: 3237f80fe20d54aad4deefa8a143f0d60543bb5d2d6ad891eb42432f155725a6' .github/workflows/quality.yml` |
| N25 | low | A workflow expression was interpolated into a shell command | fixed | `ruby -ryaml -e 'Dir[".github/workflows/*.yml"].each{\|f\| YAML.load_file(f)["jobs"].each_value{\|j\| (j["steps"]\|\|[]).each{\|s\| abort "#{f}: expression spliced into run" if s["run"].to_s.include?("${{") }}}'` |
| N26 | low | Checkout left a credential in the working tree | fixed | `test "$(grep -c 'persist-credentials: false' .github/workflows/*.yml \| awk -F: '{s+=$2} END {print s}')" = "$(grep -rc 'uses: actions/checkout@' .github/workflows/*.yml \| awk -F: '{s+=$2} END {print s}')"` |

### Remote execution and sessions

[`remote-execution.md`](./remote-execution.md) — quoting, tmux targets, the ssh protocol verbs, the machine registry and the agents agb starts.

| ID | Sev | Finding | Status | Proof |
|---|---|---|---|---|
| R1 | critical | A curly apostrophe closed the PowerShell quoting, so dictated text ran as code on Windows hosts | fixed | `zig build test 2>&1 \| tail -n 200 && zig test --test-filter "curly apostrophe" src/sessions/sys.zig` |
| R2 | low | The tmux command for a `shell` session took `$SHELL` unquoted | fixed | `grep -q 'try sys.shQuote(ctx, ctx.getenv("SHELL") orelse "/bin/sh")' src/sessions/local.zig` |
| R3 | medium | A worktree path could write its own entry into Codex's trust file | fixed | `zig test --test-filter "own Codex trust entry" src/sessions/local.zig` |
| R4 | high | `..` was a valid task name, and `~/agents/..` is the home directory | fixed | `zig test --test-filter "never a directory entry" src/sessions/sys.zig` |
| R5 | low | The adopted session took its name from a basename that could be `..` or empty | fixed | `grep -q 'if (sys.validSlug(cleaned)) cleaned else a.agent' src/sessions/local.zig` |
| R6 | low | A spoken prompt was written into a world-listable directory | fixed | `grep -q 'sys.createPrivateDir(ctx.io, dir) catch {};' src/sessions/local.zig` |
| R7 | critical | An entry in `hosts.conf` could be an ssh option instead of a machine | fixed | `zig test --test-filter "cannot be an ssh option" src/sessions/sys.zig && zig test --test-filter "whatever wrote the file" src/sessions/hosts.zig` |
| R8 | high | The ssh user was cut out of the destination and pasted into a remote PowerShell command | fixed | `! grep -q "indexOfScalar(u8, h.target, '@') orelse 0" src/sessions/cli.zig && ! grep -q "indexOfScalar(u8, host.target, '@') orelse 0" src/sessions/cli.zig && grep -q 'fn hostUser' src/sessions/cli.zig` |
| R9 | medium | `StrictHostKeyChecking=accept-new` trusts a machine's key on first contact | **accepted** | `grep -q 'StrictHostKeyChecking=accept-new' src/sessions/cli.zig` |
| R10 | medium | A session name with `:` aimed the protocol verbs at a different session | fixed | `zig test --test-filter "tmux would read as another session" src/sessions/sys.zig` |
| R11 | medium | A session name containing `\|` shifted every column of the machine-to-machine listing | fixed | `zig test --test-filter "keeps its columns" src/sessions/local.zig` |
| R12 | high | Agents start with permission checks disabled and the worktree pre-trusted | **accepted** | `grep -q 'WORK_NO_AUTOTRUST' src/sessions/local.zig && grep -q 'dangerously-skip-permissions' src/sessions/local.zig` |

### Public repository quality

[`public-repo-quality.md`](./public-repo-quality.md) — personal data anywhere a reader can see it, doc accuracy, the security policy, the licence and CI gaps.

| ID | Sev | Finding | Status | Proof |
|---|---|---|---|---|
| P1 | high | Real machine, company and repository names in the public docs | fixed | `! git ls-files -z -- docs README.md AGENTS.md tests scripts/mesh-keys.sh src/config.zig \| xargs -0 grep -nIE "felipe\|micromed\|Micromed\|broering\|coreum\|Odelio\|macbook-pro\|Hermes" \| grep -v '^docs/review/' \| grep -v 'feliperun/agent-belt'` |
| P2 | medium | User-facing Portuguese and a Portuguese identifier in `mesh-keys.sh` | fixed | `bash -n scripts/mesh-keys.sh && ! grep -nE "FALHA\|sem registro\|sem diretorio\|conferindo\|ANTIGA\|ATUALIZADA\|alvo\|' em %s\|' de %s" scripts/mesh-keys.sh` |
| P3 | medium | A headline feature depended on a private tool nobody else has | fixed | `grep -q 'None is shipped: without one, the' README.md && grep -q 'none is shipped, and without one nothing is sent' docs/agent-stats.md` |
| P4 | high | The security model understated what leaves the machine | fixed | `grep -q 'api.typesafe.ai' docs/ARCHITECTURE.md && grep -q 'api.deepseek.com' docs/ARCHITECTURE.md && ! grep -q 'Everything stays local except the transcription call' docs/VISION.md` |
| P5 | medium | The adopt documentation described a fallback the code refuses to do | fixed | `grep -q 'adopt refuses rather than falling back' docs/sessions.md && ! grep -q 'otherwise .--continue' docs/sessions.md` |
| P6 | medium | Getting Started read as macOS-only, and hid how tests are wired | fixed | `grep -q 'zig build -Dtarget=x86_64-windows-gnu' docs/GETTING-STARTED.md && grep -q 'builds and runs on macOS, Linux and Windows' docs/GETTING-STARTED.md` |
| P7 | low | The dictation language was undocumented and defaults to pt-BR | fixed | `grep -q 'deepgram_language' README.md && grep -q 'transcribed phonetically into the wrong language' src/config.zig` |
| P8 | high | Personal and production-derived data is compiled into `src/` and `tools/` | fixed | `! git ls-files -z -- src tools \| xargs -0 grep -nIE "felipe\|frb@\|ford@\|Micromed\|[Cc]oreum\|Odelio\|micromed\|frb-linux\|macbook-pro\|[Hh]ermes\|/home/frb\|uso: \|aviso no" \| grep -v 'feliperun/agent-belt' && grep -q 'return ctx.join(&.{ ctx.home(), "dev" });' src/sessions/local.zig` |
| P13 | low | Nothing said that requests are understood in Portuguese as well as English | fixed | `grep -q 'Requests are understood in \*\*English and Portuguese\*\*' README.md && grep -q 'in English or Portuguese' docs/sessions.md` |
| P9 | high | No security policy and no threat model | fixed | `test -f SECURITY.md && grep -q 'security/advisories/new' SECURITY.md && grep -q 'one compromised machine in the mesh' SECURITY.md && grep -q 'SECURITY.md' README.md` |
| P10 | high | No licence, so nobody could legally use the project | **open (owner decision)** | `! grep -q '(LICENSE)' README.md \|\| test -f LICENSE` |
| P11 | medium | `.gitignore` did not cover the build's own output or local secrets | fixed | `for p in dist/x.zip .env deepgram.key; do git check-ignore -q "$p" \|\| exit 1; done; test -z "$(git ls-files \| git check-ignore --stdin)"` |
| P12 | high | Twelve regression tests existed and never ran | fixed | `zig build test --summary all 2>&1 \| grep -qE '69/69 tests passed' && grep -q '"src/deepgram.zig", "src/transcribe_stream.zig", "src/sessions/jev.zig", "src/sessions/deepseek.zig"' build.zig` |

Each file also has a **Checked, no finding** section: ground that was covered and
turned out to be sound. It is there so a later reader can tell the difference
between "looked at, fine" and "never looked at".

## Method

Each area went to a reviewer with a write boundary and the same rules: read
`AGENTS.md` first, make the smallest change that closes the defect, add a regression
test wherever Zig can hold one, and record every finding — including the ones that
turn out to be non-issues.

Proofs prefer a named Zig test; where the behaviour lives in a shell script, a
workflow or Objective-C they are `grep`/`bash` checks written to be specific enough
to fail if the fix is undone. One finding is about the proofs themselves: twelve
regression tests existed and never ran, because a module's `test` blocks are
collected only when the module is in `build.zig`'s `test_step` list (P12).
`zig build test` now runs 69 tests.

Gates that stay green alongside the proofs:

```sh
zig build -Doptimize=ReleaseSafe && zig build test
zig build -Dtarget=x86_64-linux-musl  -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
bash -n install.sh && for f in scripts/*.sh githooks/*; do bash -n "$f" || exit 1; done
sentrux check . && sentrux gate .
```

Reporting a vulnerability, and what agent-belt trusts: [SECURITY.md](../../SECURITY.md).
