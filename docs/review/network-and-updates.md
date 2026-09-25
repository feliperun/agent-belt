# Security and quality review — network clients, response parsing, self-update

Scope: the Deepgram live WebSocket client (`src/transcribe_stream.zig`), the Deepgram
batch client (`src/deepgram.zig`), the Jev and DeepSeek HTTP clients
(`src/sessions/jev.zig`, `src/sessions/deepseek.zig`), the updater
(`src/updater.m`, `scripts/update.sh`) and the release workflows (`.github/workflows/`).

Threat model: a server the client talks to is hostile or compromised (Deepgram, Jev,
DeepSeek, `api.github.com`), an attacker sits on the network path, an attacker controls
a GitHub release or moves an action tag, and configuration on disk has been tampered
with. Every finding below is fixed unless marked `accepted`.

Regression tests live next to the code they cover. They are **not** registered in
`build.zig`, which is outside this node's write roots, so `zig build test` does not run
them yet; each proof command runs them directly with `zig test`. Registering the four
files in the `test_step` list of `build.zig` is a one-line change for the integrator:

```zig
inline for (.{ ..., "src/transcribe_stream.zig", "src/deepgram.zig", "src/sessions/jev.zig", "src/sessions/deepseek.zig" }) |path| {
```

---

## Deepgram live WebSocket client

### N1. A frame length from the wire sizes an allocation, unchecked
- **severity:** critical
- **where:** src/transcribe_stream.zig:37 (`takeHeader`), src/transcribe_stream.zig:262 (`readFrames`)
- **evidence:** the 64-bit extended payload length was read straight from the socket and
  passed to `message.resize(gpa, start + @as(usize, @intCast(len)))`. A server (or anyone
  who can terminate the TLS session) sending `0x82 0x7f` followed by `0xFF…FF` asked for a
  16 EiB allocation; on a 32-bit target the `@intCast` itself is a checked illegal cast that
  aborts the daemon. Continuation frames were also accumulated with no ceiling: an endless
  run of non-final frames grows one message until the process is killed.
- **fix:** `takeHeader` validates the length against `max_message_len` (1 MiB) before it is
  narrowed to `usize`, and `readFrames` re-checks the running total across fragments, so no
  attacker-controlled value ever reaches an allocator or a cast.
- **status:** fixed
- **proof:** command: `zig test --test-filter "above the message cap" src/transcribe_stream.zig`

### N2. Any `101` response was accepted as a WebSocket
- **severity:** high
- **where:** src/transcribe_stream.zig:72 (`acceptToken`), src/transcribe_stream.zig:88 (`readHandshakeResponse`)
- **evidence:** the handshake only looked for `" 101 "` in the status line and then skipped
  headers. `Sec-WebSocket-Accept` was never computed or compared, which is the one check
  RFC 6455 §4.1 requires of a client. Any endpoint that can answer `HTTP/1.1 101` — a
  confused HTTP service, a caching proxy, a cross-protocol redirect target — had its
  response body parsed as a frame stream, and the audio (and the `Authorization: Token`
  header already sent) went to it.
- **fix:** `acceptToken` computes `base64(sha1(key ++ GUID))` and `readHandshakeResponse`
  fails with `error.WebSocketHandshakeFailed` unless the server echoes exactly that value.
- **proof:** command: `zig test --test-filter "Sec-WebSocket-Accept" src/transcribe_stream.zig`
- **status:** fixed

### N3. A 16-bit length of exactly 127 consumed eight more bytes
- **severity:** medium
- **where:** src/transcribe_stream.zig:44
- **evidence:** the two length forms were tested with two independent `if`s:
  `if (len == 126) len = readInt(u16, …); if (len == 127) len = readInt(u64, …);`. A frame
  whose 16-bit extended length is 127 fell into the second branch and eight payload bytes
  were read as a 64-bit length — the stream desynchronises and every later frame is garbage,
  with a length again taken from payload bytes. Deepgram legitimately sends 127-byte results.
- **fix:** the second form is now `else if`, so exactly one extended length is ever read.
- **status:** fixed
- **proof:** command: `zig test --test-filter "16-bit length of 127" src/transcribe_stream.zig`

### N4. Control frames and unknown opcodes were not validated
- **severity:** medium
- **where:** src/transcribe_stream.zig:39, src/transcribe_stream.zig:49, src/transcribe_stream.zig:268
- **evidence:** a ping or pong of any size was read into the message buffer and then
  shrunk away, so an oversized "ping" was still allocated and buffered (RFC 6455 caps a
  control frame at 125 bytes and forbids fragmenting one). Reserved bits `RSV1..3` were
  ignored although no extension is negotiated, and opcodes 0x3–0x7 and 0xB–0xF were treated
  as data and appended to the transcript message.
- **fix:** `takeHeader` rejects set reserved bits and any control frame that is fragmented or
  longer than 125 bytes; `readFrames` discards control payloads without buffering them and
  refuses any opcode above `0x2`.
- **status:** fixed
- **proof:** command: `zig test --test-filter "oversized or fragmented control frame" src/transcribe_stream.zig`

### N5. Configured values were spliced raw into the upgrade request
- **severity:** medium
- **where:** src/transcribe_stream.zig:56 (`writeTarget`)
- **evidence:** `model` and `language` came from `~/.config/agent-belt/config.json` and were
  printed into the request target with `{s}`. A value containing CRLF injects arbitrary
  headers into the upgrade request (`Authorization`, a second request line); a value
  containing `&` or `=` silently rewrites the query. `keyterms` was already encoded — these
  two were not.
- **fix:** `writeTarget` percent-encodes model, language and every keyterm with the same
  unreserved-character predicate, and is covered by a test asserting no CRLF survives.
- **status:** fixed
- **proof:** command: `zig test --test-filter "percent-encodes" src/transcribe_stream.zig`

### N6. An endless header block held the recording thread forever
- **severity:** medium
- **where:** src/transcribe_stream.zig:93
- **evidence:** after the status line the handshake looped `while (true)` over header lines
  until a blank one. A server that keeps sending short headers never ends the loop; the call
  is made from the recording path, so holding the key produced a hang with no transcript and
  no error.
- **fix:** the loop is bounded by `max_handshake_headers` (64) and returns
  `error.WebSocketHandshakeFailed` when the block does not end.
- **status:** fixed
- **proof:** command: `zig test --test-filter "endless header block" src/transcribe_stream.zig`

---

## API keys in headers

### N7. An API key containing CRLF aborted the daemon or injected a header
- **severity:** low
- **where:** src/transcribe_stream.zig:150, src/deepgram.zig:46, src/sessions/jev.zig:103, src/sessions/deepseek.zig:28
- **evidence:** keys are read from the Keychain, the Windows Credential Manager, a config
  file or the environment. In the WebSocket client a key with CRLF is printed into the
  handshake and injects headers. In the three `std.http` clients the same value reaches
  `Client.request`, which **asserts** that a header value holds no CRLF — in ReleaseSafe that
  is an abort of the daemon, not an error the caller can report.
- **fix:** all four clients reject a key containing CR or LF with `error.InvalidApiKey`
  before any request is built.
- **status:** fixed
- **proof:** command: `test "$(grep -c 'indexOfAny(u8, .*api_key, "\\r\\n") != null) return error.InvalidApiKey' src/transcribe_stream.zig src/deepgram.zig src/sessions/jev.zig src/sessions/deepseek.zig | grep -c ':1')" = 4`

---

## Deepgram batch client

### N8. Configured values were spliced raw into the request URL
- **severity:** medium
- **where:** src/deepgram.zig:13 (`writeUrl`)
- **evidence:** the endpoint was built with `bufPrint("…?model={s}&language={s}…")` from
  config values. A `model` of `nova-3&language=xx` rewrites the query; a value with a space
  or CRLF produces a URL that either fails to parse or reshapes the request.
- **fix:** `writeUrl` percent-encodes both values and the result is parsed by `std.Uri.parse`;
  a test pins the exact encoded URL.
- **status:** fixed
- **proof:** command: `zig test --test-filter "percent-encodes" src/deepgram.zig`

### N9. The API key rode in a header that survives a cross-domain redirect
- **severity:** medium
- **where:** src/deepgram.zig:60
- **evidence:** `Authorization` was passed in `extra_headers`, documented by std as "kept
  including when following a redirect to a different domain", with the default
  redirect behaviour of three hops. A `303` (or a `302` on a POST) from the endpoint makes
  std re-issue the request as a GET against the new host with the Deepgram key attached.
  Only the empty auxiliary buffer passed to `receiveHead(&.{})` happened to turn that into
  `error.HttpRedirectLocationOversize` — an incidental guard, not an intentional one.
- **fix:** the request sets `.redirect_behavior = .unhandled`; the batch endpoint never
  redirects, and now a redirect is an error rather than a key disclosure one buffer away.
- **status:** fixed
- **proof:** command: `grep -q '.redirect_behavior = .unhandled' src/deepgram.zig`

### N10. The whole server-controlled body went to the log, in Portuguese
- **severity:** low
- **where:** src/deepgram.zig:22 (`preview`), src/deepgram.zig:79
- **evidence:** a non-200 response logged `"Deepgram retornou HTTP {d}: {s}"` with the entire
  body — up to the 1 MiB read limit — into `~/Library/Logs/agent-belt.log`. The message also
  broke the repository's English-only rule, and unbounded server-controlled bytes in a log
  file are a way to bloat or to poison anything that reads it.
- **fix:** both log lines are English and pass the body through `preview`, which caps it at
  512 bytes.
- **status:** fixed
- **proof:** command: `! grep -q 'retornou' src/deepgram.zig && grep -q 'return body\[0..@min(body.len, 512)\];' src/deepgram.zig`

### Checked, no finding
The batch body is read with `allocRemaining(…, .limited(max_response_len))`, so a
decompression bomb or an endless body is bounded at 1 MiB; the typed `parseFromSlice`
already returned errors rather than panicking, and the channel/alternative lengths were
already guarded. A regression test now pins that behaviour
(`zig test --test-filter "hostile Deepgram response" src/deepgram.zig`).

---

## Jev client

### N11. A reply that is not the documented shape aborted the daemon
- **severity:** high
- **where:** src/sessions/jev.zig:22 (`field`), src/sessions/jev.zig:37 (`parseChoices`)
- **evidence:** the answers were read as
  `parsed.value.object.get("answers").object` and `(a.get("choice") …).string`. Accessing the
  wrong field of a `std.json.Value` union is checked illegal behaviour: in ReleaseSafe it
  panics. A reply of `[]`, `"x"`, `{"answers":[]}` or `{"answers":{"machine":{"choice":42}}}`
  — anything a broken or hostile endpoint can return with HTTP 200 — killed the daemon.
- **fix:** `field` verifies the union tag before every lookup and `parseChoices` checks that
  `choice` is a string, returning `error.JevBadResponse` for every other shape.
- **status:** fixed
- **proof:** command: `zig test --test-filter "hostile Jev response" src/sessions/jev.zig`

### N12. The response body was allocated without a bound
- **severity:** high
- **where:** src/sessions/jev.zig:20, src/sessions/jev.zig:106
- **evidence:** `fetch` streamed the body into a `std.Io.Writer.Allocating`, which grows for
  as long as the server keeps writing. A server that answers 200 and then streams
  indefinitely exhausts memory in the daemon; `std.http` applies no limit of its own.
- **fix:** the body is written into a fixed `max_response_len` (256 KiB) buffer; overflowing
  it surfaces as `error.JevResponseTooLarge`.
- **status:** fixed
- **proof:** command: `grep -q 'error.WriteFailed => return error.JevResponseTooLarge' src/sessions/jev.zig && grep -q 'var response = std.Io.Writer.fixed(buffer);' src/sessions/jev.zig`

### N13. Answers already parsed leaked when a later one was missing
- **severity:** low
- **where:** src/sessions/jev.zig:43
- **evidence:** `choices` allocated the result array and duplicated each answer's string, but
  a missing key on the second or later question returned `error.JevBadResponse` with the
  array and every earlier duplicate still allocated. A server omitting one key leaks on every
  intent parse.
- **fix:** an `errdefer` frees the array and the strings filled so far.
- **status:** fixed
- **proof:** command: `zig test --test-filter "frees what was already parsed" src/sessions/jev.zig`

---

## DeepSeek client

### N14. The response body was allocated without a bound
- **severity:** high
- **where:** src/sessions/deepseek.zig:11, src/sessions/deepseek.zig:43
- **evidence:** same defect as N12 — `fetch` wrote into a `Writer.Allocating` with no ceiling,
  so a 200 response that never ends exhausts memory. The request asks for 400 tokens; the
  answer is a few kB.
- **fix:** a fixed 128 KiB response buffer; overflow becomes `error.DeepSeekResponseTooLarge`.
- **status:** fixed
- **proof:** command: `grep -q 'error.WriteFailed => return error.DeepSeekResponseTooLarge' src/sessions/deepseek.zig && grep -q 'var response = std.Io.Writer.fixed(buffer);' src/sessions/deepseek.zig`

### Checked, no finding
The reply is parsed into a typed struct, so a missing or mistyped field is an error and not
a panic, and `choices.len == 0` was already handled. `parseContent` was split out of the
request so the behaviour is pinned by a test
(`zig test --test-filter "hostile DeepSeek response" src/sessions/deepseek.zig`).

---

## Updater

### N15. A release tag from the network was spliced into a shell command
- **severity:** critical
- **where:** src/updater.m:40 (`MKIsReleaseTag`), src/updater.m:59
- **evidence:** `MKStartUpdate` built `[NSString stringWithFormat:@"exec %@ %@ >>%@ 2>&1", script, tag, log]`
  and ran it with `/bin/bash -lc`. Only spaces were escaped. `tag` is
  `release["tag_name"]` taken verbatim from `api.github.com` and carried in the notification's
  `userInfo`, and is also the argument of `agb update <tag>`. A release named
  `v1.0.0;curl … | sh` runs as the logged-in user the moment the user presses **Update** on
  the notification — anyone able to create a release, or to answer for `api.github.com`,
  gets arbitrary code execution. The spawn deliberately outlives the daemon
  (`POSIX_SPAWN_SETSID`), so the process survives the update.
- **fix:** the command string is now a constant, `exec "$0" ${1:+"$1"} >>"$2" 2>&1`, and the
  script, the tag and the log path are passed as positional arguments that bash never
  re-parses. `MKIsReleaseTag` additionally rejects any tag that is not 1–64 characters of
  `[A-Za-z0-9.+_-]`, both for `agb update` and for what the API returns.
- **status:** fixed
- **proof:** command: `! grep -q 'stringWithFormat:@"exec' src/updater.m && bash -c 'rm -f /tmp/agb-pwn; out=$(/bin/bash -c "exec \"\$0\" \${1:+\"\$1\"} >>\"\$2\" 2>&1" /bin/echo "v1; touch /tmp/agb-pwn" /dev/stdout); test ! -e /tmp/agb-pwn && test "$out" = "v1; touch /tmp/agb-pwn"'`

### N16. The release URL was opened without checking scheme, host or type
- **severity:** medium
- **where:** src/updater.m:116 (`MKReleaseURL`)
- **evidence:** `mk_update_url = release[@"html_url"]` was stored with no class check and
  handed to `[NSWorkspace openURL:]` when the user clicks the notification. A response whose
  `html_url` is not a string makes `[NSURL URLWithString:]` raise on a non-`NSString`
  argument and crash the daemon; a response with a `file://`, `x-apple-…` or other scheme
  makes a single click on an Agent Belt notification open an attacker-chosen target.
- **fix:** `MKReleaseURL` accepts only an `NSString` that parses to an `https` URL on
  `github.com` (or a subdomain), and the click handler requires a non-empty value.
- **status:** fixed
- **proof:** command: `grep -q 'isEqual:@"https"' src/updater.m && grep -q 'isEqual:@"github.com"' src/updater.m`

### N17. The release response was parsed whatever its status or size
- **severity:** low
- **where:** src/updater.m:126 (`MKReleaseBody`)
- **evidence:** the completion handler ignored the `NSURLResponse` entirely (`(void)response;`)
  and fed any non-nil `NSData` to `NSJSONSerialization`. An error page, a rate-limit body or
  an arbitrarily large payload was buffered in full and parsed, six-hourly, in the daemon.
- **fix:** `MKReleaseBody` requires HTTP 200 and a body between 1 byte and 1 MiB before it
  parses, and requires the result to be a dictionary.
- **status:** fixed
- **proof:** command: `grep -q 'status != 200 || data.length == 0 || data.length > 1024 \* 1024' src/updater.m`

### N18. `curl -L` could be redirected off HTTPS
- **severity:** high
- **where:** scripts/update.sh:9
- **evidence:** both transfers used `curl -fsSL` with no protocol restriction. `-L` follows a
  redirect to any scheme, so a `301` to `http://…` (which an on-path attacker can inject the
  moment any hop is plaintext) hands the script a source tree that it then unpacks, builds,
  code-signs locally and registers as a LaunchAgent. The tarball is the code that runs.
- **fix:** every transfer uses `--proto '=https' --proto-redir '=https'` plus `--max-time`, so
  the download cannot leave HTTPS.
- **status:** fixed
- **proof:** command: `grep -q -- "--proto '=https' --proto-redir '=https'" scripts/update.sh`

### N19. The tag was not validated before it became part of a URL
- **severity:** medium
- **where:** scripts/update.sh:17
- **evidence:** `tag` came from `$1` or from a `sed` over the API response and went straight
  into `https://github.com/$repo/archive/refs/tags/$tag.tar.gz`. A tag containing `/` or `..`
  walks out of the repository path and fetches a different archive (`../../other/repo/…`);
  a tag starting with `-` is taken by `curl` as an option.
- **fix:** a `case` guard accepts only `[A-Za-z0-9.+_-]` and rejects any `..`, before `curl`
  is called. `src/updater.m` applies the same rule on its side (N15).
- **status:** fixed
- **proof:** command: `bash -c 'for bad in "v1;id" "../../x" "a b" "v1..2"; do bash scripts/update.sh "$bad" >/dev/null 2>&1 && exit 1; done; exit 0'`

### N20. A truncated download was still unpacked and installed
- **severity:** medium
- **where:** scripts/update.sh:27
- **evidence:** the script piped `curl … | tar -xz`. `pipefail` catches a curl that exits
  non-zero, but a connection cut mid-transfer can still leave a partially extracted tree in
  `$dir`, and the extracted state is whatever tar managed before the error. There was also no
  check that the archive contained an installer, and the temporary directory was never removed.
- **fix:** the archive is fetched whole to `$dir/source.tar.gz`, then extracted; the script
  requires an executable `install.sh` in the result and removes the temporary directory on exit.
- **status:** fixed
- **proof:** command: `! grep -qE 'curl[^|]*\|[[:space:]]*tar' scripts/update.sh && grep -q '\[ -x "$dir/source/install.sh" \]' scripts/update.sh`

### N21. What the updater installs carries no signature or checksum
- **severity:** medium
- **where:** scripts/update.sh:27
- **evidence:** `update.sh` downloads `https://github.com/<repo>/archive/refs/tags/<tag>.tar.gz`
  and runs `./install.sh` from it. Nothing verifies that the archive is the code the
  maintainer released: integrity rests entirely on TLS to `github.com` and on GitHub itself.
- **fix:** not fixed. Two mitigations bound the exposure and are in place: the download is
  HTTPS end to end and cannot be redirected to plaintext (N18), and the updater never
  executes a **release asset** — it builds the *source of the tag*, so an attacker who
  replaces the uploaded `.zip` on a release (the asset `release-please.yml` publishes) cannot
  run code on any user's machine. Closing the remaining gap needs a published signature and a
  signing key, which the project does not have; the product requirement recorded in
  `scripts/update.sh` and `.github/workflows/release-please.yml` is that updates are built
  from source locally so macOS privacy grants survive, and a notarised signed artifact —
  the usual alternative — is explicitly not the update path.
- **status:** accepted
- **proof:** command: `grep -q 'archive/refs/tags' scripts/update.sh && grep -q -- "--proto-redir '=https'" scripts/update.sh`

---

## GitHub Actions

### N22. Every action was referenced by a mutable tag
- **severity:** medium
- **where:** .github/workflows/ci.yml:16, .github/workflows/quality.yml:17, .github/workflows/release-please.yml:21
- **evidence:** `actions/checkout@v5`, `mlugg/setup-zig@v2` and
  `googleapis/release-please-action@v4` are branch-like tags the action's owner can move at
  any time. Whoever moves one runs their code in this repository's workflows, including the
  release job that holds a `contents: write` token.
- **fix:** all three are pinned to the commit the tag pointed at, with the version in a
  trailing comment (checkout v5.1.0, setup-zig v2.2.1, release-please-action v4.4.1 — the
  same commits the floating tags resolved to, so behaviour is unchanged).
- **status:** fixed
- **proof:** command: `! grep -rqE 'uses: .*@v[0-9]' .github/workflows/ && test "$(grep -rhoE 'uses: [^ ]+@[0-9a-f]{40}' .github/workflows/ | wc -l | tr -d ' ')" = 6`

### N23. Jobs ran with the repository's default token permissions
- **severity:** medium
- **where:** .github/workflows/ci.yml:8, .github/workflows/quality.yml:11, .github/workflows/release-please.yml:7
- **evidence:** `ci.yml` and `quality.yml` declared no `permissions:` at all, so their
  `GITHUB_TOKEN` carries whatever the repository default is — historically read/write on every
  scope. Both jobs build and execute code from the checked-out tree (including a pull request's
  code), so a malicious PR could use that token. `release-please.yml` declared
  `contents: write` and `pull-requests: write` at workflow level, which also handed both to the
  packaging job that only uploads an asset.
- **fix:** `ci.yml` and `quality.yml` are `contents: read`; `release-please.yml` defaults to
  `permissions: {}` and grants `contents: write` + `pull-requests: write` to the release job and
  `contents: write` to the packaging job only.
- **status:** fixed
- **proof:** command: `ruby -ryaml -e 'Dir[".github/workflows/*.yml"].each{|f| d=YAML.load_file(f); d["jobs"].each{|n,j| p=j["permissions"]||d["permissions"]; abort "#{f}/#{n}: no permissions" if p.nil?; abort "#{f}/#{n}: unexpected write" if p.is_a?(Hash) && p.any?{|k,v| v=="write" && !["contents","pull-requests"].include?(k)} }}'`

### N24. The Sentrux binary was downloaded and executed unverified
- **severity:** medium
- **where:** .github/workflows/quality.yml:28
- **evidence:** the quality job fetched `sentrux-linux-x86_64` from a GitHub release,
  `chmod +x`'d it and ran it over the whole checkout with no checksum. A replaced release
  asset, or a redirect off HTTPS, executes attacker code in CI on every push and pull request.
- **fix:** the download is HTTPS-only end to end and is checked against a pinned
  `SENTRUX_SHA256` with `sha256sum --check --strict` before `chmod +x`; a version bump now has
  to bring a new checksum with it.
- **status:** fixed
- **proof:** command: `grep -q 'sha256sum --check --strict' .github/workflows/quality.yml && grep -q 'SENTRUX_SHA256: 3237f80fe20d54aad4deefa8a143f0d60543bb5d2d6ad891eb42432f155725a6' .github/workflows/quality.yml`

### N25. A workflow expression was interpolated into a shell command
- **severity:** low
- **where:** .github/workflows/release-please.yml:52
- **evidence:** `run: gh release upload "${{ needs.release-please.outputs.tag_name }}" …`
  pastes a step output into the script's text before bash sees it — the pattern that turns any
  attacker-influenced value into command execution on the runner. Here the value comes from
  release-please rather than from a pull request title or a branch name, so it is not
  presently attacker-controlled, but the shape is the defect.
- **fix:** the tag is passed through the step's `env:` and referenced as `"$TAG_NAME"`, so it
  is data to bash, never text in the command.
- **status:** fixed
- **proof:** command: `ruby -ryaml -e 'Dir[".github/workflows/*.yml"].each{|f| YAML.load_file(f)["jobs"].each_value{|j| (j["steps"]||[]).each{|s| abort "#{f}: expression spliced into run" if s["run"].to_s.include?("${{") }}}'`

### N26. Checkout left a credential in the working tree
- **severity:** low
- **where:** .github/workflows/ci.yml:17
- **evidence:** `actions/checkout` defaults to `persist-credentials: true`, storing the job's
  token in `.git/config`. Every one of these jobs then builds and runs code from the tree it
  just checked out (a pull request's code, in `ci.yml` and `quality.yml`), which puts the
  token within reach of a build script.
- **fix:** every checkout sets `persist-credentials: false`; nothing in these workflows pushes
  with git (the release job authenticates `gh` through `GH_TOKEN`).
- **status:** fixed
- **proof:** command: `test "$(grep -c 'persist-credentials: false' .github/workflows/*.yml | awk -F: '{s+=$2} END {print s}')" = "$(grep -rc 'uses: actions/checkout@' .github/workflows/*.yml | awk -F: '{s+=$2} END {print s}')"`

### Checked, no finding
No workflow uses `pull_request_target` or `workflow_run`, so none runs privileged against a
fork's code. No pull request title, body, branch name, label or issue text is referenced
anywhere; the only `github.*` reference left is `github.event_name` in an `if:` condition,
which never reaches a shell. There is no self-hosted runner and no third-party action beyond
the three pinned above.

---

## Verification

```
zig build -Doptimize=ReleaseSafe
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
bash -n install.sh && for f in scripts/*.sh githooks/*; do bash -n "$f" || exit 1; done
sentrux check . && sentrux gate .
zig test src/transcribe_stream.zig && zig test src/deepgram.zig \
  && zig test src/sessions/jev.zig && zig test src/sessions/deepseek.zig
actionlint
```
